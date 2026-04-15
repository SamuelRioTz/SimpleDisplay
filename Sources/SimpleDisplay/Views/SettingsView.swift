import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(DisplayManagerViewModel.self) private var viewModel
    @State private var launchAtLogin: Bool = false
    @State private var loginItemNeedsApproval: Bool = false
    @State private var cleanupResult: String?
    @State private var showCleanConfirmation: Bool = false
    @State private var ghostCount: Int = 0
    /// Prevents onChange from firing during initial onAppear value loading
    @State private var didLoadInitialValues: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.navigate(to: .displayList)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isNavigating)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            VStack(spacing: 0) {
                // About card at top
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 48, height: 48)
                        Image(systemName: "display")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SimpleDisplay")
                            .font(.system(.body, weight: .semibold))
                        Text(verbatim: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)

                // Settings rows
                VStack(spacing: 1) {
                    // Launch at login
                    settingsRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: $launchAtLogin) {
                                HStack(spacing: 10) {
                                    settingsIcon("power", color: .green)
                                    Text("Launch at login")
                                        .font(.callout)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: launchAtLogin) { _, newValue in
                                guard didLoadInitialValues else { return }
                                setLaunchAtLogin(newValue)
                            }

                            if loginItemNeedsApproval {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.orange)
                                    Text("Requires approval in System Settings > General > Login Items")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                .padding(.leading, 36)
                            }
                        }
                    }

                    // Clean cache
                    if showCleanConfirmation {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(verbatim: "Clean \(ghostCount) cached profiles?")
                                    .font(.callout).fontWeight(.medium)
                            }
                            Text("Removes all cached display color profiles and resets display preferences. Requires admin password. Restart recommended after.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    withAnimation { showCleanConfirmation = false }
                                }
                                .font(.caption)
                                Button(role: .destructive) {
                                    cleanSystemCache()
                                    showCleanConfirmation = false
                                } label: {
                                    Text(verbatim: "Clean").font(.caption).fontWeight(.medium)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)
                    } else {
                        settingsRow {
                            Button {
                                ghostCount = countGhostProfiles()
                                withAnimation { showCleanConfirmation = true }
                            } label: {
                                HStack(spacing: 10) {
                                    settingsIcon("paintbrush.fill", color: .red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Clean display cache")
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                        if let result = cleanupResult {
                                            Text(verbatim: result)
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else {
                                            Text(verbatim: "Remove all cached display profiles. Fixes color issues.")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Website
                    settingsRow {
                        if let url = URL(string: "https://simpledisplay.app") {
                            Link(destination: url) {
                                HStack(spacing: 10) {
                                    settingsIcon("globe", color: .blue)
                                    Text(verbatim: "Website")
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(verbatim: "simpledisplay.app")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    // Contact
                    settingsRow {
                        if let url = URL(string: "mailto:hello@simpledisplay.app") {
                            Link(destination: url) {
                                HStack(spacing: 10) {
                                    settingsIcon("envelope.fill", color: .indigo)
                                    Text(verbatim: "Contact")
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(verbatim: "hello@simpledisplay.app")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)

                // Footer
                Text(verbatim: "macOS 14+ \u{2022} Apple Silicon & Intel")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled
            loginItemNeedsApproval = status == .requiresApproval
            DispatchQueue.main.async {
                didLoadInitialValues = true
            }
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private func settingsIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 26, height: 26)
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private func cleanSystemCache() {
        let profilesDir = "/Library/ColorSync/Profiles/Displays"

        let allowedChars = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: ".-_()\""))
        var filesToRemove: [String] = []
        if let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
            for file in files where file.hasSuffix(".icc") {
                if file.unicodeScalars.allSatisfy({ allowedChars.contains($0) }) {
                    filesToRemove.append(file)
                }
            }
        }

        guard !filesToRemove.isEmpty else {
            cleanupResult = "No cached profiles found."
            return
        }

        let rmCommands = filesToRemove.map { file in
            let path = "\(profilesDir)/\(file)"
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "rm -f '\(escaped)'"
        }
        let fullCmd = (rmCommands + [
            "rm -f /Library/Preferences/com.apple.windowserver.displays.plist"
        ]).joined(separator: " && ")

        let scriptCmd = fullCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(scriptCmd)\" with administrator privileges"

        var error: NSDictionary?
        if let scriptObj = NSAppleScript(source: appleScript) {
            scriptObj.executeAndReturnError(&error)
            if let error {
                let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                if msg.contains("cancel") || msg.contains("Cancel") {
                    cleanupResult = nil
                } else {
                    cleanupResult = "Error: \(msg)"
                }
            } else {
                cleanupResult = "Cleaned \(filesToRemove.count) profiles. Restart recommended."
            }
        }
    }

    private func countGhostProfiles() -> Int {
        let profilesDir = "/Library/ColorSync/Profiles/Displays"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else { return 0 }
        return files.filter { $0.hasSuffix(".icc") }.count
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let status = SMAppService.mainApp.status
            loginItemNeedsApproval = status == .requiresApproval
        } catch {
            viewModel.errorMessage = "Failed to update login item: \(error.localizedDescription)"
            launchAtLogin = !enabled
        }
    }
}
