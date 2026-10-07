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
    @State private var enteringOwn = false
    @State private var showingRaw = false

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
            Button {
                enteringOwn = true
            } label: {
                Label("Enter it myself", systemImage: "pencil")
            }
            .font(.subheadline)

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
