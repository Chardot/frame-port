import AVFoundation

/// The presentation timestamp of every frame in a video track, in display order.
///
/// The table is built from the samples that are actually in the file rather than from the
/// nominal frame rate, so screen recordings and other variable-frame-rate videos stay
/// frame-accurate: "frame 120" always means the 121st picture the video contains.
struct FrameTable: Sendable {
    /// Presentation timestamp of each frame, ascending.
    let times: [CMTime]
    /// The same timestamps in seconds, for fast lookups.
    let seconds: [Double]
    /// When the last frame stops being displayed.
    let endSeconds: Double

    init(times: [CMTime], duration: CMTime) {
        self.times = times
        self.seconds = times.map(\.seconds)

        let last = seconds.last ?? 0
        let first = seconds.first ?? 0
        let typicalFrame = seconds.count > 1 ? (last - first) / Double(seconds.count - 1) : 1.0 / 30
        let declaredEnd = duration.isNumeric ? duration.seconds : 0
        // Some files declare a duration that stops at (or before) the last frame's timestamp.
        self.endSeconds = declaredEnd > last + typicalFrame / 4 ? declaredEnd : last + max(typicalFrame, 0.001)
    }

    var count: Int { times.count }
    var lastIndex: Int { max(times.count - 1, 0) }
    var startSeconds: Double { seconds.first ?? 0 }
    var span: Double { max(endSeconds - startSeconds, 0.000_001) }

    func clamped(_ index: Int) -> Int {
        min(max(index, 0), lastIndex)
    }

    /// The frame on screen at `time`: the last one whose timestamp is at or before it.
    func index(at time: Double) -> Int {
        clamped(boundaryCount(upTo: time + Self.timestampSlack) - 1)
    }

    /// Frame boundaries are numbered `0...count`: boundary `k` is where frame `k` starts, and
    /// boundary `count` is the end of the video. Returns the boundary closest to `time`.
    func nearestBoundary(to time: Double) -> Int {
        let upper = boundaryCount(upTo: time)          // first boundary strictly after `time`
        guard upper > 0 else { return 0 }
        let before = seconds[upper - 1]
        let after = upper < count ? seconds[upper] : endSeconds
        return (time - before) <= (after - time) ? upper - 1 : upper
    }

    /// Position of a frame boundary along the timeline, from 0 (start) to 1 (end).
    func fraction(ofBoundary boundary: Int) -> Double {
        guard count > 0 else { return 0 }
        let time = boundary >= count ? endSeconds : seconds[max(boundary, 0)]
        return min(max((time - startSeconds) / span, 0), 1)
    }

    /// The time a timeline position (0...1) corresponds to.
    func time(atFraction fraction: Double) -> Double {
        startSeconds + min(max(fraction, 0), 1) * span
    }

    /// Number of frames whose timestamp is `<= time`.
    private func boundaryCount(upTo time: Double) -> Int {
        var low = 0
        var high = seconds.count
        while low < high {
            let middle = (low + high) / 2
            if seconds[middle] <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Absorbs rounding when a timestamp is converted between timescales.
    private static let timestampSlack = 0.000_1
}

extension FrameTable {
    /// Loads the presentation time of every frame in `track`. Nothing is decoded.
    @concurrent
    static func load(track: AVAssetTrack, of asset: AVAsset) async throws -> FrameTable {
        let duration = try await asset.load(.duration)
        let (edits, hasSampleIndex) = try await track.load(.segments, .canProvideSampleCursors)
        let mediaTimes = try (hasSampleIndex ? indexedSampleTimes(of: track) : nil) ?? scannedSampleTimes(of: track, in: asset)
        let times = presentationTimes(forMediaTimes: mediaTimes, edits: edits)
        guard !times.isEmpty else { throw VideoError.noFrames }
        return FrameTable(times: times, duration: duration)
    }

    /// Media timestamps straight from the file's sample index: instant, even for huge files.
    /// Nil when the container has no such index (anything that isn't QuickTime / MPEG-4).
    static func indexedSampleTimes(of track: AVAssetTrack) throws -> [CMTime]? {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        var times: [CMTime] = []
        var visited = 0
        repeat {
            if visited % 4096 == 0 { try Task.checkCancellation() }
            visited += 1
            let time = cursor.presentationTimeStamp
            if time.isNumeric { times.append(time) }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return times
    }

    /// Media timestamps gathered by walking every sample in the file, without decoding.
    /// Slower than the index (it reads the whole file) but works for any container.
    static func scannedSampleTimes(of track: AVAssetTrack, in asset: AVAsset) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoError.unreadable }

        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard sample.numSamples > 0, !sample.isHiddenFromDisplay else { continue }

            if sample.numSamples == 1 {
                let time = sample.presentationTimeStamp
                if time.isNumeric { times.append(time) }
            } else if let timings = try? sample.sampleTimingInfos() {
                if timings.count == 1, let run = timings.first, run.presentationTimeStamp.isNumeric, run.duration.isNumeric {
                    // A single timing entry describes a run of equally long samples.
                    for offset in 0..<sample.numSamples {
                        times.append(run.presentationTimeStamp + CMTimeMultiply(run.duration, multiplier: Int32(offset)))
                    }
                } else {
                    for timing in timings where timing.presentationTimeStamp.isNumeric {
                        times.append(timing.presentationTimeStamp)
                    }
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? VideoError.unreadable }
        return times
    }

    /// Sample timestamps live in the media's own timeline. The track's edits decide when,
    /// and whether, each sample is shown: files with B-frames, for instance, start their
    /// media a couple of frames late and use an edit to shift it back to zero. This applies
    /// the edits, giving the times the player and the decoder use.
    static func presentationTimes(forMediaTimes mediaTimes: [CMTime], edits: [AVAssetTrackSegment]) -> [CMTime] {
        // Samples are stored in decode order; with B-frames that differs from display order.
        let samples = sortedUnique(mediaTimes)
        let mappings = edits
            .filter { !$0.isEmpty }
            .map(\.timeMapping)
            .filter { mapping in
                mapping.source.start.isNumeric && mapping.source.duration.isNumeric && mapping.source.duration > .zero
                    && mapping.target.start.isNumeric && mapping.target.duration.isNumeric
            }
        guard !samples.isEmpty, !mappings.isEmpty else { return samples }

        var shown: [CMTime] = []
        shown.reserveCapacity(samples.count)
        for mapping in mappings {
            let source = mapping.source
            let target = mapping.target
            let rate = source.duration == target.duration ? 1 : target.duration.seconds / source.duration.seconds

            // The edit opens on whichever sample is on screen at its start: the last one at or
            // before it. Every later sample that begins inside the edit follows.
            var index = samples.partitioningIndex { $0 > source.start }
            if index > 0 { index -= 1 }
            while index < samples.count, samples[index] < source.end {
                let offset = max(samples[index] - source.start, .zero)
                shown.append(target.start + (rate == 1 ? offset : CMTimeMultiplyByFloat64(offset, multiplier: rate)))
                index += 1
            }
        }
        return sortedUnique(shown)
    }

    private static func sortedUnique(_ times: [CMTime]) -> [CMTime] {
        var unique: [CMTime] = []
        unique.reserveCapacity(times.count)
        for time in times.sorted() where unique.last != time {
            unique.append(time)
        }
        return unique
    }
}

private extension Array {
    /// Index of the first element for which `belongsInSecondHalf` is true, assuming the
    /// array is already partitioned by it (binary search).
    func partitioningIndex(where belongsInSecondHalf: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if belongsInSecondHalf(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

private extension CMSampleBuffer {
    /// Decode-only samples (e.g. leading frames trimmed by an edit) never reach the screen.
    var isHiddenFromDisplay: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        return (first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool) ?? false
    }
}

enum VideoError: LocalizedError {
    case noVideoTrack
    case noFrames
    case unreadable
    case imageCreationFailed
    case writeFailed(URL)
    case folderNotWritable(URL)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This file doesn't contain a video track."
        case .noFrames: "This video doesn't contain any frames."
        case .unreadable: "This video couldn't be read."
        case .imageCreationFailed: "The frame couldn't be converted to an image."
        case .writeFailed(let url): "Couldn't write \(url.lastPathComponent)."
        case .folderNotWritable(let folder):
            "FramePort isn't allowed to save to “\(folder.lastPathComponent)”. Allow it in System Settings › Privacy & Security › Files & Folders, or choose another export folder from the File menu."
        }
    }
}
