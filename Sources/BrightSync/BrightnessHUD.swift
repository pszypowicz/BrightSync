import AppKit
import CoreGraphics

/// Small self-drawn brightness overlay for clamshell key presses. The native
/// OSD is not used: on macOS 26 it stopped rendering fill levels for
/// third-party callers, so the daemon shows its own short-lived pill - a sun
/// icon that distinguishes brightening from darkening plus the luminance
/// percentage, fading in and out quickly. Main queue only.
enum BrightnessHUD {
    private static let size = NSSize(width: 150, height: 56)
    private static let visibleFor: TimeInterval = 0.7

    // Created lazily on first show; touched only on the main queue.
    nonisolated(unsafe) private static var panel: NSPanel?
    nonisolated(unsafe) private static var icon: NSImageView?
    nonisolated(unsafe) private static var label: NSTextField?
    nonisolated(unsafe) private static var hideWork: DispatchWorkItem?

    static func show(percent: Double, brightening: Bool, on display: CGDirectDisplayID) {
        let panel = panel ?? makePanel()
        icon?.image = NSImage(
            systemSymbolName: brightening ? "sun.max.fill" : "sun.min.fill",
            accessibilityDescription: nil)
        label?.stringValue = "\(Int(percent.rounded())) %"

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == display
        } ?? NSScreen.main
        if let screen {
            panel.setFrameOrigin(NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.minY + 140))
        }

        hideWork?.cancel()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                // Skip the hide if a newer show already raised the alpha.
                if panel.alphaValue < 0.01 { panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        newPanel.level = .screenSaver
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.isReleasedWhenClosed = false
        newPanel.alphaValue = 0

        let bounds = NSRect(origin: .zero, size: size)
        let glass = NSGlassEffectView(frame: bounds)
        glass.cornerRadius = size.height / 2
        let content = NSView(frame: bounds)
        glass.contentView = content
        newPanel.contentView = glass

        let imageView = NSImageView(
            frame: NSRect(x: 22, y: (size.height - 28) / 2, width: 28, height: 28))
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        imageView.contentTintColor = .labelColor
        content.addSubview(imageView)

        let textField = NSTextField(labelWithString: "")
        textField.frame = NSRect(
            x: 60, y: (size.height - 28) / 2, width: size.width - 72, height: 28)
        textField.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        textField.textColor = .labelColor
        textField.alignment = .center
        content.addSubview(textField)

        panel = newPanel
        icon = imageView
        label = textField
        return newPanel
    }
}
