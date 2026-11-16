import CoreGraphics
import Foundation

/// How far into the picture a window is zoomed, when it isn't showing the whole of it.
struct Zoom: Equatable {
    /// Screen pixels per pixel of the video.
    var scale: CGFloat
    /// The point of the picture that's in the middle of the view, in video pixels from the
    /// picture's top left corner.
    var center: CGPoint
}

/// The arithmetic of zooming: where a picture of a given size goes in a view of a given size.
///
/// Everything is in pixels, counted from the top left — the video's own on one side, the
/// screen's on the other — and a zoom comes to rest on a whole number of screen pixels per
/// video pixel. That's what lets each pixel of the video be drawn as an exact block.
struct Viewport: Equatable {
    /// The size of the picture, in video pixels.
    var picture: CGSize
    /// The size of the view it's shown in, in screen pixels.
    var view: CGSize

    static let maximumScale: CGFloat = 32
    /// Where Zoom In and Zoom Out stop.
    private static let steps: [CGFloat] = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32]

    /// Whether there's a picture and somewhere to show it.
    var isUsable: Bool {
        picture.width >= 1 && picture.height >= 1 && view.width >= 1 && view.height >= 1
    }

    /// The scale at which the whole picture just fits in the view.
    var fitScale: CGFloat {
        min(view.width / picture.width, view.height / picture.height)
    }

    /// The middle of the view.
    var middle: CGPoint {
        CGPoint(x: view.width / 2, y: view.height / 2)
    }

    /// The fitted picture, put as a zoom.
    private var fit: Zoom {
        Zoom(scale: fitScale, center: CGPoint(x: picture.width / 2, y: picture.height / 2))
    }

    // MARK: - Where the picture goes

    /// The picture's place in the view at `zoom`. Its corner lands on a whole screen pixel; no
    /// side of it comes away from the edge of the view while there's more picture beyond; and
    /// along a side where it's smaller than the view, it's centred.
    func frame(at zoom: Zoom) -> CGRect {
        let size = CGSize(width: picture.width * zoom.scale, height: picture.height * zoom.scale)
        return CGRect(
            x: Self.origin(of: size.width, in: view.width, middleAt: zoom.center.x * zoom.scale),
            y: Self.origin(of: size.height, in: view.height, middleAt: zoom.center.y * zoom.scale),
            width: size.width,
            height: size.height
        )
    }

    private static func origin(of length: CGFloat, in room: CGFloat, middleAt offset: CGFloat) -> CGFloat {
        guard length > room else { return ((room - length) / 2).rounded(.down) }
        return min(0, max(room - length, (room / 2 - offset).rounded()))
    }

    /// The part of the picture that's inside the view at `zoom`, in video pixels: every pixel
    /// of the video that shows, the ones at the edges that only show in part included.
    func visible(at zoom: Zoom) -> CGRect {
        let frame = frame(at: zoom)
        let shown = frame.intersection(CGRect(origin: .zero, size: view))
        guard !shown.isEmpty else { return .zero }
        // What a division leaves over by a hair isn't a sliver of one more pixel.
        let hair = 0.000_001
        let left = ((shown.minX - frame.minX) / zoom.scale + hair).rounded(.down)
        let top = ((shown.minY - frame.minY) / zoom.scale + hair).rounded(.down)
        let right = min(((shown.maxX - frame.minX) / zoom.scale - hair).rounded(.up), picture.width)
        let bottom = min(((shown.maxY - frame.minY) / zoom.scale - hair).rounded(.up), picture.height)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `zoom` with its centre where the picture really ends up: `frame(at:)` doesn't let it
    /// be pushed past its edges, and the centre shouldn't remember the attempt.
    ///
    /// On a whole scale — at rest — that's to the pixel: the centre says where the picture is
    /// on the screen. In between, in the middle of a pinch, the rounding to pixels is left
    /// to the drawing: done at every step of a pinch, it would add up, and the point under
    /// the fingers would wander off.
    func kept(_ zoom: Zoom) -> Zoom {
        guard zoom.scale == zoom.scale.rounded() else {
            return Zoom(scale: zoom.scale, center: CGPoint(
                x: Self.held(zoom.center.x, in: picture.width, showing: view.width / zoom.scale),
                y: Self.held(zoom.center.y, in: picture.height, showing: view.height / zoom.scale)
            ))
        }
        let frame = frame(at: zoom)
        return Zoom(scale: zoom.scale, center: CGPoint(
            x: (view.width / 2 - frame.minX) / zoom.scale,
            y: (view.height / 2 - frame.minY) / zoom.scale
        ))
    }

    /// Where the middle of the view can be along one side of the picture, `length` long, when
    /// `visible` of it fits in the view: as near `center` as it gets without the view
    /// looking past either end — or the middle, if all of it fits.
    private static func held(_ center: CGFloat, in length: CGFloat, showing visible: CGFloat) -> CGFloat {
        guard length > visible else { return length / 2 }
        return min(max(center, visible / 2), length - visible / 2)
    }

    // MARK: - Changing the zoom

    /// `zoom` — the fitted picture, if nil — taken to another scale with the point of the
    /// picture that's under `anchor` staying where it is.
    func zoom(_ zoom: Zoom?, to scale: CGFloat, around anchor: CGPoint) -> Zoom {
        let current = kept(zoom ?? fit)
        let scale = min(max(scale, min(fitScale, 1)), Self.maximumScale)
        // How far the anchor is from the middle of the view: that much of the picture, at
        // the scale it's at, separates what's under the one from what's under the other.
        let reach = CGPoint(x: anchor.x - view.width / 2, y: anchor.y - view.height / 2)
        let held = CGPoint(x: current.center.x + reach.x / current.scale, y: current.center.y + reach.y / current.scale)
        return kept(Zoom(scale: scale, center: CGPoint(
            x: held.x - reach.x / scale,
            y: held.y - reach.y / scale
        )))
    }

    /// Where a zoom that was left at any scale comes to rest: on the fitted picture (nil), or
    /// on the nearest whole number of screen pixels per video pixel — whichever is closer,
    /// as proportions go.
    func rest(for zoom: Zoom, around anchor: CGPoint) -> Zoom? {
        let whole = min(max(zoom.scale.rounded(), 1), Self.maximumScale)
        if abs(log(zoom.scale / fitScale)) <= abs(log(zoom.scale / whole)) {
            return nil
        }
        return self.zoom(zoom, to: whole, around: anchor)
    }

    /// The next stop of Zoom In from `zoom`, or of Zoom Out. The fitted picture is one of the
    /// stops, in its place among the others.
    func step(_ zoom: Zoom?, up: Bool) -> Zoom? {
        let current = zoom?.scale ?? fitScale
        // nil stands for the fitted picture.
        var stops: [(scale: CGFloat, zoom: CGFloat?)] = Self.steps.map { ($0, $0) }
        stops.append((fitScale, nil))
        stops.sort { $0.scale < $1.scale }
        let next = up
            ? stops.first { $0.scale > current * 1.001 }
            : stops.last { $0.scale < current / 1.001 }
        guard let next else { return zoom }
        guard let scale = next.zoom else { return nil }
        return self.zoom(zoom, to: scale, around: middle)
    }

    /// What a double tap does: from the fitted picture, a closer look at what's under
    /// `anchor`; from anywhere else, back to the fitted picture.
    func toggled(_ zoom: Zoom?, around anchor: CGPoint) -> Zoom? {
        guard zoom == nil else { return nil }
        let closer = Self.steps.first { $0 >= fitScale * 1.5 } ?? Self.maximumScale
        return self.zoom(nil, to: closer, around: anchor)
    }

    /// `zoom` with the picture moved by `delta` screen pixels.
    func scrolled(_ zoom: Zoom, by delta: CGSize) -> Zoom {
        kept(Zoom(scale: zoom.scale, center: CGPoint(
            x: zoom.center.x - delta.width / zoom.scale,
            y: zoom.center.y - delta.height / zoom.scale
        )))
    }
}
