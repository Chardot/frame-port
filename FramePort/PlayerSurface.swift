import AVFoundation
import SwiftUI

/// Shows the video, with no controls of its own: the player's layer while it plays, and
/// `still` drawn over it while it's paused — the whole picture letterboxed, or part of it
/// zoomed in on.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let still: StillFrame?
    /// The size of the video's picture in its own pixels; nil with no video.
    let pictureSize: CGSize?
    let zoom: Zoom?
    /// Who is told how much room the picture has, and what the trackpad asks for.
    let model: PlayerModel

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.model = model
        view.show(still, pictureSize: pictureSize, zoom: zoom)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.model = model
        view.show(still, pictureSize: pictureSize, zoom: zoom)
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    /// Hides the player layer completely while a still is up, so that however the system
    /// presents the video underneath, none of it shows around the still.
    private let stillBackdrop = CALayer()
    private let stillLayer = CALayer()

    weak var model: PlayerModel?

    private var still: StillFrame?
    private var pictureSize: CGSize?
    private var zoom: Zoom?
    /// What `stillLayer` holds, so that layout passes that change nothing don't redraw it:
    /// the frame it came from and, if that was resampled to fit the view, at what size.
    private var drawn: (source: CGImage, fitted: CGSize?)?
    /// A pinch is going on: the zoom follows the fingers rather than gliding.
    private var isMagnifying = false
    /// The part of a scroll or a drag that came to less than a whole screen pixel.
    private var panRemainder = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.backgroundColor = .black
        root.masksToBounds = true                   // a zoomed picture is bigger than the view
        playerLayer.videoGravity = .resizeAspect
        stillBackdrop.backgroundColor = .black
        stillBackdrop.isOpaque = true
        stillBackdrop.isHidden = true
        stillLayer.isOpaque = true
        stillLayer.contentsGravity = .resize
        // When the picture glides to another zoom, it's only its place that's animated: a new
        // frame still replaces the old one at once, and the still appears and goes at once.
        stillLayer.actions = ["contents": NSNull()]
        stillBackdrop.actions = ["hidden": NSNull()]

        root.addSublayer(playerLayer)
        root.addSublayer(stillBackdrop)
        stillBackdrop.addSublayer(stillLayer)
        layer = root
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Draws `still` in place of the player layer — or uncovers the player layer, if it's
    /// nil — with the picture fitted to the view, or at `zoom`.
    func show(_ still: StillFrame?, pictureSize: CGSize?, zoom: Zoom?) {
        // From one zoom to another the picture glides, unless it's following the fingers.
        // To and from the fitted picture it doesn't: that one is a different drawing.
        let glides = !isMagnifying && self.zoom != nil && zoom != nil && self.zoom?.scale != zoom?.scale
        self.still = still
        self.pictureSize = pictureSize
        self.zoom = zoom
        arrangeLayers(gliding: glides)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrangeLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isMagnifying {
            // Taken off screen in the middle of a pinch (its tab was switched away from): the
            // pinch ends here, as far as this picture goes.
            isMagnifying = false
            model?.endMagnifying(around: nil)
        }
        arrangeLayers()
    }

    /// The window moved to a display with a different pixel density.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        arrangeLayers()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? layer?.contentsScale ?? 1
    }

    private func arrangeLayers(gliding: Bool = false) {
        CATransaction.begin()
        if gliding {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)   // no cross-fades: frames replace each other at once
        }
        defer { CATransaction.commit() }

        stillBackdrop.frame = bounds

        let scale = backingScale
        let room = CGSize(width: (bounds.width * scale).rounded(.down), height: (bounds.height * scale).rounded(.down))
        if window != nil {
            model?.stageChanged(to: room)
        }

        if let zoom, let pictureSize {
            let viewport = Viewport(picture: pictureSize, view: room)
            if viewport.isUsable {
                arrangeZoomed(zoom, in: viewport, scale: scale)
                return
            }
        }

        playerLayer.frame = bounds
        guard let still,
              let fit = Self.pixelFit(of: CGSize(width: still.image.width, height: still.image.height), in: bounds.size, scale: scale) else {
            hideStill()
            return
        }
        if drawn?.source !== still.image || drawn?.fitted != fit.pixels {
            guard let image = FrameImage.resampled(still.image, to: fit.pixels) else {
                hideStill()
                return
            }
            stillLayer.contents = image
            drawn = (still.image, fit.pixels)
        }
        // The still is drawn pixel for pixel; if it ever isn't, don't smooth that over.
        stillLayer.magnificationFilter = .nearest
        stillLayer.minificationFilter = .nearest
        stillLayer.contentsScale = scale
        stillLayer.frame = fit.frame
        stillBackdrop.isHidden = false
    }

    /// The picture at `zoom`: the frame itself, as it was decoded, stretched over the place
    /// `viewport` gives it, so that each of its pixels covers a whole block of the screen's.
    private func arrangeZoomed(_ zoom: Zoom, in viewport: Viewport, scale: CGFloat) {
        // From screen pixels counted from the top left, to the layer's points from the bottom left.
        let place = viewport.frame(at: zoom)
        let frame = CGRect(
            x: place.minX / scale,
            y: (viewport.view.height - place.maxY) / scale,
            width: place.width / scale,
            height: place.height / scale
        )
        // The same place for the video itself, so that playing shows the same part of it.
        playerLayer.frame = frame
        guard let still else {
            hideStill()
            return
        }
        if drawn?.source !== still.image || drawn?.fitted != nil {
            stillLayer.contents = still.image
            drawn = (still.image, nil)
        }
        // Blocks, not a blur. (Smoothed only while a pinch has the picture smaller than life,
        // on its way to or from the fitted size.)
        stillLayer.magnificationFilter = .nearest
        stillLayer.minificationFilter = .trilinear
        stillLayer.contentsScale = scale
        stillLayer.frame = frame
        stillBackdrop.isHidden = false
    }

    private func hideStill() {
        stillBackdrop.isHidden = true
        stillLayer.contents = nil
        drawn = nil
    }

    /// Where a picture of `size` goes when it's fitted into `container` and snapped to whole
    /// device pixels: its frame in points, and its size in pixels. Whole pixels are what let
    /// the still be drawn without any further resampling.
    private static func pixelFit(of size: CGSize, in container: CGSize, scale: CGFloat) -> (frame: CGRect, pixels: CGSize)? {
        let available = CGSize(width: (container.width * scale).rounded(.down), height: (container.height * scale).rounded(.down))
        guard size.width >= 1, size.height >= 1, available.width >= 1, available.height >= 1 else { return nil }
        let factor = min(available.width / size.width, available.height / size.height)
        let pixels = CGSize(
            width: min(max((size.width * factor).rounded(), 1), available.width),
            height: min(max((size.height * factor).rounded(), 1), available.height)
        )
        let origin = CGPoint(
            x: ((available.width - pixels.width) / 2).rounded(.down),
            y: ((available.height - pixels.height) / 2).rounded(.down)
        )
        return (
            CGRect(x: origin.x / scale, y: origin.y / scale, width: pixels.width / scale, height: pixels.height / scale),
            pixels
        )
    }

    // MARK: - Zooming with the trackpad and the mouse

    /// Where something happened, in screen pixels from the top left corner of the view: what
    /// the zoom works in.
    private func pixelPoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x * backingScale, y: (bounds.height - point.y) * backingScale)
    }

    /// Shows what the model has made of a gesture at once, without waiting for SwiftUI to
    /// come round with it.
    private func follow(_ model: PlayerModel) {
        show(still, pictureSize: pictureSize, zoom: model.zoom)
    }

    /// A pinch: closer or further, about the point under the pointer.
    override func magnify(with event: NSEvent) {
        guard let model, pictureSize != nil else {
            super.magnify(with: event)
            return
        }
        let anchor = pixelPoint(of: event)
        let isOver = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        isMagnifying = !isOver
        model.magnify(by: 1 + event.magnification, around: anchor)
        if isOver {
            model.endMagnifying(around: anchor)
        }
        follow(model)
    }

    /// A double tap with two fingers.
    override func smartMagnify(with event: NSEvent) {
        guard let model, pictureSize != nil else {
            super.smartMagnify(with: event)
            return
        }
        model.toggleZoom(around: pixelPoint(of: event))
        follow(model)
    }

    /// Two fingers, or the wheel: moves the zoomed picture about.
    override func scrollWheel(with event: NSEvent) {
        guard let model, zoom != nil else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) {
            panRemainder = .zero
        }
        // A trackpad counts in points; a wheel, in lines.
        let unit = backingScale * (event.hasPreciseScrollingDeltas ? 1 : 10)
        pan(model, by: CGSize(width: event.scrollingDeltaX * unit, height: event.scrollingDeltaY * unit))
    }

    /// Moves the zoomed picture by so many screen pixels — by the whole ones, that is: it
    /// sits on the screen's pixels, and what's left over is kept for the next time.
    private func pan(_ model: PlayerModel, by delta: CGSize) {
        let wanted = CGSize(width: delta.width + panRemainder.width, height: delta.height + panRemainder.height)
        let whole = CGSize(width: wanted.width.rounded(.towardZero), height: wanted.height.rounded(.towardZero))
        panRemainder = CGSize(width: wanted.width - whole.width, height: wanted.height - whole.height)
        guard whole != .zero else { return }
        model.scroll(by: whole)
        follow(model)
    }

    /// A double click does what a double tap does. (A single one on a zoomed picture is the
    /// start of a drag, and stays here.)
    override func mouseDown(with event: NSEvent) {
        guard let model, pictureSize != nil, event.clickCount == 2 || zoom != nil else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            model.toggleZoom(around: pixelPoint(of: event))
            follow(model)
        }
        panRemainder = .zero
    }

    /// Dragging moves the zoomed picture, for those without two fingers on a trackpad.
    override func mouseDragged(with event: NSEvent) {
        guard let model, zoom != nil else {
            super.mouseDragged(with: event)
            return
        }
        pan(model, by: CGSize(width: event.deltaX * backingScale, height: event.deltaY * backingScale))
    }
}
