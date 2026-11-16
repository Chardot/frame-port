import SwiftUI

enum TimelineMetrics {
    static let height: CGFloat = 48
    static let handleWidth: CGFloat = 15
    /// Thickness of the bars that join the two handles along the top and bottom.
    static let frameThickness: CGFloat = 3
    static let stripHeight: CGFloat = height - 2 * frameThickness
}

/// Maps frames to horizontal positions. The filmstrip is inset by one handle width on each
/// side so the handles have room to sit just outside the frames they enclose.
struct TimelineLayout {
    let frames: FrameTable?
    let width: CGFloat

    var trackMinX: CGFloat { TimelineMetrics.handleWidth }
    var trackWidth: CGFloat { max(width - 2 * TimelineMetrics.handleWidth, 1) }

    /// Boundary `k` is the left edge of frame `k`; boundary `count` is the end of the video.
    func x(ofBoundary boundary: Int) -> CGFloat {
        trackMinX + CGFloat(frames?.fraction(ofBoundary: boundary) ?? 0) * trackWidth
    }

    func time(atX x: CGFloat) -> Double {
        frames?.time(atFraction: Double((x - trackMinX) / trackWidth)) ?? 0
    }
}

/// The scrubber: a filmstrip with a playhead and, while selecting, a yellow frame with
/// a draggable handle at each end.
struct TimelineView: View {
    @Environment(PlayerModel.self) private var model
    @State private var dragTarget: DragTarget?
    /// Distance from the pointer to the edge being dragged, so handles don't jump on grab.
    @State private var grabOffset: CGFloat = 0

    private enum DragTarget {
        case playhead, segmentStart, segmentEnd
    }

    var body: some View {
        // Read here (not inside the Canvas) so changes are observed.
        let frames = model.video?.frames
        let frame = model.frame
        let selection = model.isSelecting ? model.selection : nil

        GeometryReader { proxy in
            let layout = TimelineLayout(frames: frames, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                Filmstrip()
                    .frame(width: layout.trackWidth, height: TimelineMetrics.stripHeight)
                    .offset(x: layout.trackMinX, y: TimelineMetrics.frameThickness)

                Canvas { context, size in
                    guard frames != nil else { return }
                    Self.drawOverlay(in: &context, size: size, layout: layout, frame: frame, selection: selection)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(layout))
            .onContinuousHover { phase in
                updateCursor(phase, layout: layout)
            }
        }
        .frame(height: TimelineMetrics.height)
    }

    // MARK: - Interaction

    private func dragGesture(_ layout: TimelineLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let frames = layout.frames else { return }
                if dragTarget == nil {
                    let target = target(at: value.startLocation, layout: layout)
                    dragTarget = target
                    switch target {
                    case .playhead:
                        grabOffset = 0
                    case .segmentStart:
                        grabOffset = layout.x(ofBoundary: model.selection.lowerBound) - value.startLocation.x
                    case .segmentEnd:
                        grabOffset = layout.x(ofBoundary: model.selection.upperBound + 1) - value.startLocation.x
                    }
                }

                let time = layout.time(atX: value.location.x + grabOffset)
                switch dragTarget {
                case .playhead:
                    model.scrub(toFrame: frames.index(at: time))
                case .segmentStart:
                    // The handle's inner edge is the left edge of the first frame in the segment…
                    model.setSelectionStart(frames.nearestBoundary(to: time))
                case .segmentEnd:
                    // …and the right edge of the last one.
                    model.setSelectionEnd(frames.nearestBoundary(to: time) - 1)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                dragTarget = nil
            }
    }

    private func target(at point: CGPoint, layout: TimelineLayout) -> DragTarget {
        guard model.isSelecting else { return .playhead }
        let slop: CGFloat = 4
        let startEdge = layout.x(ofBoundary: model.selection.lowerBound)
        let endEdge = layout.x(ofBoundary: model.selection.upperBound + 1)
        let onStart = point.x >= startEdge - TimelineMetrics.handleWidth - slop && point.x <= startEdge + slop
        let onEnd = point.x >= endEdge - slop && point.x <= endEdge + TimelineMetrics.handleWidth + slop

        switch (onStart, onEnd) {
        case (true, true): return point.x < (startEdge + endEdge) / 2 ? .segmentStart : .segmentEnd
        case (true, false): return .segmentStart
        case (false, true): return .segmentEnd
        case (false, false): return .playhead
        }
    }

    private func updateCursor(_ phase: HoverPhase, layout: TimelineLayout) {
        guard dragTarget == nil else { return }
        switch phase {
        case .active(let location) where layout.frames != nil && target(at: location, layout: layout) != .playhead:
            NSCursor.resizeLeftRight.set()
        default:
            NSCursor.arrow.set()
        }
    }

    // MARK: - Drawing

    private static func drawOverlay(
        in context: inout GraphicsContext,
        size: CGSize,
        layout: TimelineLayout,
        frame: Int,
        selection: ClosedRange<Int>?
    ) {
        let handleWidth = TimelineMetrics.handleWidth
        let thickness = TimelineMetrics.frameThickness
        let strip = CGRect(x: layout.trackMinX, y: thickness, width: layout.trackWidth, height: TimelineMetrics.stripHeight)

        if let selection {
            let startX = layout.x(ofBoundary: selection.lowerBound)
            let endX = layout.x(ofBoundary: selection.upperBound + 1)
            let banana = GraphicsContext.Shading.color(Palette.banana)
            let dim = GraphicsContext.Shading.color(.black.opacity(0.62))

            // Dim everything outside the segment.
            context.fill(Path(CGRect(x: strip.minX, y: strip.minY, width: max(startX - strip.minX, 0), height: strip.height)), with: dim)
            context.fill(Path(CGRect(x: endX, y: strip.minY, width: max(strip.maxX - endX, 0), height: strip.height)), with: dim)

            // The yellow frame: a bar along the top and bottom…
            context.fill(Path(CGRect(x: startX, y: 0, width: endX - startX, height: thickness)), with: banana)
            context.fill(Path(CGRect(x: startX, y: size.height - thickness, width: endX - startX, height: thickness)), with: banana)

            // …and a handle at each end, rounded on the outside.
            let radius: CGFloat = 7
            let leading = CGRect(x: startX - handleWidth, y: 0, width: handleWidth, height: size.height)
            let trailing = CGRect(x: endX, y: 0, width: handleWidth, height: size.height)
            context.fill(
                UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous).path(in: leading),
                with: banana
            )
            context.fill(
                UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous).path(in: trailing),
                with: banana
            )
            for handle in [leading, trailing] {
                let grip = CGRect(x: handle.midX - 1.25, y: handle.midY - 8, width: 2.5, height: 16)
                context.fill(Path(roundedRect: grip, cornerRadius: 1.25), with: .color(Palette.bananaInk.opacity(0.7)))
            }
        }

        // Playhead, on the left edge of the current frame.
        let x = layout.x(ofBoundary: frame)
        let outline = CGRect(x: x - 2.5, y: 0, width: 5, height: size.height)
        context.fill(Path(roundedRect: outline, cornerRadius: 2.5), with: .color(.black.opacity(0.55)))
        context.fill(Path(roundedRect: outline.insetBy(dx: 1, dy: 1), cornerRadius: 1.5), with: .color(.white))
    }
}

/// Evenly spaced thumbnails behind the playhead. Kept in its own view so it's only redrawn
/// when a thumbnail arrives, not on every playhead move.
private struct Filmstrip: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, thumbnail in
                Palette.stripPlaceholder
                    .overlay {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        }
                    }
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.stripPlaceholder)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: model.thumbnails.count(where: { $0 != nil }))
    }
}
