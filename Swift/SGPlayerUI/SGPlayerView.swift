import SwiftUI
import CoreGraphics
import SGPlayer

@MainActor
public final class SGPlayerModel: ObservableObject {
    public enum Engine: Int { case ffmpeg, native }
    public enum State: Int { case idle, loading, playing, paused, buffering, ended, failed }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var error: Error?
    public private(set) var session: SGPlaybackSession?
    private var source: (url: URL, identifier: String, title: String)?
    private weak var hostView: SGPlayerHostView?
    private var controls: SGPlaybackControls?
    private var coverImage: CGImage?
    private var controlsIdleInterval: TimeInterval = 0
    private var boundView: ObjectIdentifier?
    private let engine: Engine
    private let resumeStore: UserDefaults?

    public init(engine: Engine = .ffmpeg, resumeStore: UserDefaults? = .standard) {
        self.engine = engine
        self.resumeStore = resumeStore
    }

    /// Supply a stable identifier independent of signed URLs and authorization tokens.
    public func open(_ url: URL, identifier: String, title: String = "Video") {
        guard !identifier.isEmpty, url.scheme != nil else {
            error = NSError(domain: "SGPlayerUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "A stable identifier and an absolute media URL are required"])
            return
        }
        source = (url, identifier, title)
        if session == nil, let host = hostView { attach(to: host) }
        else { loadSource() }
    }
    public func play() { session?.play() }
    public func pause() { session?.pause() }
    public func close() {
        session?.close()
        session = nil
        hostView?.uninstallControls()
        controls = nil
        if state != .idle { state = .idle }
        if error != nil { error = nil }
    }
    /// Supply an optional presentation cover; it follows source/first-frame state.
    public func setCoverImage(_ image: CGImage?) {
        coverImage = image
        applyCover()
    }
    /// Zero disables hiding. Surface interaction reveals controls; pause/lock keeps them visible.
    public func setControlsAutoHideInterval(_ interval: TimeInterval) {
        controlsIdleInterval = interval.isFinite ? min(120, max(0, interval)) : 0
        controls?.autoHideInterval = controlsIdleInterval
    }
    private func applyCover() {
        guard let host = hostView, let controls else { return }
        #if os(macOS)
        let image = coverImage.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width), height: CGFloat($0.height))) }
        #else
        let image = coverImage.map { UIImage(cgImage: $0) }
        #endif
        controls.setCover(image, for: host.surface)
    }
    private func loadSource() {
        guard let source, let session else { return }
        let rendition = SGPlaybackRendition(identifier: "original", title: "Original", url: source.url)
        let item = SGPlaybackItem(identifier: source.identifier, title: source.title, renditions: [rendition])
        do {
            try session.loadItems([item], start: 0, autoPlay: true)
            if error != nil { error = nil }
        } catch { self.error = error }
    }

    fileprivate func attach(to host: SGPlayerHostView) {
        close()
        boundView = ObjectIdentifier(host)
        hostView = host
        let controller = SGPlaybackController(kernel: SGPlaybackKernel(rawValue: engine.rawValue)!, view: host.surface)
        controller.effects.subtitleFallbackFontURL = Bundle.module.url(forResource: "NotoSansCJKsc-Regular", withExtension: "otf", subdirectory: "Fonts")
        let session = SGPlaybackSession(controller: controller, resumeStore: resumeStore)
        self.session = session
        session.changed = { [weak self] session in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session === session else { return }
                self.state = State(rawValue: session.state.rawValue) ?? .idle
                self.error = session.error
            }
        }
        let controls = SGPlaybackControls(session: session)
        self.controls = controls
        host.install(controls)
        applyCover()
        #if os(macOS)
        controls.attachKeyboard(to: host.surface)
        #elseif os(iOS)
        controls.attachGestures(to: host.surface)
        #elseif os(tvOS)
        controls.attachRemote(to: host.surface)
        #endif
        controls.autoHideInterval = controlsIdleInterval
        loadSource()
    }
    fileprivate func detach(from host: SGPlayerHostView) {
        if boundView == ObjectIdentifier(host) {
            close()
            boundView = nil
            hostView = nil
        }
    }
}

#if os(macOS)
import AppKit
typealias SGPlatformContainer = NSView
#else
import UIKit
typealias SGPlatformContainer = UIView
#endif

@MainActor
final class SGPlayerHostView: SGPlatformContainer {
    let surface = SGPlatformContainer(frame: .zero)
    private weak var installedControls: SGPlaybackControls?
    private var installedConstraints: [NSLayoutConstraint] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        uninstallControls()
    }
    required init?(coder: NSCoder) { fatalError("Use SGPlayerView(model:)") }
    func uninstallControls() {
        NSLayoutConstraint.deactivate(installedConstraints)
        installedControls?.removeFromSuperview()
        installedControls = nil
        installedConstraints = [
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(installedConstraints)
    }
    func install(_ controls: SGPlaybackControls) {
        uninstallControls()
        NSLayoutConstraint.deactivate(installedConstraints)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        installedControls = controls
        installedConstraints = [
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 260)
        ]
        NSLayoutConstraint.activate(installedConstraints)
    }
}

/// One live view per model. SwiftUI dismantling closes the decoder/session and saves resume state.
#if os(macOS)
public struct SGPlayerView: NSViewRepresentable {
    @ObservedObject private var model: SGPlayerModel
    public init(model: SGPlayerModel) { self.model = model }
    public func makeCoordinator() -> SGPlayerModel { model }
    public func makeNSView(context: Context) -> NSView {
        let host = SGPlayerHostView(frame: .zero)
        model.attach(to: host)
        return host
    }
    public func updateNSView(_ nsView: NSView, context: Context) {}
    public static func dismantleNSView(_ nsView: NSView, coordinator: SGPlayerModel) {
        if let host = nsView as? SGPlayerHostView { coordinator.detach(from: host) }
    }
}
#else
public struct SGPlayerView: UIViewRepresentable {
    @ObservedObject private var model: SGPlayerModel
    public init(model: SGPlayerModel) { self.model = model }
    public func makeCoordinator() -> SGPlayerModel { model }
    public func makeUIView(context: Context) -> UIView {
        let host = SGPlayerHostView(frame: .zero)
        model.attach(to: host)
        return host
    }
    public func updateUIView(_ uiView: UIView, context: Context) {}
    public static func dismantleUIView(_ uiView: UIView, coordinator: SGPlayerModel) {
        if let host = uiView as? SGPlayerHostView { coordinator.detach(from: host) }
    }
}
#endif
