//
//  SettingsSections.swift
//  BluesClues
//
//  Settings for the AI assistant and iCloud sync.
//

import SwiftUI

// MARK: - AI Assistant Settings
struct AISettingsSection: View {
    @EnvironmentObject var ai: AIAssistant
    @State private var keyDraft = ""

    var body: some View {
        Section(header: Text("AI assistant"),
                footer: Text(footer)) {
            Picker("Engine", selection: $ai.engine) {
                ForEach(AIEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            Text(ai.statusText)
                .font(.footnote)
                .foregroundColor(.secondary)

            if ai.engine == .custom {
                Picker("API style", selection: $ai.format) {
                    ForEach(AIProviderFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                TextField(ai.format.defaultEndpoint, text: $ai.endpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(ai.format.modelPlaceholder, text: $ai.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    SecureField(ai.hasAPIKey ? "API key saved" : "API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(keyDraft.isEmpty && ai.hasAPIKey ? "Remove" : "Save") {
                        ai.setAPIKey(keyDraft)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.isEmpty && !ai.hasAPIKey)
                }
            }
        }
    }

    private var footer: String {
        switch ai.engine {
        case .off:
            return "BlueClues identifies devices on the phone with its built-in rules. Turn this on for a second opinion you ask for one device at a time."
        case .onDevice:
            return "Uses Apple Intelligence on this iPhone. Free, works offline, nothing leaves the phone. It's a small model, so treat its answers as hints."
        case .applePrivateCloud:
            return "Uses Apple's larger model on Private Cloud Compute. No API key; free within Apple's usage limit. Apple processes the request without keeping it."
        case .custom:
            return "Requests go straight from this iPhone to your provider. BlueClues has no server and never sees them. Your API key stays in this iPhone's Keychain and is never synced or exported. OpenAI-compatible covers OpenAI, OpenRouter and local servers such as Ollama or LM Studio (use their http://<computer>:<port>/v1 address)."
        }
    }
}

// MARK: - iCloud Settings
struct ICloudSettingsSection: View {
    @EnvironmentObject var monitor: CloudSyncMonitor
    @State private var enabled = CloudSync.isEnabled

    var body: some View {
        Section(header: Text("iCloud"), footer: Text(footer)) {
            Toggle("Sync with iCloud", isOn: $enabled)
                .disabled(!CloudSync.isAvailableInThisBuild)
                .onChange(of: enabled) { _, newValue in CloudSync.isEnabled = newValue }

            if enabled != monitor.isActive && CloudSync.isAvailableInThisBuild {
                Label("Close and reopen BlueClues to \(enabled ? "start" : "stop") syncing.", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            if monitor.isActive {
                if let account = monitor.accountStatus {
                    Text(account).font(.footnote).foregroundColor(.secondary)
                }
                if let error = monitor.lastError {
                    Text("Last sync error: \(error)").font(.footnote).foregroundColor(.red)
                } else if let date = monitor.lastSuccess {
                    Text("Last synced \(date.formatted(date: .omitted, time: .shortened))").font(.footnote).foregroundColor(.secondary)
                } else {
                    Text("Waiting for the first sync…").font(.footnote).foregroundColor(.secondary)
                }
            }
        }
    }

    private var footer: String {
        guard CloudSync.isAvailableInThisBuild else {
            return "iCloud sync isn't available in this build. It needs a version of BlueClues signed with a paid Apple Developer account (for example from the App Store or TestFlight). Your data stays on this iPhone."
        }
        return "Syncs devices, labels, logs and sightings (including where they were seen) to your own private iCloud database, so your other iPhones and iPads with BlueClues stay up to date. Only you can read it. AI keys and settings are not synced."
    }
}
