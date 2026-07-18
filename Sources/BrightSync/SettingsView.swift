import ApplicationServices
import ServiceManagement
import SwiftUI

// A hover affordance for the settings whose meaning is not obvious from
// the label. The native help tooltip takes over a second to appear and
// cannot be styled, so the info circle presents a popover after a short
// hover delay instead.
private struct InfoDot: View {
    let text: String
    init(_ text: String) { self.text = text }

    @State private var shown = false
    @State private var hoverDelay: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .onHover { inside in
                hoverDelay?.cancel()
                if inside {
                    hoverDelay = Task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        shown = true
                    }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
            }
    }
}

/// The Settings window content. Sync settings bind straight to the defaults
/// domain (the AppDelegate's observers apply them live); the login item and
/// the Accessibility grant have no change notifications, so both are
/// re-read whenever the app activates.
struct SettingsView: View {
    @AppStorage(Config.showMenuBarIconKey, store: Config.defaults) private var showMenuBarIcon = true
    @AppStorage(Config.clamshellKeysKey, store: Config.defaults) private var clamshellKeys = true
    @AppStorage(Config.minKey, store: Config.defaults) private var minLuminance = 0.0
    @AppStorage(Config.maxKey, store: Config.defaults) private var maxLuminance = 100.0
    @AppStorage(Config.gammaKey, store: Config.defaults) private var gamma = 1.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = AXIsProcessTrusted()

    var body: some View {
        Form {
            generalSection
            mappingSection
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onAppear { refreshExternalState() }
        // System Settings is a second writer of the login-item and
        // Accessibility state, and neither offers a change notification, so
        // both are re-read at the moments the user can next see them:
        // changing them over there deactivates this app, and both returning
        // here and reopening the window activate it again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshExternalState()
        }
    }

    private var generalSection: some View {
        Section {
            Toggle(isOn: $launchAtLogin) {
                Label("Launch at Login", systemImage: "power")
            }
            .onChange(of: launchAtLogin) { _, enable in setLaunchAtLogin(enable) }
            Toggle(isOn: $showMenuBarIcon) {
                HStack(spacing: 4) {
                    Label("Show Menu Bar Icon", systemImage: "sun.max")
                    InfoDot("BrightSync keeps running without the icon. To get back here, launch BrightSync again - reopening the app always shows this window.")
                }
            }
            Toggle(isOn: $clamshellKeys) {
                HStack(spacing: 4) {
                    Label("Clamshell Brightness Keys", systemImage: "keyboard")
                    InfoDot("Keeps the brightness keys working with the lid closed: an event tap steps the external displays through the mapping curve and shows an overlay. Needs the Accessibility permission; enabling prompts for it.")
                }
            }
            if clamshellKeys, !accessibilityGranted {
                HStack(spacing: 4) {
                    Text("Accessibility not granted - clamshell keys are inactive.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Pane") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var mappingSection: some View {
        Section("Brightness Mapping") {
            slider("Minimum luminance", value: $minLuminance, in: 0...99, step: 1,
                   display: "\(Int(minLuminance))%",
                   info: "External luminance written when the built-in brightness is at zero. Raise it if the display gets too dark at the low end.")
                .onChange(of: minLuminance) { _, value in
                    if maxLuminance <= value { maxLuminance = value + 1 }
                }
            slider("Maximum luminance", value: $maxLuminance, in: 1...100, step: 1,
                   display: "\(Int(maxLuminance))%",
                   info: "External luminance written when the built-in brightness is at full.")
                .onChange(of: maxLuminance) { _, value in
                    if minLuminance >= value { minLuminance = value - 1 }
                }
            slider("Gamma", value: $gamma, in: 0.5...3, step: 0.05,
                   display: String(format: "%.2f", gamma),
                   info: "Curve exponent between the two ends: above 1 keeps the external display dimmer in the midrange, below 1 keeps it brighter. Changes apply immediately, so tune it by eye.")
        }
    }

    private func slider(
        _ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
        step: Double, display: String, info: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                InfoDot(info)
                Spacer()
                Text(display)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func refreshExternalState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityGranted = AXIsProcessTrusted()
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
