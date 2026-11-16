import SwiftUI

/// The row of tabs under the title bar of a window that holds more than one video.
///
/// Each tab is as wide as its title, and they line up from the left. (Which is why the tabs
/// are the app's own: the system's window tabs always share out the whole width of the window.)
struct TabStrip: View {
    /// The height AppKit gives a bar under the title bar, whatever is asked for.
    static let height: CGFloat = 36

    let list: TabList
    let select: (VideoTab) -> Void
    let close: (VideoTab) -> Void
    let closeOthers: (VideoTab) -> Void
    let moveToNewWindow: (VideoTab) -> Void

    var body: some View {
        LeadingRow(spacing: 2) {
            ForEach(list.tabs) { tab in
                TabItem(
                    model: tab.model,
                    isSelected: tab === list.selected,
                    select: { select(tab) },
                    close: { close(tab) }
                )
                .contextMenu {
                    Button("Close Tab") { close(tab) }
                    Button("Close Other Tabs") { closeOthers(tab) }
                    Divider()
                    Button("Move Tab to New Window") { moveToNewWindow(tab) }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
    }
}

/// One tab: the name of its video, and a button to close it that shows while the pointer is
/// over the tab.
private struct TabItem: View {
    let model: PlayerModel
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    private var title: String {
        model.video?.url.lastPathComponent ?? "FramePort"
    }

    var body: some View {
        HStack(spacing: 1) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Close tab")
            .accessibilityLabel("Close tab")

            Button(action: select) {
                // The same weight whether selected or not, so that selecting a tab doesn't
                // change how wide it is.
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.14 : isHovered ? 0.06 : 0))
        }
        .onHover { isHovered = $0 }
        .help(title)
    }
}

/// A row of views from the leading edge, each as wide as it would like to be. When there
/// isn't room for that, the widest give way first — down to a common width, if it comes to
/// it — so that every one of them stays in view.
private struct LeadingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = ideals.reduce(0) { $0 + $1.width } + gaps(between: subviews.count)
        let height = ideals.map(\.height).max() ?? 0
        guard let available = proposal.width, available.isFinite else {
            return CGSize(width: ideal, height: height)
        }
        return CGSize(width: min(ideal, max(available, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = Self.fitted(ideals, into: max(bounds.width - gaps(between: subviews.count), 0))
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func gaps(between count: Int) -> CGFloat {
        spacing * CGFloat(max(count - 1, 0))
    }

    /// The widths for views that would like `ideals`, so that together they take no more
    /// than `room`: each keeps its own width up to a cap that all the wider ones share.
    static func fitted(_ ideals: [CGFloat], into room: CGFloat) -> [CGFloat] {
        guard ideals.reduce(0, +) > room else { return ideals }
        // The narrowest views that fit in an even share of what's left keep their width;
        // the share that's left for the first one that doesn't is the cap.
        var remaining = room
        var cap: CGFloat = 0
        let sorted = ideals.sorted()
        for (index, width) in sorted.enumerated() {
            let share = remaining / CGFloat(sorted.count - index)
            if width <= share {
                remaining -= width
            } else {
                cap = share
                break
            }
        }
        return ideals.map { min($0, cap) }
    }
}
