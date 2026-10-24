import XCTest
import SwiftUI
import MetalKit
import SGPlayer
@testable import SGPlayerUI

final class PackagePlaybackTests: XCTestCase {
    @MainActor
    func testInvalidModelInputIsReported() {
        let model = SGPlayerModel(resumeStore: nil)
        model.open(URL(fileURLWithPath: "/unused.mp4"), identifier: "")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.session)
        model.close()
    }

    #if os(macOS)
    // Drive the rendering pipeline explicitly so XCTest remains deterministic
    // while the display is occluded. Foreground acceptance is a separate real-app test.
    @MainActor
    private static func drawTestFrame(_ view: NSView) {
        if let metal = view as? MTKView { metal.draw() }
        view.subviews.forEach(drawTestFrame)
    }
    @MainActor
    func testSwiftUIPlaybackAndBundledFont() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let model = SGPlayerModel(resumeStore: nil)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        model.setCoverImage(try XCTUnwrap(context.makeImage()))
        model.setControlsAutoHideInterval(1.5)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "orientation", withExtension: "mp4", subdirectory: "Fixtures"))
        model.open(fixture, identifier: "package-orientation")
        let hosting = NSHostingView(rootView: SGPlayerView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { model.close(); window.close() }
        for _ in 0..<200 {
            if let controller = model.session?.controller, controller.presentedFrameCount >= 3 { break }
            Self.drawTestFrame(hosting)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let controller = try XCTUnwrap(model.session?.controller)
        XCTAssertGreaterThanOrEqual(controller.presentedFrameCount, 3)
        let font = try XCTUnwrap(controller.effects.subtitleFallbackFontURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: font.path))
        XCTAssertNil(model.error)
        model.pause()
        XCTAssertFalse(controller.playing)
        func findHost(_ view: NSView) -> SGPlayerHostView? {
            if let host = view as? SGPlayerHostView { return host }
            return view.subviews.lazy.compactMap(findHost).first
        }
        let host = try XCTUnwrap(findHost(hosting))
        XCTAssertEqual(try XCTUnwrap(host.subviews.compactMap { $0 as? SGPlaybackControls }.first).autoHideInterval, 1.5)
        model.close()
        XCTAssertNil(model.session)
        XCTAssertEqual(host.subviews.filter { $0 is SGPlaybackControls }.count, 0)
        model.open(fixture, identifier: "reopened-on-same-view")
        for _ in 0..<200 {
            if let next = model.session?.controller, next.presentedFrameCount >= 3 { break }
            Self.drawTestFrame(hosting)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let reopened = try XCTUnwrap(model.session?.controller)
        XCTAssertFalse(reopened === controller)
        XCTAssertEqual(host.subviews.filter { $0 is SGPlaybackControls }.count, 1)
        XCTAssertEqual(try XCTUnwrap(host.subviews.compactMap { $0 as? SGPlaybackControls }.first).autoHideInterval, 1.5)
        model.setCoverImage(nil)
        XCTAssertGreaterThanOrEqual(reopened.presentedFrameCount, 3)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testCachedMediaWithPreservedExtensionPlaysInBothKernels() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "orientation", withExtension: "mp4", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = directory.appendingPathComponent("verified-file.sgcache.mp4")
        try FileManager.default.copyItem(at: fixture, to: cached)
        for engine in [SGPlayerModel.Engine.ffmpeg, .native] {
            let model = SGPlayerModel(engine: engine, resumeStore: nil)
            model.open(cached, identifier: "cache-file")
            let host = NSHostingView(rootView: SGPlayerView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<200 {
                if let controller = model.session?.controller, controller.presentedFrameCount >= 3 { break }
                Self.drawTestFrame(host)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertGreaterThanOrEqual(model.session?.controller.presentedFrameCount ?? 0, 3, "Cached media must be sniffed by \(engine)")
            XCTAssertNil(model.error)
            model.close()
            window.close()
        }
    }
    #endif
}
