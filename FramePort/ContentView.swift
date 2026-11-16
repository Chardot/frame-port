import SwiftUI

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.openVideos) private var openVideos
    @State private var isDropTargeted = false
    /// Indexing a video is usually instant; the spinner only appears if it drags on.
    @State private var showsLoadingIndicator = false

    /// The smallest the window's content gets.
    static let minimumSize = CGSize(width: 800, height: 500)

    var body: some View {
        VStack(spacing: 0) {
            stage
            ControlBar()
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(.black)
        .overlay {
            if isDropTargeted {
                DropHighlight(opensNewTab: !model.isEmpty)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            openVideos(files, from: model)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .alert("Export \(model.framesAwaitingConfirmation.formatted()) frames?", isPresented: isConfirmingSegmentExport) {
            Button("Export") { model.confirmSegmentExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each frame is saved as its own PNG, in a new folder inside \(model.exportFolder.lastPathComponent).")
        }
    }

    private var stage: some View {
        ZStack {
            VideoPicture()
                .opacity(model.video == nil ? 0 : 1)

            if model.video == nil {
                EmptyState()
                    .opacity(showsLoadingIndicator ? 0 : 1)
            }
            if showsLoadingIndicator {
                ProgressView("Reading frames…")
                    .controlSize(.large)
                    .padding(22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .task(id: model.isLoading) {
            guard model.isLoading else {
                showsLoadingIndicator = false
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled {
                showsLoadingIndicator = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .overlay(alignment: .topTrailing) {
            ZoomReadout()
                .padding(12)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeView(notice: notice)
                    .padding(.bottom, 14)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(notice.id)
            }
        }
        .animation(.snappy(duration: 0.25), value: model.notice?.id)
        .clipped()
    }

    private var isConfirmingSegmentExport: Binding<Bool> {
        Binding {
            model.segmentAwaitingConfirmation != nil
        } set: { isPresented in
            if !isPresented { model.segmentAwaitingConfirmation = nil }
        }
    }
}

/// Opens the videos dropped on a window: in that window if it's empty, otherwise in new tabs
/// of it. Which is the window manager's business (`VideoWindows`), so it's handed down.
struct OpenVideosAction {
    let handler: @MainActor (_ urls: [URL], _ model: PlayerModel) -> Void

    @MainActor
    func callAsFunction(_ urls: [URL], from model: PlayerModel) {
        handler(urls, model)
    }
}

extension EnvironmentValues {
    /// On its own — in a preview, say — a window simply opens the first video itself.
    @Entry var openVideos = OpenVideosAction { urls, model in
        if let url = urls.first {
            model.open(url)
        }
    }
}

/// The video itself. Kept in its own view so that stepping, which replaces the still on every
/// frame, redraws only this.
private struct VideoPicture: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        PlayerSurface(
            player: model.player,
            still: model.still,
            pictureSize: model.pictureSize,
            zoom: model.zoom,
            model: model
        )
    }
}

/// Says what zoom the picture is at — "300%", "Fit · 48%" — for a moment after it changes.
private struct ZoomReadout: View {
    @Environment(PlayerModel.self) private var model
    /// What it says, while it's up.
    @State private var text: String?
    /// Counts the changes, so that each one keeps it up a little longer.
    @State private var changes = 0

    var body: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.1))
                    }
                    .transition(.opacity)
            }
        }
        // Moving about a zoomed picture changes where it's zoomed, not how far: that goes unsaid.
        .onChange(of: model.zoom?.scale) {
            text = model.zoomDescription
            changes += 1
        }
        .task(id: changes) {
            guard text != nil else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) { text = nil }
            }
        }
    }
}

/// What the window shows before a video is opened.
private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("Drop a video here")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("or choose File › Open…  (⌘O)")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 44)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        }
    }
}

/// Shown over the whole window while a file is being dragged across it.
private struct DropHighlight: View {
    /// The window already has a video, so the one being dragged will get a tab of its own.
    let opensNewTab: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(opensNewTab ? 0.55 : 0.25)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [11, 8]))
                .padding(10)
            if opensNewTab {
                Label("Drop to open in a new tab", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .allowsHitTesting(false)
    }
}

/// A transient message over the bottom of the video.
private struct NoticeView: View {
    @Environment(PlayerModel.self) private var model
    let notice: Notice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(notice.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
                .truncationMode(.middle)
            if let url = notice.revealURL {
                Button("Show in Finder") {
                    model.reveal(url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .onTapGesture {
            model.dismissNotice()
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .success: .green
        case .failure: .orange
        case .info: .white.opacity(0.7)
        }
    }
}
