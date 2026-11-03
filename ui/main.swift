// main.swift — AppKit menu-bar UI (no SwiftUI; builds on Command Line Tools).
// Status-bar speaker icon -> popover menu with a slider per audio app.

import AppKit

// one menu row: name | slider 0..200% | % | reset
final class RowView: NSView {
    private let engine: MixerEngine
    private let app: AudioApp
    private let pct = NSTextField(labelWithString: "")

    init(app: AudioApp, engine: MixerEngine) {
        self.app = app; self.engine = engine
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 30))

        let icon = NSImageView(frame: NSRect(x: 12, y: 5, width: 20, height: 20))
        icon.image = NSRunningApplication(processIdentifier: app.pid)?.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let name = NSTextField(labelWithString: app.name)
        name.frame = NSRect(x: 38, y: 6, width: 126, height: 18)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)

        let knob = engine.knob(app)
        let slider = NSSlider(value: Double(knob), minValue: 0, maxValue: 2,
                              target: self, action: #selector(changed(_:)))
        slider.frame = NSRect(x: 170, y: 4, width: 170, height: 20)
        slider.isContinuous = true
        addSubview(slider)

        pct.stringValue = "\(Int((knob * 100).rounded()))%"
        pct.alignment = .right
        pct.frame = NSRect(x: 344, y: 6, width: 44, height: 18)
        pct.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        addSubview(pct)

        let reset = NSButton(title: "Reset", target: self, action: #selector(doReset))
        reset.frame = NSRect(x: 392, y: 2, width: 52, height: 24)
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        addSubview(reset)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func changed(_ s: NSSlider) {
        engine.setKnob(app, Float(s.doubleValue))
        pct.stringValue = "\(Int((s.doubleValue * 100).rounded()))%"
    }
    @objc private func doReset() {
        engine.setKnob(app, 1.0)
        if let s = subviews.compactMap({ $0 as? NSSlider }).first { s.doubleValue = 1.0 }
        pct.stringValue = "100%"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = MixerEngine()
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "AppVolume")
            b.imagePosition = .imageLeading
            b.title = "AV"            // text so it can't vanish behind the notch unseen
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // rebuild the menu each time it opens, from the live app list
    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.refresh()
        menu.removeAllItems()

        let header = NSMenuItem(title: "Per-app volume", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if engine.apps.isEmpty {
            let empty = NSMenuItem(title: "No apps playing audio", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for app in engine.apps {
                let item = NSMenuItem()
                item.view = RowView(app: app, engine: engine)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit AppVolume", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc func quit() { engine.stopAll(); NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
