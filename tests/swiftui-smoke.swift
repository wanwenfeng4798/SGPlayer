import AppKit
import SwiftUI
import SGPlayer
import SGPlayerUI

@MainActor
final class Smoke: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: SGPlayerModel!
    var timer: Timer?
    var started = Date()
    var phase = 0
    var results: [[String: Any]] = []
    let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let cached = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sgcache.mp4")
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try FileManager.default.copyItem(at: fixture, to: cached) }
        catch { finish(false); return }
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }
    func load() {
        let engine: SGPlayerModel.Engine = phase == 3 ? .native : .ffmpeg
        model = SGPlayerModel(engine: engine, resumeStore: nil)
        model.open(phase == 0 ? fixture : cached, identifier: "smoke-\(phase)")
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SGPlayerView(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        started = Date()
    }
    func check() {
        let controller = model.session?.controller
        let frames = controller?.presentedFrameCount ?? 0
        guard frames >= 5 || Date().timeIntervalSince(started) > 25 else { return }
        let font = controller?.effects.subtitleFallbackFontURL
        let passed = frames >= 5 && model.state == .playing && model.error == nil && font.map { FileManager.default.fileExists(atPath: $0.path) } == true
        results.append(["case": ["swiftui-ffmpeg", "reopened-same-view", "cached-ffmpeg", "cached-native"][phase], "frames": frames, "passed": passed])
        if passed && phase == 0 {
            model.close()
            model.open(fixture, identifier: "reopened-same-view")
            phase = 1
            started = Date()
            return
        }
        model.close(); window.close()
        guard passed else { finish(false); return }
        phase += 1
        if phase == 4 { finish(true) } else { load() }
    }
    func finish(_ passed: Bool) {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: cached)
        let report: [String: Any] = ["passed": passed, "checks": results, "displayLoop": "NSApplication.run; automatic Metal rendering"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) }
        exit(passed ? 0 : 1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Smoke()
app.delegate = delegate
app.run()
