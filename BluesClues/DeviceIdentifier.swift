//
//  DeviceIdentifier.swift
//  BluesClues
//
//  Guesses who made a Bluetooth device and what kind of device it is, from
//  what it advertises. iOS never shows real MAC addresses (and most devices
//  use random ones anyway), so this works from the advertisement contents:
//  the Bluetooth SIG company ID in the manufacturer data, 16-bit service UUIDs
//  that the SIG assigns to member companies, Apple Continuity and Microsoft
//  CDP message types, and the advertised name. Everything runs on the phone.
//

import Foundation

// MARK: - Advertisement Fields
/// The raw parts of an advertisement worth keeping for identification,
/// stored as JSON on the device so suggestions can be recomputed later.
struct AdvertisementFields: Codable, Equatable {
    var manufacturerData: Data?
    var serviceUUIDs: [String] = []
    var serviceDataUUIDs: [String] = []
    var localName: String?
    var txPower: Int?

    var companyID: UInt16? {
        guard let manufacturerData, manufacturerData.count >= 2 else { return nil }
        return UInt16(manufacturerData[manufacturerData.startIndex])
            | (UInt16(manufacturerData[manufacturerData.startIndex + 1]) << 8)
    }

    /// Keeps the newest values but doesn't forget a name or services that
    /// only appear in some packets (e.g. scan responses).
    func merged(with newer: AdvertisementFields) -> AdvertisementFields {
        AdvertisementFields(
            manufacturerData: newer.manufacturerData ?? manufacturerData,
            serviceUUIDs: Array(Set(serviceUUIDs).union(newer.serviceUUIDs)).sorted(),
            serviceDataUUIDs: Array(Set(serviceDataUUIDs).union(newer.serviceDataUUIDs)).sorted(),
            localName: newer.localName ?? localName,
            txPower: newer.txPower ?? txPower)
    }

    var json: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func fromJSON(_ json: String?) -> AdvertisementFields? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AdvertisementFields.self, from: data)
    }

    /// Human-readable dump for the detail screen and CSV export.
    var rawDescription: String {
        var parts: [String] = []
        if let manufacturerData {
            parts.append("Manufacturer data: " + manufacturerData.map { String(format: "%02X", $0) }.joined())
        }
        if !serviceUUIDs.isEmpty { parts.append("Services: " + serviceUUIDs.joined(separator: ", ")) }
        if !serviceDataUUIDs.isEmpty { parts.append("Service data: " + serviceDataUUIDs.joined(separator: ", ")) }
        if let localName { parts.append("Name: \(localName)") }
        if let txPower { parts.append("Tx power: \(txPower) dBm") }
        return parts.isEmpty ? "Nothing advertised" : parts.joined(separator: "\n")
    }
}

// MARK: - Device Category
enum DeviceCategory: String, CaseIterable, Identifiable, Codable {
    case phone = "Phone"
    case computer = "Computer or tablet"
    case earbuds = "Earbuds or headphones"
    case watch = "Watch or fitness band"
    case speaker = "Speaker"
    case tv = "TV or streaming device"
    case tracker = "Item tracker"
    case car = "Car"
    case keyboardMouse = "Keyboard or mouse"
    case smartHome = "Smart home device"
    case beacon = "Beacon"
    case unknown = "Unknown"

    var id: String { rawValue }
}

// MARK: - Identification Confidence
enum IdentificationConfidence: String, Comparable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case confirmed = "Confirmed by you"

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .confirmed: return 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    init(score: Double) {
        if score >= 0.8 { self = .high } else if score >= 0.5 { self = .medium } else { self = .low }
    }
}

// MARK: - Candidate
struct ManufacturerCandidate: Identifiable, Equatable {
    var id: String { manufacturer ?? "unknown-\(category.rawValue)" }
    let manufacturer: String?
    var category: DeviceCategory
    var model: String?
    /// 0...1
    var score: Double
    var evidence: [String]

    var confidence: IdentificationConfidence { IdentificationConfidence(score: score) }
}

// MARK: - Device Identity
/// The single best answer shown on rows: either the top automatic candidate
/// or what the user confirmed.
struct DeviceIdentity: Equatable {
    let manufacturer: String?
    let category: DeviceCategory
    let model: String?
    let confidence: IdentificationConfidence
    let evidence: [String]

    var label: String {
        guard let manufacturer else {
            return model ?? (category == .unknown ? "Unknown device" : category.rawValue)
        }
        let what = model ?? (category == .unknown ? "device" : category.rawValue.lowercased())
        return "\(manufacturer) \(what)"
    }

    static let unknown = DeviceIdentity(manufacturer: nil, category: .unknown, model: nil, confidence: .low, evidence: [])
}

// MARK: - Device Identifier
enum DeviceIdentifier {
    /// Ranked guesses, best first.
    static func candidates(for fields: AdvertisementFields, tracker: TrackerKind? = nil) -> [ManufacturerCandidate] {
        var clues: [Clue] = []
        if let tracker { clues.append(trackerClue(tracker)) }
        clues += manufacturerDataClues(fields)
        clues += serviceClues(fields)
        if let name = fields.localName { clues += nameClues(name) }
        if let category = standardServiceCategory(fields) {
            clues.append(Clue(manufacturer: nil, category: category, weight: 0.3,
                              evidence: "Advertises standard \(category.rawValue.lowercased()) services"))
        }
        return combine(clues)
    }

    static func identify(_ fields: AdvertisementFields, tracker: TrackerKind? = nil) -> DeviceIdentity {
        let ranked = candidates(for: fields, tracker: tracker)
        guard let best = ranked.first(where: { $0.manufacturer != nil }) ?? ranked.first else {
            return .unknown
        }
        return DeviceIdentity(manufacturer: best.manufacturer, category: best.category, model: best.model,
                              confidence: best.confidence, evidence: best.evidence)
    }

    // MARK: Clues
    struct Clue {
        /// nil when the clue says what the device is but not who made it.
        let manufacturer: String?
        let category: DeviceCategory?
        var model: String? = nil
        let weight: Double
        let evidence: String
    }

    /// Merges clues per manufacturer. Weights combine as independent evidence
    /// (1 - Π(1 - w)) and the strongest clue with a category decides the type.
    /// Clues without a maker add their type and evidence to every candidate,
    /// or form a maker-less candidate when nothing names a maker.
    static func combine(_ clues: [Clue]) -> [ManufacturerCandidate] {
        struct Partial {
            var miss = 1.0
            var category: DeviceCategory?
            var categoryWeight = 0.0
            var model: String?
            var evidence: [String] = []

            mutating func add(_ clue: Clue, affectsScore: Bool) {
                if affectsScore { miss *= (1 - clue.weight) }
                if let category = clue.category, clue.weight > categoryWeight {
                    self.category = category
                    categoryWeight = clue.weight
                }
                if model == nil { model = clue.model }
                evidence.append(clue.evidence)
            }
        }

        let makerless = clues.filter { $0.manufacturer == nil }
        var byMaker: [String: Partial] = [:]
        for clue in clues {
            guard let maker = clue.manufacturer else { continue }
            byMaker[maker, default: Partial()].add(clue, affectsScore: true)
        }

        if byMaker.isEmpty {
            guard !makerless.isEmpty else { return [] }
            var partial = Partial()
            makerless.forEach { partial.add($0, affectsScore: true) }
            return [ManufacturerCandidate(manufacturer: nil, category: partial.category ?? .unknown,
                                          model: partial.model, score: 1 - partial.miss, evidence: partial.evidence)]
        }

        return byMaker
            .map { maker, partial -> ManufacturerCandidate in
                var partial = partial
                // Type hints only fill in a missing type; they don't raise the score.
                makerless.forEach { clue in
                    if partial.category == nil { partial.add(clue, affectsScore: false) } else { partial.evidence.append(clue.evidence) }
                }
                return ManufacturerCandidate(manufacturer: maker, category: partial.category ?? .unknown,
                                             model: partial.model, score: 1 - partial.miss, evidence: partial.evidence)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : ($0.manufacturer ?? "") < ($1.manufacturer ?? "") }
    }

    private static func trackerClue(_ kind: TrackerKind) -> Clue {
        let maker: String
        switch kind {
        case .appleFindMy: maker = "Apple (Find My network)"
        case .tile: maker = "Tile"
        case .samsungSmartTag: maker = "Samsung"
        case .googleFindMyDevice: maker = "Google (Find My Device network)"
        case .chipolo: maker = "Chipolo"
        }
        return Clue(manufacturer: maker, category: .tracker, weight: 0.9, evidence: "Matches the \(kind.rawValue) tracker format")
    }

    static func manufacturerDataClues(_ fields: AdvertisementFields) -> [Clue] {
        guard let company = fields.companyID, let data = fields.manufacturerData else { return [] }
        let bytes = [UInt8](data)
        let hex = String(format: "0x%04X", company)

        if company == 0x004C {
            var clues = [Clue(manufacturer: "Apple", category: nil, weight: 0.7, evidence: "Apple company ID (\(hex)) in manufacturer data")]
            if bytes.count >= 3 { clues += appleContinuityClues(bytes) }
            return clues
        }
        if company == 0x0006, bytes.count >= 4 {
            return [microsoftClue(bytes)]
        }
        guard let entry = CompanyIDs.table[company] else {
            return [Clue(manufacturer: String(format: "Company %@", hex), category: nil, weight: 0.3,
                         evidence: "Bluetooth company ID \(hex) (not in the built-in list)")]
        }
        if entry.isChipMaker {
            return [Clue(manufacturer: entry.name, category: nil, weight: 0.25,
                         evidence: "Company ID \(hex) belongs to chip maker \(entry.name); the product brand may differ")]
        }
        return [Clue(manufacturer: entry.name, category: entry.category, weight: 0.65,
                     evidence: "Company ID \(hex) is assigned to \(entry.name)")]
    }

    /// Apple Continuity: after the company ID comes a message type byte.
    private static func appleContinuityClues(_ bytes: [UInt8]) -> [Clue] {
        let type = bytes[2]
        func clue(_ category: DeviceCategory?, _ weight: Double, _ text: String, model: String? = nil) -> [Clue] {
            [Clue(manufacturer: "Apple", category: category, model: model, weight: weight, evidence: text)]
        }
        switch type {
        case 0x02: return [Clue(manufacturer: nil, category: .beacon, weight: 0.6, evidence: "iBeacon advertisement (Apple format, any maker can use it)")]
        case 0x05: return clue(nil, 0.6, "AirDrop message")
        case 0x06: return clue(.smartHome, 0.5, "HomeKit message")
        case 0x07:
            // Proximity pairing: 07 len 01 <model hi> <model lo> ...
            if bytes.count >= 7, let model = airPodsModels[UInt16(bytes[5]) << 8 | UInt16(bytes[6])] {
                let maker = model.hasPrefix("Beats") || model.hasPrefix("Powerbeats") ? "Beats (Apple)" : "Apple"
                return [Clue(manufacturer: maker, category: .earbuds, model: model, weight: 0.9,
                             evidence: "Proximity pairing message for \(model)")]
            }
            return clue(.earbuds, 0.8, "Proximity pairing message (AirPods or Beats)")
        case 0x09: return clue(.tv, 0.7, "AirPlay target (Apple TV, HomePod or AirPlay speaker)")
        case 0x0A: return clue(nil, 0.6, "AirPlay source")
        case 0x0B: return clue(.watch, 0.8, "Apple Watch wrist detection message")
        case 0x0C: return clue(nil, 0.6, "Handoff message (iPhone, iPad or Mac signed in to iCloud)")
        case 0x0D: return clue(.phone, 0.7, "Instant Hotspot request")
        case 0x0E: return clue(.phone, 0.8, "Instant Hotspot available (an iPhone or iPad sharing its connection)")
        case 0x0F: return clue(nil, 0.6, "Nearby Action message (setup or sharing in progress)")
        case 0x10: return clue(nil, 0.7, "Nearby Info message (iPhone, iPad, Mac or Watch)")
        case 0x12: return clue(.tracker, 0.8, "Find My network message")
        default: return clue(nil, 0.6, String(format: "Apple Continuity message type 0x%02X", type))
        }
    }

    static let airPodsModels: [UInt16: String] = [
        0x0220: "AirPods", 0x0F20: "AirPods (2nd gen)", 0x1320: "AirPods (3rd gen)",
        0x0E20: "AirPods Pro", 0x1420: "AirPods Pro (2nd gen)", 0x0A20: "AirPods Max",
        0x0320: "Powerbeats3", 0x0B20: "Powerbeats Pro", 0x0520: "BeatsX", 0x0620: "Beats Solo3",
        0x0920: "Beats Studio3", 0x0C20: "Beats Solo Pro", 0x1020: "Beats Flex", 0x1120: "Beats Studio Buds"
    ]

    /// Microsoft Connected Devices Platform beacon (scenario 0x01) or Swift Pair (0x03).
    private static func microsoftClue(_ bytes: [UInt8]) -> Clue {
        let scenario = bytes[2]
        if scenario == 0x03 {
            return Clue(manufacturer: nil, category: .keyboardMouse, weight: 0.6,
                        evidence: "Microsoft Swift Pair advertisement (a mouse, keyboard or headset pairing with Windows)")
        }
        if scenario == 0x01 {
            let deviceType = bytes[3] & 0x1F
            switch deviceType {
            case 1: return Clue(manufacturer: "Microsoft", category: .tv, model: "Xbox", weight: 0.85, evidence: "Microsoft CDP beacon from an Xbox")
            case 6: return Clue(manufacturer: "Apple", category: .phone, model: "iPhone", weight: 0.75, evidence: "Microsoft CDP beacon from an iPhone (Phone Link / Microsoft apps)")
            case 7: return Clue(manufacturer: "Apple", category: .computer, model: "iPad", weight: 0.75, evidence: "Microsoft CDP beacon from an iPad")
            case 8: return Clue(manufacturer: nil, category: .phone, model: "Android phone", weight: 0.7, evidence: "Microsoft CDP beacon from an Android device")
            case 9, 15, 16: return Clue(manufacturer: nil, category: .computer, model: "Windows PC", weight: 0.8, evidence: "Microsoft CDP beacon from a Windows computer")
            case 14: return Clue(manufacturer: "Microsoft", category: .tv, model: "Surface Hub", weight: 0.8, evidence: "Microsoft CDP beacon from a Surface Hub")
            default: break
            }
        }
        return Clue(manufacturer: "Microsoft", category: nil, weight: 0.6, evidence: "Microsoft company ID (0x0006) in manufacturer data")
    }

    static func serviceClues(_ fields: AdvertisementFields) -> [Clue] {
        Set(fields.serviceUUIDs + fields.serviceDataUUIDs).sorted().compactMap { uuid in
            guard let entry = MemberServices.table[uuid.uppercased()] else { return nil }
            return Clue(manufacturer: entry.name, category: entry.category, weight: entry.weight,
                        evidence: "Service \(uuid.uppercased()): \(entry.note)")
        }
    }

    private static func standardServiceCategory(_ fields: AdvertisementFields) -> DeviceCategory? {
        let services = Set(fields.serviceUUIDs.map { $0.uppercased() })
        if services.contains("1812") { return .keyboardMouse }
        if !services.isDisjoint(with: ["180D", "1814", "1816", "1826", "183E"]) { return .watch }
        if !services.isDisjoint(with: ["184E", "184F", "1850", "1853", "110B"]) { return .earbuds }
        return nil
    }

    // MARK: Names
    struct NamePattern {
        let regex: NSRegularExpression
        let manufacturer: String?
        let category: DeviceCategory
        let model: String?

        init(_ pattern: String, _ manufacturer: String?, _ category: DeviceCategory, model: String? = nil) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.manufacturer = manufacturer
            self.category = category
            self.model = model
        }
    }

    static func nameClues(_ name: String) -> [Clue] {
        let range = NSRange(name.startIndex..., in: name)
        // First match wins: patterns are ordered from specific to general.
        guard let pattern = namePatterns.first(where: { $0.regex.firstMatch(in: name, range: range) != nil }) else { return [] }
        return [Clue(manufacturer: pattern.manufacturer, category: pattern.category, model: pattern.model, weight: 0.75,
                     evidence: "Name \"\(name)\" matches \(pattern.manufacturer ?? pattern.category.rawValue.lowercased()) naming")]
    }

    static let namePatterns: [NamePattern] = [
        NamePattern(#"^\[TV\]"#, "Samsung", .tv, model: "TV"),
        NamePattern(#"^\[(AV|Soundbar)\]"#, "Samsung", .speaker, model: "soundbar"),
        NamePattern(#"Galaxy Buds"#, "Samsung", .earbuds, model: "Galaxy Buds"),
        NamePattern(#"Galaxy Watch"#, "Samsung", .watch, model: "Galaxy Watch"),
        NamePattern(#"Galaxy (Tab|Book)"#, "Samsung", .computer),
        NamePattern(#"^Galaxy"#, "Samsung", .phone, model: "Galaxy phone"),
        NamePattern(#"^Pixel Buds"#, "Google", .earbuds, model: "Pixel Buds"),
        NamePattern(#"^Pixel Watch"#, "Google", .watch, model: "Pixel Watch"),
        NamePattern(#"^Pixel"#, "Google", .phone, model: "Pixel phone"),
        NamePattern(#"Chromecast|Google TV|Nest (Hub|Audio|Mini)"#, "Google", .tv),
        NamePattern(#"AirPods"#, "Apple", .earbuds, model: "AirPods"),
        NamePattern(#"Apple Watch"#, "Apple", .watch, model: "Apple Watch"),
        NamePattern(#"iPhone"#, "Apple", .phone, model: "iPhone"),
        NamePattern(#"MacBook|iMac|iPad"#, "Apple", .computer),
        NamePattern(#"Powerbeats|Beats|Studio Buds"#, "Beats (Apple)", .earbuds),
        NamePattern(#"^(LE-)?Bose|^Bose"#, "Bose", .earbuds),
        NamePattern(#"^JBL"#, "JBL (Harman)", .speaker),
        NamePattern(#"^(WH|WF|WI)-[A-Z0-9]+"#, "Sony", .earbuds),
        NamePattern(#"^(LE_)?(SRS|XB|ULT)[- ]"#, "Sony", .speaker),
        NamePattern(#"^Jabra"#, "Jabra", .earbuds),
        NamePattern(#"Sennheiser|MOMENTUM"#, "Sennheiser", .earbuds),
        NamePattern(#"soundcore|Anker"#, "Anker", .earbuds),
        NamePattern(#"Skullcandy"#, "Skullcandy", .earbuds),
        NamePattern(#"^Nothing (Ear|Phone)"#, "Nothing", .earbuds),
        NamePattern(#"^OnePlus Buds"#, "OnePlus", .earbuds),
        NamePattern(#"^OnePlus"#, "OnePlus", .phone),
        NamePattern(#"^Sonos"#, "Sonos", .speaker),
        NamePattern(#"Fitbit|^(Charge|Versa|Sense|Inspire|Luxe) ?\d"#, "Fitbit (Google)", .watch),
        NamePattern(#"Mi (Smart )?Band|Redmi (Watch|Band|Buds)|Xiaomi"#, "Xiaomi", .watch),
        NamePattern(#"Amazfit|Zepp"#, "Zepp (Huami)", .watch),
        NamePattern(#"HUAWEI (WATCH|Band)|HONOR Band"#, "Huawei", .watch),
        NamePattern(#"^(Forerunner|fenix|Fenix|Venu|vivoactive|vívoactive|Instinct|epix|Enduro|Edge \d)"#, "Garmin", .watch),
        NamePattern(#"^Polar"#, "Polar", .watch),
        NamePattern(#"^Suunto"#, "Suunto", .watch),
        NamePattern(#"^WHOOP"#, "WHOOP", .watch),
        NamePattern(#"^Oura"#, "Oura", .watch),
        NamePattern(#"^(MX |Logi|K\d{3}|M\d{3}|Lift|ERGO)"#, "Logitech", .keyboardMouse),
        NamePattern(#"Surface (Pen|Mouse|Keyboard|Headphones|Earbuds)"#, "Microsoft", .keyboardMouse),
        NamePattern(#"Xbox"#, "Microsoft", .tv, model: "Xbox controller"),
        NamePattern(#"^Echo|^Fire ?TV|Amazon"#, "Amazon", .tv),
        NamePattern(#"^Tile$"#, "Tile", .tracker),
        NamePattern(#"^S[0-9a-f]{16}[CDRP]$"#, "Tesla", .car, model: "vehicle key"),
        NamePattern(#"^(Tesla|Model [3SXY])"#, "Tesla", .car),
        NamePattern(#"^(MY ?(VW|AUDI|BMW|MERCEDES|TOYOTA|HONDA|KIA|HYUNDAI|FORD|NISSAN|MAZDA|SUBARU)|SYNC|Uconnect|CarPlay|Audi MMI|BMW \d|Mercedes|Toyota|Honda|Hyundai|Kia|Lexus|Volvo)"#, nil, .car),
        NamePattern(#"^Hue|Philips"#, "Philips Hue (Signify)", .smartHome),
        NamePattern(#"^(Govee|ihoment_|GVH)"#, "Govee", .smartHome),
        NamePattern(#"^ELK-BLEDOM|^LEDBLE|^Triones"#, nil, .smartHome, model: "LED light controller"),
        NamePattern(#"^Roku"#, "Roku", .tv),
        NamePattern(#"^\[LG\]|^LG "#, "LG", .tv),
        NamePattern(#"^HP |DeskJet|OfficeJet|LaserJet|ENVY"#, "HP", .computer, model: "printer")
    ]
}

// MARK: - Company IDs
/// A built-in subset of the Bluetooth SIG company identifier list: common
/// consumer brands plus the main chip makers (whose IDs say little about the
/// product brand).
enum CompanyIDs {
    struct Entry {
        let name: String
        let category: DeviceCategory?
        var isChipMaker = false
    }

    static func chip(_ name: String) -> Entry { Entry(name: name, category: nil, isChipMaker: true) }
    static func brand(_ name: String, _ category: DeviceCategory? = nil) -> Entry { Entry(name: name, category: category) }

    static let table: [UInt16: Entry] = [
        0x0000: brand("Ericsson"),
        0x0001: brand("Nokia", .phone),
        0x0002: chip("Intel"),
        0x0003: brand("IBM"),
        0x0004: brand("Toshiba"),
        0x0006: brand("Microsoft"),
        0x0008: brand("Motorola", .phone),
        0x0009: chip("Infineon"),
        0x000A: chip("Qualcomm (CSR)"),
        0x000D: chip("Texas Instruments"),
        0x000F: chip("Broadcom"),
        0x001D: chip("Qualcomm"),
        0x0025: chip("NXP Semiconductors"),
        0x0030: chip("STMicroelectronics"),
        0x003A: brand("Panasonic"),
        0x003C: brand("BlackBerry", .phone),
        0x0045: chip("Atheros"),
        0x0046: chip("MediaTek"),
        0x0047: chip("Bluegiga (Silicon Labs)"),
        0x0048: chip("Marvell"),
        0x004C: brand("Apple"),
        0x0055: brand("Plantronics (Poly)", .earbuds),
        0x0056: brand("Sony Ericsson", .phone),
        0x0057: brand("Harman (JBL, Harman Kardon)", .speaker),
        0x0058: brand("Vizio", .tv),
        0x0059: chip("Nordic Semiconductor"),
        0x005C: brand("Belkin"),
        0x005D: chip("Realtek"),
        0x0065: brand("HP", .computer),
        0x0067: brand("Jabra (GN Netcom)", .earbuds),
        0x0068: brand("General Motors", .car),
        0x006B: brand("Polar", .watch),
        0x0070: brand("Monster", .earbuds),
        0x0075: brand("Samsung"),
        0x0076: brand("Creative Technology", .speaker),
        0x0078: brand("Nike", .watch),
        0x0082: brand("Sennheiser", .earbuds),
        0x0087: brand("Garmin", .watch),
        0x0089: brand("GN ReSound (hearing aids)", .earbuds),
        0x008A: brand("Jawbone", .watch),
        0x0094: chip("Airoha"),
        0x009E: brand("Bose", .earbuds),
        0x009F: brand("Suunto", .watch),
        0x00A0: brand("Kensington", .keyboardMouse),
        0x00B9: brand("Johnson Controls", .car),
        0x00BA: brand("Starkey (hearing aids)", .earbuds),
        0x00C3: brand("adidas", .watch),
        0x00C4: brand("LG Electronics"),
        0x00CC: brand("Beats (Apple)", .earbuds),
        0x00CD: chip("Microchip"),
        0x00CE: brand("Eve Systems", .smartHome),
        0x00D0: brand("Dexcom (glucose monitor)"),
        0x00D2: chip("Dialog Semiconductor"),
        0x00D6: brand("Timex", .watch),
        0x00D7: chip("Qualcomm"),
        0x00D9: brand("Turtle Beach", .earbuds),
        0x00DF: brand("Misfit", .watch),
        0x00E0: brand("Google"),
        0x0100: brand("TomTom"),
        0x0103: brand("Bang & Olufsen", .speaker),
        0x0107: brand("Demant (Oticon hearing aids)", .earbuds),
        0x010E: brand("Audi", .car),
        0x010F: chip("HiSilicon (Huawei)"),
        0x0111: brand("SteelSeries", .keyboardMouse),
        0x011F: brand("Volkswagen", .car),
        0x0120: brand("Porsche", .car),
        0x012D: brand("Sony"),
        0x012E: brand("ASSA ABLOY (locks)", .smartHome),
        0x0131: chip("Cypress (Infineon)"),
        0x013A: brand("Tencent"),
        0x013C: chip("Murata"),
        0x014F: brand("Bowers & Wilkins", .earbuds),
        0x0150: brand("Pioneer", .car),
        0x0154: brand("Pebble", .watch),
        0x0155: brand("Netatmo", .smartHome),
        0x0157: brand("Huami (Amazfit, Mi Band)", .watch),
        0x015D: brand("Estimote", .beacon),
        0x0171: brand("Amazon"),
        0x0178: brand("Casio", .watch),
        0x017C: brand("Mercedes-Benz", .car),
        0x01AB: brand("Meta (Facebook)"),
        0x022B: brand("Tesla", .car),
        0x027D: brand("Huawei"),
        0x02E5: chip("Espressif"),
        0x038F: brand("Xiaomi"),
        0x0499: brand("Ruuvi", .smartHome),
        0x05A7: brand("Sonos", .speaker)
    ]
}

// MARK: - Member Service UUIDs
/// 16-bit service UUIDs that the Bluetooth SIG assigns to member companies or
/// that identify a well-known feature.
enum MemberServices {
    struct Entry {
        /// nil when the service identifies a feature used by many makers.
        let name: String?
        let category: DeviceCategory?
        let weight: Double
        let note: String
    }

    static let table: [String: Entry] = [
        "FEAA": Entry(name: "Google", category: .beacon, weight: 0.5, note: "Eddystone beacon (Google format)"),
        "FE2C": Entry(name: nil, category: .earbuds, weight: 0.6, note: "Google Fast Pair (Android accessory pairing)"),
        "FE9F": Entry(name: "Google", category: nil, weight: 0.6, note: "assigned to Google"),
        "FD6F": Entry(name: nil, category: .phone, weight: 0.6, note: "COVID exposure notification (Apple/Google phones)"),
        "FD44": Entry(name: "Apple (Find My network)", category: .tracker, weight: 0.7, note: "Find My network accessory"),
        "FEED": Entry(name: "Tile", category: .tracker, weight: 0.85, note: "assigned to Tile"),
        "FEEC": Entry(name: "Tile", category: .tracker, weight: 0.85, note: "assigned to Tile"),
        "FD5A": Entry(name: "Samsung", category: .tracker, weight: 0.8, note: "Samsung SmartTag"),
        "FE33": Entry(name: "Chipolo", category: .tracker, weight: 0.8, note: "assigned to Chipolo"),
        "FE95": Entry(name: "Xiaomi", category: .smartHome, weight: 0.7, note: "Xiaomi MiBeacon"),
        "FEE0": Entry(name: "Huami (Amazfit, Mi Band)", category: .watch, weight: 0.6, note: "Huami fitness band service"),
        "FEE7": Entry(name: "Tencent (WeChat)", category: nil, weight: 0.5, note: "WeChat device service"),
        "FE07": Entry(name: "Sonos", category: .speaker, weight: 0.7, note: "assigned to Sonos"),
        "FE03": Entry(name: "Amazon", category: .smartHome, weight: 0.6, note: "Amazon Alexa gadget"),
        "FE0F": Entry(name: "Philips Hue (Signify)", category: .smartHome, weight: 0.7, note: "assigned to Signify (Philips Hue)"),
        "FE9A": Entry(name: "Estimote", category: .beacon, weight: 0.7, note: "assigned to Estimote"),
        "FEBE": Entry(name: "Bose", category: .earbuds, weight: 0.7, note: "assigned to Bose"),
        "FE59": Entry(name: "Nordic Semiconductor", category: nil, weight: 0.2, note: "Nordic firmware update service (chip maker, many brands)")
    ]
}
