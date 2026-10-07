//
//  AIAssistant.swift
//  BluesClues
//
//  Optional AI second opinion on "who made this device?". The user picks the
//  engine: Apple's on-device model, Apple's Private Cloud Compute model, or
//  their own provider and API key. There is no BlueClues server; requests go
//  straight from the phone to the engine the user chose, and only after the
//  user has seen exactly what will be sent.
//

import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Engine
enum AIEngine: String, CaseIterable, Identifiable {
    case off
    case onDevice
    case applePrivateCloud
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .onDevice: return "On this iPhone (Apple)"
        case .applePrivateCloud: return "Apple Private Cloud"
        case .custom: return "My own provider"
        }
    }

    /// Where the request goes, for the "this will be sent" preview.
    var destination: String {
        switch self {
        case .off: return "Nowhere"
        case .onDevice: return "Apple's model on this iPhone. Nothing leaves the phone."
        case .applePrivateCloud: return "Apple Private Cloud Compute (Apple's servers, not kept by Apple)."
        case .custom: return "Your provider"
        }
    }
}

// MARK: - Provider Format
enum AIProviderFormat: String, CaseIterable, Identifiable {
    case openAICompatible = "OpenAI-compatible"
    case anthropic = "Anthropic"

    var id: String { rawValue }

    var defaultEndpoint: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        }
    }

    var modelPlaceholder: String {
        switch self {
        case .openAICompatible: return "Model name, e.g. from your provider's docs"
        case .anthropic: return "claude-opus-5-5"
        }
    }
}

// MARK: - Suggestion
struct AIDeviceSuggestion: Equatable {
    let manufacturer: String?
    let category: DeviceCategory
    let model: String?
    let confidence: IdentificationConfidence
    let reasoning: String
    let source: String
}

enum AIAssistantError: LocalizedError {
    case off
    case unavailable(String)
    case badEndpoint
    case missingModel
    case http(Int, String)
    case refused
    case unreadableAnswer(String)

    var errorDescription: String? {
        switch self {
        case .off: return "The AI assistant is off. Turn it on in Settings."
        case .unavailable(let why): return why
        case .badEndpoint: return "The endpoint URL isn't valid."
        case .missingModel: return "Enter a model name in Settings."
        case .http(let code, let body): return "The provider returned an error (\(code)). \(body.prefix(300))"
        case .refused: return "The model declined to answer."
        case .unreadableAnswer(let text): return "Couldn't read the model's answer: \(text.prefix(300))"
        }
    }
}

// MARK: - AI Assistant
@MainActor
final class AIAssistant: ObservableObject {
    @Published var engine: AIEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Keys.engine) }
    }
    @Published var format: AIProviderFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: Keys.format) }
    }
    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Keys.endpoint) }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }
    @Published private(set) var hasAPIKey: Bool

    private enum Keys {
        static let engine = "aiEngine"
        static let format = "aiProviderFormat"
        static let endpoint = "aiEndpoint"
        static let model = "aiModel"
        static let keychainAccount = "ai-provider-api-key"
    }

    init() {
        let defaults = UserDefaults.standard
        engine = AIEngine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .off
        format = AIProviderFormat(rawValue: defaults.string(forKey: Keys.format) ?? "") ?? .openAICompatible
        endpoint = defaults.string(forKey: Keys.endpoint) ?? ""
        model = defaults.string(forKey: Keys.model) ?? ""
        hasAPIKey = Keychain.read(account: Keys.keychainAccount) != nil
    }

    // MARK: API key (Keychain, this device only, never synced or exported)
    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: Keys.keychainAccount)
        } else {
            Keychain.save(trimmed, account: Keys.keychainAccount)
        }
        hasAPIKey = !trimmed.isEmpty
    }

    private var apiKey: String? { Keychain.read(account: Keys.keychainAccount) }

    var resolvedEndpoint: String {
        let value = endpoint.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? format.defaultEndpoint : value
    }

    var destinationDescription: String {
        engine == .custom ? "\(format.rawValue) provider at \(URL(string: resolvedEndpoint)?.host ?? resolvedEndpoint)" : engine.destination
    }

    // MARK: Status
    /// A short line for Settings: whether the chosen engine can be used now.
    var statusText: String {
        switch engine {
        case .off:
            return "Off. Nothing is sent anywhere."
        case .onDevice:
            return Self.onDeviceStatus()
        case .applePrivateCloud:
            return Self.privateCloudStatus()
        case .custom:
            if model.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a model name." }
            return hasAPIKey ? "Ready." : "No API key saved (fine for a local server that doesn't need one)."
        }
    }

    // MARK: Ask
    func suggestIdentity(prompt: String) async throws -> AIDeviceSuggestion {
        switch engine {
        case .off:
            throw AIAssistantError.off
        case .onDevice:
            return try await Self.askApple(prompt: prompt, privateCloud: false)
        case .applePrivateCloud:
            return try await Self.askApple(prompt: prompt, privateCloud: true)
        case .custom:
            let text = try await askCustom(prompt: prompt)
            return try AIPrompts.parseSuggestion(text, source: "\(format.rawValue) · \(model)")
        }
    }

    // MARK: Custom providers
    private func askCustom(prompt: String) async throws -> String {
        let modelName = model.trimmingCharacters(in: .whitespaces)
        guard !modelName.isEmpty else { throw AIAssistantError.missingModel }
        switch format {
        case .openAICompatible:
            return try await askOpenAICompatible(prompt: prompt, model: modelName)
        case .anthropic:
            return try await askAnthropic(prompt: prompt, model: modelName)
        }
    }

    private func askOpenAICompatible(prompt: String, model: String) async throws -> String {
        var base = resolvedEndpoint
        while base.hasSuffix("/") { base.removeLast() }
        let urlString = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: urlString), url.scheme != nil else { throw AIAssistantError.badEndpoint }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": AIPrompts.instructions],
                ["role": "user", "content": prompt]
            ]
        ])

        let json = try await send(request)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIAssistantError.unreadableAnswer(String(describing: json))
        }
        return content
    }

    /// Anthropic Messages API over raw HTTP (there is no official Swift SDK).
    private func askAnthropic(prompt: String, model: String) async throws -> String {
        var base = resolvedEndpoint
        while base.hasSuffix("/") { base.removeLast() }
        let urlString = base.hasSuffix("/v1/messages") ? base : base + "/v1/messages"
        guard let url = URL(string: urlString), url.scheme != nil else { throw AIAssistantError.badEndpoint }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 4000,
            "system": AIPrompts.instructions,
            "messages": [["role": "user", "content": prompt]]
        ])

        let json = try await send(request)
        if json["stop_reason"] as? String == "refusal" { throw AIAssistantError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIAssistantError.unreadableAnswer(String(describing: json)) }
        return text
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIAssistantError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAssistantError.unreadableAnswer(String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }

    // MARK: Apple models
    private static func onDeviceStatus() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Ready. Runs on this iPhone, free and offline."
            case .unavailable(.deviceNotEligible): return "This iPhone doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in the Settings app."
            case .unavailable(.modelNotReady): return "Apple's model is still downloading. Try again later."
            case .unavailable: return "Apple's model isn't available right now."
            }
        }
        #endif
        return "Needs iOS 26 or later."
    }

    private static func privateCloudStatus() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                let usage = model.quotaUsage
                if usage.isLimitReached {
                    let reset = usage.resetDate.map { " Resets \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                    return "Apple's usage limit is reached.\(reset)"
                }
                if case .belowLimit(let below) = usage.status, below.isApproachingLimit {
                    return "Ready, but getting close to Apple's usage limit."
                }
                return "Ready. Free within Apple's usage limit."
            case .unavailable(.deviceNotEligible): return "This iPhone can't use Apple Private Cloud."
            case .unavailable: return "Apple Private Cloud isn't ready right now."
            }
        }
        #endif
        return "Needs iOS 27 or later."
    }

    private static func askApple(prompt: String, privateCloud: Bool) async throws -> AIDeviceSuggestion {
        #if canImport(FoundationModels)
        if privateCloud {
            if #available(iOS 27.0, *) {
                let model = PrivateCloudComputeLanguageModel()
                guard model.isAvailable else { throw AIAssistantError.unavailable(privateCloudStatus()) }
                let session = LanguageModelSession(model: model, instructions: AIPrompts.instructions)
                let response = try await session.respond(to: prompt, generating: AppleDeviceGuess.self)
                return response.content.suggestion(source: "Apple Private Cloud")
            }
        } else if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw AIAssistantError.unavailable(onDeviceStatus())
            }
            let session = LanguageModelSession(instructions: AIPrompts.instructions)
            let response = try await session.respond(to: prompt, generating: AppleDeviceGuess.self)
            return response.content.suggestion(source: "Apple on-device model")
        }
        #endif
        throw AIAssistantError.unavailable(privateCloud ? privateCloudStatus() : onDeviceStatus())
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct AppleDeviceGuess {
    @Guide(description: "Company that most likely made the device, or an empty string if it can't be told")
    var manufacturer: String
    @Guide(description: "Device type", .anyOf(DeviceCategory.allCases.map(\.rawValue)))
    var deviceType: String
    @Guide(description: "Product or model name if it can be told, otherwise an empty string")
    var model: String
    @Guide(description: "How sure you are", .anyOf(["low", "medium", "high"]))
    var confidence: String
    @Guide(description: "One or two sentences explaining which clues support the answer")
    var reasoning: String

    func suggestion(source: String) -> AIDeviceSuggestion {
        AIPrompts.suggestion(manufacturer: manufacturer, deviceType: deviceType, model: model,
                             confidence: confidence, reasoning: reasoning, source: source)
    }
}
#endif

// MARK: - Prompts
enum AIPrompts {
    static let instructions = """
    You identify Bluetooth Low Energy devices from their advertisement data for a personal \
    safety app. Use only the advertisement data and the app's built-in clues you are given. \
    Bluetooth SIG company IDs in manufacturer data are little-endian (bytes 4C 00 mean 0x004C, Apple). \
    A chip maker's ID (Nordic, Realtek, Qualcomm, Espressif and similar) does not reveal the product brand. \
    If the data doesn't support an answer, say so with low confidence instead of guessing. \
    Answer with a single JSON object and nothing else: \
    {"manufacturer": string or null, "device_type": one of [\(DeviceCategory.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))], \
    "model": string or null, "confidence": "low" | "medium" | "high", "reasoning": string}
    """

    /// The exact text sent to the model: broadcast contents and the app's own
    /// guesses only. No location, times, signal strength or device IDs.
    static func devicePrompt(fields: AdvertisementFields, candidates: [ManufacturerCandidate], includeName: Bool) -> String {
        var lines = ["Bluetooth advertisement:"]
        if let data = fields.manufacturerData {
            lines.append("- Manufacturer data (hex): " + data.map { String(format: "%02X", $0) }.joined(separator: " "))
            if let company = fields.companyID { lines.append(String(format: "- Company ID: 0x%04X", company)) }
        } else {
            lines.append("- Manufacturer data: none")
        }
        lines.append("- Advertised services: " + (fields.serviceUUIDs.isEmpty ? "none" : fields.serviceUUIDs.joined(separator: ", ")))
        lines.append("- Service data for: " + (fields.serviceDataUUIDs.isEmpty ? "none" : fields.serviceDataUUIDs.joined(separator: ", ")))
        if let name = fields.localName, !name.isEmpty {
            lines.append("- Name: " + (includeName ? name : "(withheld by the user)"))
        } else {
            lines.append("- Name: none")
        }
        if let txPower = fields.txPower { lines.append("- Tx power: \(txPower) dBm") }

        if candidates.isEmpty {
            lines.append("\nThe app's built-in rules found no clues.")
        } else {
            lines.append("\nThe app's built-in guesses:")
            for candidate in candidates {
                let label = DeviceIdentity(manufacturer: candidate.manufacturer, category: candidate.category,
                                           model: candidate.model, confidence: candidate.confidence, evidence: []).label
                lines.append("- \(label) (\(candidate.confidence.rawValue.lowercased())): " + candidate.evidence.joined(separator: "; "))
            }
        }
        lines.append("\nWho most likely made this device, and what kind of device is it?")
        return lines.joined(separator: "\n")
    }

    /// Reads the JSON answer from a text reply, tolerating surrounding prose
    /// or a Markdown code fence.
    static func parseSuggestion(_ text: String, source: String) throws -> AIDeviceSuggestion {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAssistantError.unreadableAnswer(text)
        }
        return suggestion(manufacturer: json["manufacturer"] as? String,
                          deviceType: json["device_type"] as? String ?? json["deviceType"] as? String,
                          model: json["model"] as? String,
                          confidence: json["confidence"] as? String,
                          reasoning: json["reasoning"] as? String ?? "",
                          source: source)
    }

    static func suggestion(manufacturer: String?, deviceType: String?, model: String?,
                           confidence: String?, reasoning: String, source: String) -> AIDeviceSuggestion {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  !["null", "none", "unknown", "n/a"].contains(value.lowercased()) else { return nil }
            return value
        }
        let category = DeviceCategory.allCases.first { $0.rawValue.lowercased() == deviceType?.lowercased() } ?? .unknown
        let level: IdentificationConfidence
        switch confidence?.lowercased() {
        case "high": level = .high
        case "medium": level = .medium
        default: level = .low
        }
        return AIDeviceSuggestion(manufacturer: clean(manufacturer), category: category, model: clean(model),
                                  confidence: level, reasoning: reasoning, source: source)
    }
}

// MARK: - Keychain
enum Keychain {
    private static let service = "BlueClues"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // Stays on this iPhone: not in backups to other devices, not in iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
