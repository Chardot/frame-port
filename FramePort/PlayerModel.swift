import AppKit
import AVFoundation
import Observation

/// A video that has been opened and indexed.
struct Video {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let frames: FrameTable
    /// Size of a frame as it's displayed, i.e. after the track's rotation is applied.
    let displaySize: CGSize
    let orientation: CGAffineTransform
    let frameRate: Double
    let isHDR: Bool

    var name: String { url.deletingPathExtension().lastPathComponent }

    var summary: String {
        var parts = ["\(Int(displaySize.width.rounded())) × \(Int(displaySize.height.rounded()))"]
        if let frameRateText {
            parts.append(frameRateText)
        }
        return parts.joined(separator: " · ")
    }

    /// "60 fps", "29.97 fps" — nil for a video that doesn't declare a frame rate.
    var frameRateText: String? {
        guard frameRate > 0 else { return nil }
        let rounded = frameRate.rounded()
        let rate = abs(frameRate - rounded) < 0.01 ? String(Int(rounded)) : String(format: "%.2f", frameRate)
        return "\(rate) fps"
    }

    var exportSource: FrameExporter.Source {
        FrameExporter.Source(asset: asset, track: track, frames: frames, orientation: orientation, pixelSize: displaySize)
    }
}

/// The frame the player is paused on, copied from the pixels it decoded.
///
/// The window draws a paused frame itself, as an ordinary image, instead of leaving it to the
/// player's video layer. For about a second after that layer gets a new frame, the system
/// shows its picture slightly wider (0.3 % was measured: a couple of pixels) and then lets it
/// snap back — after every single step. It never shows in a screenshot, only on the display.
struct StillFrame {
    let index: Int
    /// The upright, full-size picture.
    let image: CGImage
}

struct ExportProgress: Equatable {
    var completed: Int
    var total: Int
}

/// A short message shown over the video, e.g. after an export.
struct Notice: Identifiable, Equatable {
    enum Kind { case success, failure, info }

    let id = UUID()
    var kind: Kind
    var message: String
    /// When set, the notice offers to reveal this file or folder in Finder.
    var revealURL: URL?
    /// How long the notice stays up. Results of long exports linger, since you may have looked away.
    var duration: Duration = .seconds(4)
}

/// Owns the player and everything the window shows.
///
/// While paused, `frame` is the source of truth and the player is moved to match it with
/// exact (zero-tolerance) seeks. While playing it's the other way round: `frame` follows
/// the player's clock.
@MainActor
@Observable
final class PlayerModel {
    let player = AVPlayer()

    private(set) var video: Video?
    /// A video is being read to be shown in this window.
    private var isOpening = false
    /// How many videos are being read for new tabs next to this window (see `read(forNewTab:)`).
    private var tabsBeingRead = 0
    private(set) var isPlaying = false
    /// Index of the frame under the playhead.
    private(set) var frame = 0
    /// The frame to draw while paused. Nil while playing, and whenever the decoded frame
    /// can't be had: the window then shows the player's own layer.
    private(set) var still: StillFrame?
    /// How far into the picture the window is zoomed; nil while it shows the whole of it.
    private(set) var zoom: Zoom?
    private(set) var isSelecting = false
    /// First and last frame of the selected segment, both included.
    private(set) var selection = 0...0
    private(set) var thumbnails: [CGImage?] = []
    /// Non-nil while a segment is being exported.
    private(set) var exportProgress: ExportProgress?
    private(set) var notice: Notice?
    /// A large segment export waiting for the user to confirm it.
    var segmentAwaitingConfirmation: ClosedRange<Int>?
    /// How many frames that confirmation is about. Set together with the segment and left as
    /// it is when the segment is cleared, so the question reads right from the moment it
    /// appears until it has gone.
    private(set) var framesAwaitingConfirmation = 0

    /// Segments longer than this ask for confirmation before writing that many files.
    static let confirmationThreshold = 500

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// Files that an in-flight export is about to create, so two exports never pick the same name.
    @ObservationIgnored private var reservedURLs: Set<URL> = []

    // Seeking state: at most one seek is in flight; a newer target simply waits its turn.
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var seekNeeded = false
    @ObservationIgnored private var seekGeneration = 0

    /// Hands over the frames the player decodes, for `still`.
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var stillTask: Task<Void, Never>?

    /// The size, in screen pixels, of the area the picture is shown in. The view that shows
    /// it is the one that knows (`stageChanged`), and zooming has to.
    @ObservationIgnored private var stage = CGSize.zero

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playerClockChanged(to: time)
            }
        }
    }

    // MARK: - Opening

    /// True while a video is being read on this window's account: one that will be shown
    /// here, or one that's headed for a new tab next to it.
    var isLoading: Bool { isOpening || tabsBeingRead > 0 }

    /// Neither showing a video nor about to: the next one opened here can just take the window.
    var isEmpty: Bool { video == nil && !isOpening }

    /// Opens a video in this window, in place of whatever it shows.
    func open(_ url: URL) {
        guard exportProgress == nil else {
            show(Notice(kind: .info, message: "Wait for the export to finish before opening another video."))
            return
        }
        loadTask?.cancel()
        let id = UUID()
        loadID = id
        isOpening = true
        loadTask = Task {
            do {
                install(try await Self.read(url))
            } catch is CancellationError {
                // A newer file replaced this one.
            } catch {
                show(Self.failure(toOpen: url, error))
            }
            if loadID == id { isOpening = false }
        }
    }

    /// Reads a video that's headed for a new tab next to this window. Meanwhile this window
    /// shows the wait, and it's the one that says so if the file can't be opened: nil comes
    /// back then, and no tab needs to appear at all.
    func read(forNewTab url: URL) async -> Video? {
        tabsBeingRead += 1
        defer { tabsBeingRead -= 1 }
        do {
            return try await Self.read(url)
        } catch {
            show(Self.failure(toOpen: url, error))
            return nil
        }
    }

    /// Reads a video file and indexes its frames.
    private static func read(_ url: URL) async throws -> Video {
        let asset = AVURLAsset(url: url)
        guard let track = try await primaryVideoTrack(of: asset) else {
            throw VideoError.noVideoTrack
        }
        let (naturalSize, orientation, nominalFrameRate, characteristics) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .mediaCharacteristics)
        let frames = try await FrameTable.load(track: track, of: asset)
        try Task.checkCancellation()

        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(orientation)
        return Video(
            url: url,
            asset: asset,
            track: track,
            frames: frames,
            displaySize: CGSize(width: abs(displayRect.width), height: abs(displayRect.height)),
            orientation: orientation,
            frameRate: Double(nominalFrameRate),
            isHDR: characteristics.contains(.containsHDRVideo)
        )
    }

    private static func failure(toOpen url: URL, _ error: Error) -> Notice {
        Notice(kind: .failure, message: "Couldn't open “\(url.lastPathComponent)”. \(explanation(of: error))")
    }

    /// The video track the player shows: the first enabled one. (Some files carry extra,
    /// disabled video tracks, such as alternate angles or depth data.)
    private static func primaryVideoTrack(of asset: AVAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        for track in tracks where (try? await track.load(.isEnabled)) == true {
            return track
        }
        return tracks.first
    }

    /// Shows a video that has been read, from its first frame.
    func install(_ video: Video) {
        player.pause()
        isPlaying = false
        seekGeneration += 1
        seekInFlight = false
        seekNeeded = false

        self.video = video
        frame = 0
        zoom = nil
        isSelecting = false
        selection = 0...video.frames.lastIndex
        segmentAwaitingConfirmation = nil
        stillTask?.cancel()
        still = nil

        let item = AVPlayerItem(asset: video.asset)
        var outputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if video.isHDR {
            // The same conversion the exporter asks for, so a paused HDR frame looks like its PNG.
            outputSettings[AVVideoColorPropertiesKey] = FrameImage.standardRangeColor
        }
        let output = AVPlayerItemVideoOutput(outputSettings: outputSettings)
        item.add(output)
        videoOutput = output
        observe(item)
        player.replaceCurrentItem(with: item)
        requestSeek()
        loadThumbnails(for: video)
    }

    /// Waits — not for long — until the first frame of a video that has just been installed is
    /// ready to be drawn, so that a new window can come up with its picture already in place.
    func firstFrame() async {
        for _ in 0..<100 {
            guard still == nil, video != nil, !isPlaying else { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func observe(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        for observer in itemObservers {
            center.removeObserver(observer)
        }
        itemObservers = [
            AVPlayerItem.didPlayToEndTimeNotification,
            AVPlayerItem.failedToPlayToEndTimeNotification,
        ].map { name in
            center.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.playbackStopped(atEnd: name == AVPlayerItem.didPlayToEndTimeNotification)
                }
            }
        }

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            let message = item.error.map { PlayerModel.explanation(of: $0) }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    // Make sure the first frame is on screen even if the early seek was dropped.
                    if !self.isPlaying { self.requestSeek() }
                case .failed:
                    self.show(Notice(kind: .failure, message: "This video can't be played. \(message ?? "")"))
                default:
                    break
                }
            }
        }
    }

    // MARK: - Closing

    /// Stops everything for good: the window is closing. An export still under way ends where
    /// it is, as it would have if the app had quit.
    func shutDown() {
        loadTask?.cancel()
        loadID = UUID()
        thumbnailTask?.cancel()
        stillTask?.cancel()
        noticeTask?.cancel()
        exportTask?.cancel()

        seekGeneration += 1
        seekInFlight = false
        seekNeeded = false
        isPlaying = false
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemObservers = []
        statusObservation = nil
        videoOutput = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Playback

    func togglePlayback() {
        guard video != nil, segmentAwaitingConfirmation == nil else { return }
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let video, !isPlaying else { return }
        if frame >= video.frames.lastIndex {
            // At the end: start over, like any player.
            frame = 0
            seekNeeded = true
        }
        isPlaying = true
        stillTask?.cancel()
        if seekNeeded || seekInFlight {
            pumpSeek()          // playback starts as soon as the seek settles
        } else {
            player.play()
        }
    }

    func pause() {
        guard let video, isPlaying else { return }
        isPlaying = false
        player.pause()
        // Land exactly on the frame that was showing, so stepping and exporting are unambiguous.
        // (If a seek is still settling, `frame` already holds where we're headed.)
        if !seekInFlight, !seekNeeded {
            frame = video.frames.index(at: player.currentTime().seconds)
        }
        requestSeek()
    }

    /// Moves the playhead by a number of frames (negative goes back). Pauses if playing.
    func step(by delta: Int) {
        guard let video, segmentAwaitingConfirmation == nil else { return }
        pause()
        let target = video.frames.clamped(frame + delta)
        guard target != frame else { return }
        frame = target
        requestSeek()
    }

    /// Moves the playhead to a frame. Pauses if playing.
    func scrub(toFrame index: Int) {
        guard let video else { return }
        pause()
        let target = video.frames.clamped(index)
        guard target != frame else { return }
        frame = target
        requestSeek()
    }

    /// The frame that's on screen right now, whether paused or playing.
    private var visibleFrame: Int {
        guard let video else { return 0 }
        return isPlaying ? video.frames.index(at: player.currentTime().seconds) : frame
    }

    private func playerClockChanged(to time: CMTime) {
        guard isPlaying, !seekInFlight, let video else { return }
        frame = video.frames.index(at: time.seconds)
        // The video is moving on screen now, so the still that covered it can go. (It stays up
        // until this point so that starting playback never shows a gap.)
        if still != nil { still = nil }
    }

    private func playbackStopped(atEnd: Bool) {
        guard let video, isPlaying else { return }
        isPlaying = false
        player.pause()
        frame = atEnd ? video.frames.lastIndex : video.frames.index(at: player.currentTime().seconds)
        requestSeek()
    }

    // MARK: - Exact seeking

    private func requestSeek() {
        seekNeeded = true
        pumpSeek()
    }

    private func pumpSeek() {
        guard let video else { return }
        guard !seekInFlight else { return }
        guard seekNeeded else {
            if isPlaying { player.play() }
            return
        }
        seekNeeded = false
        seekInFlight = true
        stillTask?.cancel()
        let generation = seekGeneration
        let target = frame
        player.seek(to: video.frames.times[target], toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seekInFlight = false
                if finished { self.showStill(of: target) }
                self.pumpSeek()
            }
        }
    }

    // MARK: - The paused frame

    /// Puts up the frame the player has just landed on as a still. Does nothing while playing.
    private func showStill(of index: Int) {
        guard !isPlaying, let video, let videoOutput else { return }
        if let decoded = Self.decodedFrame(index, of: video, from: videoOutput) {
            still = decoded
            return
        }

        // The frame nearly always reaches the output together with the seek; now and then it
        // trails by a few milliseconds. A newer seek, or playback, cancels the wait.
        stillTask = Task { [weak self] in
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(3))
                guard let self, !Task.isCancelled, !self.isPlaying, self.videoOutput === videoOutput else { return }
                if let decoded = Self.decodedFrame(index, of: video, from: videoOutput) {
                    self.still = decoded
                    return
                }
            }
            // No frame to draw: uncover the player's own layer rather than show a stale one.
            if let self, !Task.isCancelled, self.videoOutput === videoOutput {
                self.still = nil
            }
        }
    }

    /// Frame `index` as decoded by the player, or nil if the output doesn't hold exactly that
    /// frame (yet).
    private static func decodedFrame(_ index: Int, of video: Video, from output: AVPlayerItemVideoOutput) -> StillFrame? {
        var shown = CMTime.invalid
        guard let pixels = output.copyPixelBuffer(forItemTime: video.frames.times[index], itemTimeForDisplay: &shown),
              shown.isNumeric, video.frames.index(at: shown.seconds) == index,
              let image = FrameImage.snapshot(of: pixels, orientation: video.orientation) else { return nil }
        return StillFrame(index: index, image: image)
    }

    // MARK: - Zooming

    /// The size of the picture in its own pixels, as it's shown (upright).
    var pictureSize: CGSize? {
        guard let video else { return nil }
        return CGSize(width: video.displaySize.width.rounded(), height: video.displaySize.height.rounded())
    }

    private var viewport: Viewport? {
        guard let pictureSize else { return nil }
        let viewport = Viewport(picture: pictureSize, view: stage)
        return viewport.isUsable ? viewport : nil
    }

    /// The view that shows the picture has this many screen pixels for it now.
    func stageChanged(to size: CGSize) {
        guard size != stage else { return }
        stage = size
        // A zoomed picture stays zoomed, but the window may have grown past its edge.
        if let zoom, let viewport {
            let kept = viewport.kept(zoom)
            if kept != zoom { self.zoom = kept }
        }
    }

    func zoomIn() {
        guard let viewport else { return }
        zoom = viewport.step(zoom, up: true)
    }

    func zoomOut() {
        guard let viewport else { return }
        zoom = viewport.step(zoom, up: false)
    }

    func zoomToFit() {
        zoom = nil
    }

    /// One pixel of the screen for each of the video.
    func zoomToActualSize() {
        guard let viewport else { return }
        zoom = viewport.zoom(zoom, to: 1, around: viewport.middle)
    }

    /// A pinch going on: the zoom follows it, about the point under the pointer (`anchor`, in
    /// screen pixels from the top left of the picture's area).
    func magnify(by factor: CGFloat, around anchor: CGPoint) {
        guard let viewport, factor > 0 else { return }
        // Fingers that have only come to rest on the trackpad begin a pinch that hasn't gone
        // anywhere yet: the fitted picture stays as it's drawn until it has.
        guard zoom != nil || factor != 1 else { return }
        zoom = viewport.zoom(zoom, to: (zoom?.scale ?? viewport.fitScale) * factor, around: anchor)
    }

    /// The pinch is over: the zoom comes to rest on the fitted picture, or on a whole number
    /// of screen pixels per pixel of the video. Around the middle, if nobody says where.
    func endMagnifying(around anchor: CGPoint?) {
        guard let viewport, let zoom else { return }
        self.zoom = viewport.rest(for: zoom, around: anchor ?? viewport.middle)
    }

    /// The part of the picture the window shows, in the video's own pixels from its top left
    /// corner; nil while it shows the whole of it.
    var visiblePart: CGRect? {
        guard let viewport, let zoom, let pictureSize else { return nil }
        let part = viewport.visible(at: zoom)
        return part.isEmpty || part.size == pictureSize ? nil : part
    }

    /// What to call the zoom the picture is at: "300%" — three screen pixels for each of the
    /// video's — or, for the whole picture, "Fit" and how much that comes to.
    var zoomDescription: String? {
        guard let viewport else { return nil }
        func percent(_ scale: CGFloat) -> String { "\(Int((scale * 100).rounded()))%" }
        guard let zoom else { return "Fit · \(percent(viewport.fitScale))" }
        return percent(zoom.scale)
    }

    /// A double tap, or a double click: a closer look at that point, or back to the whole picture.
    func toggleZoom(around anchor: CGPoint) {
        guard let viewport else { return }
        zoom = viewport.toggled(zoom, around: anchor)
    }

    /// Moves the zoomed picture by so many screen pixels.
    func scroll(by delta: CGSize) {
        guard let viewport, let zoom else { return }
        self.zoom = viewport.scrolled(zoom, by: delta)
    }

    // MARK: - Segment selection

    func toggleSelecting() {
        guard video != nil else { return }
        isSelecting.toggle()
    }

    func stopSelecting() {
        isSelecting = false
    }

    /// Drags the start of the segment to a frame and shows that frame.
    func setSelectionStart(_ index: Int) {
        guard let video else { return }
        let start = min(video.frames.clamped(index), selection.upperBound)
        selection = start...selection.upperBound
        scrub(toFrame: start)
    }

    /// Drags the end of the segment to a frame and shows that frame.
    func setSelectionEnd(_ index: Int) {
        guard let video else { return }
        let end = max(video.frames.clamped(index), selection.lowerBound)
        selection = selection.lowerBound...end
        scrub(toFrame: end)
    }

    /// Starts the segment at the frame on screen.
    func markSelectionStart() {
        guard video != nil else { return }
        let index = visibleFrame
        selection = index...max(selection.upperBound, index)
        isSelecting = true
    }

    /// Ends the segment at the frame on screen.
    func markSelectionEnd() {
        guard video != nil else { return }
        let index = visibleFrame
        selection = min(selection.lowerBound, index)...index
        isSelecting = true
    }

    // MARK: - Exporting

    func exportCurrentFrame() {
        guard let video, segmentAwaitingConfirmation == nil else { return }
        exportSingleFrame(visibleFrame, of: video)
    }

    func exportSegment() {
        guard let video, isSelecting, exportProgress == nil else { return }
        if selection.count > Self.confirmationThreshold {
            framesAwaitingConfirmation = selection.count
            segmentAwaitingConfirmation = selection
        } else {
            startSegmentExport(selection, of: video)
        }
    }

    func confirmSegmentExport() {
        guard let range = segmentAwaitingConfirmation, let video, exportProgress == nil else { return }
        segmentAwaitingConfirmation = nil
        startSegmentExport(range, of: video)
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func exportSingleFrame(_ index: Int, of video: Video) {
        let folder = exportFolder
        let name = frameFileName(index, of: video)
        let source = video.exportSource

        Task {
            let url = await reserveURL(in: folder, name: name, pathExtension: "png")
            defer { reservedURLs.remove(url) }
            do {
                let outcome = try await FrameExporter.export(source, range: index...index, into: folder, fileName: { _ in url.lastPathComponent }, progress: { _ in })
                guard outcome.written == 1 else { throw VideoError.imageCreationFailed }
                show(Notice(kind: .success, message: "Saved \(url.lastPathComponent) to \(folder.lastPathComponent)", revealURL: url))
            } catch {
                show(Notice(kind: .failure, message: "Couldn't export frame \((index + 1).formatted()). \(Self.explanation(of: error))"))
            }
        }
    }

    private func startSegmentExport(_ range: ClosedRange<Int>, of video: Video) {
        guard range.count > 1 else {
            exportSingleFrame(range.lowerBound, of: video)
            return
        }

        let digits = frameNumberDigits(of: video)
        let name = video.name
        let folderName = "\(name)_frames_\(Self.padded(range.lowerBound + 1, digits))-\(Self.padded(range.upperBound + 1, digits))"
        let parent = exportFolder
        let source = video.exportSource
        let total = range.count
        exportProgress = ExportProgress(completed: 0, total: total)

        exportTask = Task {
            let folder = await reserveURL(in: parent, name: folderName, pathExtension: "")
            defer { reservedURLs.remove(folder) }
            do {
                let outcome = try await FrameExporter.export(
                    source,
                    range: range,
                    into: folder,
                    fileName: { index in
                        "\(name)_frame_\(Self.padded(index + 1, digits)).png"
                    },
                    progress: { completed in
                        Task { @MainActor in
                            guard let current = self.exportProgress else { return }
                            self.exportProgress?.completed = max(current.completed, completed)
                        }
                    }
                )
                let count = outcome.written.formatted()
                if outcome.wasCancelled {
                    if outcome.written == 0 {
                        rmdir(folder.path)      // only ever removes an empty folder
                        show(Notice(kind: .info, message: "Export cancelled."))
                    } else {
                        show(Notice(kind: .info, message: "Export cancelled. \(count) frames were already saved to \(folder.lastPathComponent)", revealURL: folder, duration: .seconds(10)))
                    }
                } else if outcome.written == total {
                    show(Notice(kind: .success, message: "Exported \(count) frames to \(folder.lastPathComponent)", revealURL: folder, duration: .seconds(10)))
                } else {
                    show(Notice(kind: .info, message: "Exported \(count) of \(total.formatted()) frames to \(folder.lastPathComponent)", revealURL: folder, duration: .seconds(10)))
                }
            } catch {
                show(Notice(kind: .failure, message: "The export failed. \(Self.explanation(of: error))"))
            }
            exportProgress = nil
            exportTask = nil
        }
    }

    // MARK: - File names

    private func frameNumberDigits(of video: Video) -> Int {
        max(4, String(video.frames.count).count)
    }

    /// Frame numbers in file names start at 1, matching the counter in the window.
    private func frameFileName(_ index: Int, of video: Video) -> String {
        "\(video.name)_frame_\(Self.padded(index + 1, frameNumberDigits(of: video)))"
    }

    nonisolated private static func padded(_ number: Int, _ digits: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: max(digits - text.count, 0)) + text
    }

    /// Picks a file or folder name that isn't taken, either on disk or by another export
    /// that's still running, and holds it until it's removed from `reservedURLs`.
    /// Nothing is ever overwritten: "-2", "-3"… is appended until the name is free.
    ///
    /// The disk is checked off the main thread, because the first access to a protected
    /// folder such as Downloads waits for the system's permission prompt.
    private func reserveURL(in folder: URL, name: String, pathExtension: String) async -> URL {
        var attempt = 1
        while true {
            var candidate = folder.appendingPathComponent(attempt == 1 ? name : "\(name)-\(attempt)", isDirectory: pathExtension.isEmpty)
            if !pathExtension.isEmpty {
                candidate.appendPathExtension(pathExtension)
            }
            attempt += 1

            guard !reservedURLs.contains(candidate) else { continue }
            reservedURLs.insert(candidate)
            if await Self.fileExists(at: candidate) {
                reservedURLs.remove(candidate)
            } else {
                return candidate
            }
        }
    }

    @concurrent
    private static func fileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Export folder

    /// Where frames are saved: one folder for the whole app, whichever window it's chosen in.
    var exportFolder: URL { ExportFolder.shared.url }

    var exportsToDownloads: Bool { ExportFolder.shared.isDownloads }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exportFolder
        panel.prompt = "Choose"
        panel.message = "Choose where exported frames are saved"
        present(panel) { url in
            ExportFolder.shared.choose(url)
        }
    }

    func resetExportFolder() {
        ExportFolder.shared.reset()
    }

    func revealExportFolder() {
        NSWorkspace.shared.open(exportFolder)
    }

    private func present(_ panel: NSOpenPanel, onChoose: @escaping @MainActor (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { onChoose(url) }
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: - Notices

    /// AVFoundation's descriptions are often just a title ("Cannot Open"); the failure
    /// reason, when there is one, says what's actually wrong.
    nonisolated private static func explanation(of error: Error) -> String {
        if error is VideoError { return error.localizedDescription }
        let detail = error as NSError
        return detail.localizedFailureReason ?? detail.localizedDescription
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [id = notice.id] in
            try? await Task.sleep(for: notice.kind == .failure ? .seconds(10) : notice.duration)
            if !Task.isCancelled, self.notice?.id == id {
                self.notice = nil
            }
        }
    }

    // MARK: - Thumbnails

    /// Number of filmstrip cells; chosen so cells are roughly frame-shaped in a normal window.
    private static func thumbnailCount(for video: Video) -> Int {
        let aspect = video.displaySize.height > 0 ? video.displaySize.width / video.displaySize.height : 16.0 / 9
        let cellWidth = max(TimelineMetrics.stripHeight * aspect, 1)
        return min(max(Int((1400 / cellWidth).rounded(.up)), 6), 48)
    }

    private func loadThumbnails(for video: Video) {
        thumbnailTask?.cancel()
        let count = Self.thumbnailCount(for: video)
        thumbnails = Array(repeating: nil, count: count)

        let start = video.frames.startSeconds
        let cell = video.frames.span / Double(count)
        let times = (0..<count).map { index in
            CMTime(seconds: start + (Double(index) + 0.5) * cell, preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: video.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1000, height: TimelineMetrics.stripHeight * 2)
        // Any frame inside the cell will do; that lets the generator stop at a nearby keyframe.
        let tolerance = CMTime(seconds: cell / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        thumbnailTask = Task {
            for await result in generator.images(for: times) {
                if Task.isCancelled { return }
                let slot = Int(((result.requestedTime.seconds - start) / cell).rounded(.down))
                guard let image = try? result.image, thumbnails.indices.contains(slot) else { continue }
                thumbnails[slot] = image
            }
        }
    }
}
