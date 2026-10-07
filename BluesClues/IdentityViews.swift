//
//  IdentityViews.swift
//  BluesClues
//
//  The "Who made this?" card on the device detail screen: the current
//  answer, ranked suggestions with their evidence, manual entry, and the raw
//  advertisement the guesses came from.
//

import SwiftUI

struct IdentitySection: View {
    @ObservedObject var device: BluetoothDevice
    @ObservedObject var deviceService: DeviceService
    @EnvironmentObject var ai: AIAssistant
    @State private var enteringOwn = false
    @State private var showingRaw = false
    @State private var askingAI = false

    var body: some View {
        let identity = device.storedIdentity
        let candidates = deviceService.manufacturerCandidates(for: device)
        let lookalikes = deviceService.devicesSharingSignature(with: device)

        VStack(alignment: .leading, spacing: 12) {
            Text("Who made this?")
                .font(.headline)

            HStack(alignment: .firstTextBaseline) {
                Text(identity.label)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                ConfidenceBadge(confidence: identity.confidence)
            }
            if identity.confidence != .confirmed {
                ForEach(identity.evidence, id: \.self) { line in
                    Label(line, systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if identity.confidence == .confirmed {
                Button("Go back to automatic guess") {
                    deviceService.clearConfirmedIdentity(uuid: device.uuid ?? "")
                }
                .font(.subheadline)
                if !lookalikes.isEmpty {
                    Button {
                        deviceService.applyConfirmedIdentity(from: device, to: lookalikes)
                    } label: {
                        Label("Apply to \(lookalikes.count) other device\(lookalikes.count == 1 ? "" : "s") with the same signature",
                              systemImage: "square.on.square")
                    }
                    .font(.subheadline)
                    Text("Phones and earbuds change their Bluetooth address, so the same device may be saved more than once. Devices with the same signature might also just be the same model.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if !candidates.isEmpty {
                Divider()
                Text("Suggestions")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ForEach(candidates) { candidate in
                    CandidateRow(candidate: candidate) {
                        deviceService.confirmIdentity(uuid: device.uuid ?? "",
                                                      manufacturer: candidate.manufacturer,
                                                      category: candidate.category,
                                                      model: candidate.model)
                    }
                }
            } else if identity.confidence != .confirmed {
                Text("This device doesn't advertise anything that identifies its maker.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
            HStack {
                Button {
                    enteringOwn = true
                } label: {
                    Label("Enter it myself", systemImage: "pencil")
                }
                Spacer()
                Button {
                    askingAI = true
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                }
                .disabled(ai.engine == .off || device.advertisementFields == nil)
            }
            .font(.subheadline)
            if ai.engine == .off {
                Text("Turn on the AI assistant in Settings to ask for a second opinion.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            DisclosureGroup("Raw advertisement", isExpanded: $showingRaw) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.advertisementFields?.rawDescription ?? "Not recorded yet")
                    if let key = device.signatureKey {
                        Text("Signature: \(key)")
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.subheadline)
        }
        .sheet(isPresented: $enteringOwn) {
            ManualIdentityView(device: device, deviceService: deviceService)
        }
        .sheet(isPresented: $askingAI) {
            AskAIView(device: device, deviceService: deviceService)
        }
    }
}

// MARK: - Candidate Row
private struct CandidateRow: View {
    let candidate: ManufacturerCandidate
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(DeviceIdentity(manufacturer: candidate.manufacturer, category: candidate.category,
                                    model: candidate.model, confidence: candidate.confidence, evidence: []).label)
                    .font(.subheadline)
                Spacer()
                ConfidenceBadge(confidence: candidate.confidence)
                Button("This is it", action: onConfirm)
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            ForEach(candidate.evidence, id: \.self) { line in
                Text("• \(line)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Confidence Badge
struct ConfidenceBadge: View {
    let confidence: IdentificationConfidence

    var body: some View {
        Text(confidence.rawValue)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var color: Color {
        switch confidence {
        case .low: return .secondary
        case .medium: return .orange
        case .high: return .green
        case .confirmed: return .blue
        }
    }
}

// MARK: - Manual Identity
struct ManualIdentityView: View {
    let device: BluetoothDevice
    let deviceService: DeviceService
    @Environment(\.dismiss) private var dismiss
    @State private var manufacturer = ""
    @State private var model = ""
    @State private var category: DeviceCategory = .unknown

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Your answer replaces the automatic guess for this device.")) {
                    TextField("Manufacturer (e.g. Samsung)", text: $manufacturer)
                    TextField("Model (optional)", text: $model)
                    Picker("Type", selection: $category) {
                        ForEach(DeviceCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                }
            }
            .navigationTitle("Who made this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let maker = manufacturer.trimmingCharacters(in: .whitespaces)
                        let modelName = model.trimmingCharacters(in: .whitespaces)
                        deviceService.confirmIdentity(uuid: device.uuid ?? "",
                                                      manufacturer: maker.isEmpty ? nil : maker,
                                                      category: category,
                                                      model: modelName.isEmpty ? nil : modelName)
                        dismiss()
                    }
                    .disabled(manufacturer.trimmingCharacters(in: .whitespaces).isEmpty && category == .unknown)
                }
            }
            .onAppear {
                let identity = device.storedIdentity
                manufacturer = identity.manufacturer ?? ""
                model = identity.model ?? ""
                category = identity.category
            }
        }
    }
}

// MARK: - Ask AI
/// Shows exactly what will be sent and where, sends only on request, and
/// lets the user accept the answer as the device's identity.
struct AskAIView: View {
    let device: BluetoothDevice
    let deviceService: DeviceService
    @EnvironmentObject var ai: AIAssistant
    @Environment(\.dismiss) private var dismiss
    @State private var includeName = true
    @State private var isSending = false
    @State private var suggestion: AIDeviceSuggestion?
    @State private var errorText: String?

    private var fields: AdvertisementFields { device.advertisementFields ?? AdvertisementFields() }

    private var prompt: String {
        AIPrompts.devicePrompt(fields: fields,
                               candidates: deviceService.manufacturerCandidates(for: device),
                               includeName: includeName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Sent to")) {
                    Text(ai.destinationDescription)
                }

                if let name = fields.localName, !name.isEmpty {
                    Section(footer: Text("Device names can be personal (like \"Jane's AirPods\"). Leave it out if you'd rather not share it.")) {
                        Toggle("Include the name \"\(name)\"", isOn: $includeName)
                    }
                }

                Section(header: Text("Exactly what will be sent"),
                        footer: Text("No locations, times, signal strengths or device IDs are sent.")) {
                    Text(prompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let suggestion {
                    Section(header: Text("AI suggestion")) {
                        HStack {
                            Text(DeviceIdentity(manufacturer: suggestion.manufacturer, category: suggestion.category,
                                                model: suggestion.model, confidence: suggestion.confidence, evidence: []).label)
                                .font(.headline)
                            Spacer()
                            ConfidenceBadge(confidence: suggestion.confidence)
                        }
                        if !suggestion.reasoning.isEmpty {
                            Text(suggestion.reasoning).font(.subheadline)
                        }
                        Text("From \(suggestion.source). AI can be wrong; only accept it if it fits.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Use this answer") {
                            deviceService.confirmIdentity(uuid: device.uuid ?? "",
                                                          manufacturer: suggestion.manufacturer,
                                                          category: suggestion.category,
                                                          model: suggestion.model)
                            dismiss()
                        }
                        .disabled(suggestion.manufacturer == nil && suggestion.category == .unknown)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button(suggestion == nil ? "Send" : "Ask again") { send() }
                    }
                }
            }
        }
    }

    private func send() {
        isSending = true
        errorText = nil
        let text = prompt
        Task {
            do {
                suggestion = try await ai.suggestIdentity(prompt: text)
            } catch {
                errorText = error.localizedDescription
            }
            isSending = false
        }
    }
}
