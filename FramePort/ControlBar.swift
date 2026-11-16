import SwiftUI

/// The bar under the video: where you are, the scrubber, and the buttons.
struct ControlBar: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            PositionReadout()
            TimelineView()
            ZStack {
                HStack(spacing: 12) {
                    SegmentToggle()
                    Spacer(minLength: 0)
                    ExportControl()
                }
                // Centred on the bar no matter how wide the buttons on either side are.
                TransportControls()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(Palette.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
        .disabled(model.video == nil)
    }
}

/// Current time on the left, the frame counter in the middle, and the total length — or the
/// selected segment — on the right.
private struct PositionReadout: View {
    @Environment(PlayerModel.self) private var model

    /// Where you are: the current time and the current frame number.
    private static let bright = Color.white.opacity(0.92)
    /// Everything that only gives those two context.
    private static let dim = Color.white.opacity(0.5)

    var body: some View {
        Group {
            if let frames = model.video?.frames {
                let frame = frames.clamped(model.frame)
                CenteredRow(spacing: 12) {
                    Text(timecode(frames.seconds[frame]))
                        .foregroundStyle(Self.bright)
                    Text("Frame \(Text((frame + 1).formatted()).foregroundStyle(Self.bright)) of \(frames.count.formatted())")
                        .foregroundStyle(Self.dim)
                    if model.isSelecting {
                        Text(segmentSummary(model.selection))
                            .foregroundStyle(Palette.banana)
                    } else {
                        Text(timecode(frames.endSeconds))
                            .foregroundStyle(Self.dim)
                    }
                }
            } else {
                Text("0:00.000")
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, TimelineMetrics.handleWidth)
    }

    private func segmentSummary(_ selection: ClosedRange<Int>) -> String {
        let count = selection.count
        guard count > 1 else { return "Segment: frame \((selection.lowerBound + 1).formatted()) · 1 frame" }
        return "Segment: frames \((selection.lowerBound + 1).formatted())–\((selection.upperBound + 1).formatted()) · \(count.formatted()) frames"
    }
}

/// A row of exactly three views: the first against the leading edge, the last against the
/// trailing edge, and the middle one centred on the row itself — not on the gap the other
/// two leave — so it stays put while they change width. It only gives way when one of them
/// would otherwise run into it.
private struct CenteredRow: Layout {
    /// The least room left between neighbours.
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }

        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)

        // The room the outer two leave. If even that is too tight, the middle view is
        // squeezed (text truncates) rather than drawn over a neighbour.
        let minX = bounds.minX + widths[0] + spacing
        let maxX = bounds.maxX - widths[2] - spacing
        let width = min(widths[1], max(maxX - minX, 0))
        let x = min(max(bounds.midX - width / 2, minX), maxX - width)
        subviews[1].place(
            at: CGPoint(x: x, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}

/// « ‹ play/pause › »
private struct TransportControls: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            stepButton("chevron.left.2", by: -10, help: "Back 10 frames (⇧←)")
            stepButton("chevron.left", by: -1, help: "Previous frame (←)")

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace.offUp))
            }
            .buttonStyle(TransportButtonStyle(isPrimary: true))
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .padding(.horizontal, 4)

            stepButton("chevron.right", by: 1, help: "Next frame (→)")
            stepButton("chevron.right.2", by: 10, help: "Forward 10 frames (⇧→)")
        }
        .buttonStyle(TransportButtonStyle())
    }

    private func stepButton(_ symbol: String, by delta: Int, help: String) -> some View {
        Button {
            model.step(by: delta)
        } label: {
            Image(systemName: symbol)
        }
        .buttonRepeatBehavior(.enabled)      // press and hold to keep stepping
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SegmentToggle: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Button {
            model.toggleSelecting()
        } label: {
            Label("Select segment", systemImage: "timeline.selection")
        }
        .buttonStyle(PillButtonStyle(tone: model.isSelecting ? .bananaTint : .quiet))
        .help(model.isSelecting
              ? "Hide the segment (S or Esc). Drag the yellow handles, or press I / O to set the start / end at the current frame."
              : "Select a range of frames to export (S)")
    }
}

/// The export button. It exports the current frame, or — while a segment is selected —
/// every frame in the segment; during a segment export it turns into a progress readout.
private struct ExportControl: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        if let progress = model.exportProgress {
            HStack(spacing: 10) {
                ProgressBar(fraction: Double(progress.completed) / Double(max(progress.total, 1)))
                    .frame(width: 140, height: 6)
                // Sized for the final count, so the bar doesn't shift as the number grows.
                Text("\(progress.total.formatted()) / \(progress.total.formatted())")
                    .hidden()
                    .overlay(alignment: .trailing) {
                        Text("\(progress.completed.formatted()) / \(progress.total.formatted())")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Button {
                    model.cancelExport()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Cancel export")
                .accessibilityLabel("Cancel export")
            }
            .frame(height: 30)
        } else {
            Group {
                if model.isSelecting {
                    Button {
                        model.exportSegment()
                    } label: {
                        Label("Export all frames in this segment", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(PillButtonStyle(tone: .banana))
                    .help("Save every frame of the segment as a PNG in a new folder in \(model.exportFolder.lastPathComponent) (⇧⌘E)")
                } else {
                    Button {
                        model.exportCurrentFrame()
                    } label: {
                        Label("Export frame as PNG", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PillButtonStyle(tone: .accent))
                    .help("Save the current frame as a PNG in \(model.exportFolder.lastPathComponent) (↩)")
                }
            }
            .contextMenu {
                Button("Choose Export Folder…") { model.chooseExportFolder() }
                if !model.exportsToDownloads {
                    Button("Use Downloads as Export Folder") { model.resetExportFolder() }
                }
                Button("Show Export Folder in Finder") { model.revealExportFolder() }
            }
        }
    }
}

/// A plain determinate bar. (The system one eases towards each new value, which makes it
/// lag far behind when hundreds of frames are written per second.)
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                Capsule()
                    .fill(Palette.banana)
                    .frame(width: max(proxy.size.height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Export progress")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}
