import ServiceManagement
import SwiftUI

/// The Settings window content. Sync settings bind straight to the defaults
/// domain (the AppDelegate's observers apply them live); the login item has
/// no change notification, so its state is re-read whenever the app
/// activates.
struct SettingsView: View {
    @AppStorage(Config.showMenuBarIconKey, store: Config.defaults) private var showMenuBarIcon = true
    @AppStorage(Config.clamshellKeysKey, store: Config.defaults) private var clamshellKeys = true
    @AppStorage(Config.minKey, store: Config.defaults) private var minLuminance = 0.0
    @AppStorage(Config.maxKey, store: Config.defaults) private var maxLuminance = 100.0
    @AppStorage(Config.gammaKey, store: Config.defaults) private var gamma = 1.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Label("Launch at Login", systemImage: "power")
                }
                .onChange(of: launchAtLogin) { _, enable in setLaunchAtLogin(enable) }
                Toggle(isOn: $showMenuBarIcon) {
                    Label("Show Menu Bar Icon", systemImage: "sun.max")
                }
                Toggle(isOn: $clamshellKeys) {
                    Label("Clamshell Brightness Keys", systemImage: "keyboard")
                }
            } footer: {
                Text("With the icon hidden, open BrightSync again to get back here. Clamshell keys need the Accessibility permission.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                slider("Minimum luminance", value: $minLuminance, in: 0...99, step: 1, display: "\(Int(minLuminance))%")
                    .onChange(of: minLuminance) { _, value in
                        if maxLuminance <= value { maxLuminance = value + 1 }
                    }
                slider("Maximum luminance", value: $maxLuminance, in: 1...100, step: 1, display: "\(Int(maxLuminance))%")
                    .onChange(of: maxLuminance) { _, value in
                        if minLuminance >= value { minLuminance = value - 1 }
                    }
                slider("Gamma", value: $gamma, in: 0.5...3, step: 0.05, display: String(format: "%.2f", gamma))
            } header: {
                Text("Brightness Mapping")
            } footer: {
                Text("External luminance range mapped to internal brightness 0-1. Gamma above 1 keeps the external display dimmer in the midrange; changes apply immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onAppear { syncLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLaunchAtLogin()
        }
    }

    private func slider(
        _ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
        step: Double, display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func syncLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        guard enable != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("launch at login toggle failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func showWindow() {
        UtilityWindow.show(id: "brightsync-settings", title: "BrightSync Settings", content: SettingsView())
    }
}
