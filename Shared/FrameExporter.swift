import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Decodes frames straight from the file and writes each one as a PNG.
///
/// Frames are read sequentially with `AVAssetReader`, which is far faster than asking for
/// one image at a time, and each frame is matched against the `FrameTable` so the files
/// that come out are exactly the frames that were asked for.
enum FrameExporter {
    /// Everything the exporter needs from a loaded video. The AVFoundation objects are
    /// never mutated after loading, which is what makes handing them to a background
    /// task safe.
    struct Source: @unchecked Sendable {
        let asset: AVAsset
        let track: AVAssetTrack
        let frames: FrameTable
        /// The track's preferred transform (rotation / mirroring).
        let orientation: CGAffineTransform
        /// Size of one exported image, used to bound memory while exporting.
        let pixelSize: CGSize
    }

    struct Outcome: Sendable {
        /// Number of PNGs written.
        let written: Int
        /// True when the task was cancelled before every frame had been written.
        let wasCancelled: Bool
    }

    /// Writes one PNG per frame in `range` into `folder`, creating the folder if needed.
    /// Cancelling the task stops the export; frames already being written are finished.
    ///
    /// - Parameters:
    ///   - fileName: Returns the name of the file for a frame index.
    ///   - progress: Called from a background thread with the number of files written so far.
    @concurrent
    static func export(
        _ source: Source,
        range: ClosedRange<Int>,
        into folder: URL,
        fileName: @escaping @Sendable (Int) -> String,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> Outcome {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let frames = source.frames
        let (reader, output) = try startReading(source, around: range)
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        // Decoding is quick; PNG compression is the slow part, so that runs in parallel.
        // Cap the number of decoded frames waiting to be written to keep memory in check.
        let bytesPerFrame = max(Int(source.pixelSize.width * source.pixelSize.height) * 4, 1)
        let parallelWrites = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 1_500_000_000 / bytesPerFrame))

        return try await withThrowingTaskGroup(of: Void.self) { group in
            var writing = 0
            var written = 0
            var previousIndex = range.lowerBound - 1
            var wasCancelled = false

            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }

                let index = frames.index(at: sample.presentationTimeStamp.seconds)
                if index > range.upperBound { break }
                guard index > previousIndex else { continue }
                previousIndex = index

                let image = try makeImage(from: buffer, orientation: source.orientation)
                let url = folder.appendingPathComponent(fileName(index), isDirectory: false)

                if writing >= parallelWrites {
                    try await group.next()
                    writing -= 1
                    written += 1
                    progress(written)
                }
                group.addTask {
                    try writePNG(image, to: url)
                }
                writing += 1
            }

            if !wasCancelled, reader.status == .failed {
                throw reader.error ?? VideoError.unreadable
            }
            // Let the writes that already started finish, so no half-written file is left behind.
            while try await group.next() != nil {
                written += 1
                progress(written)
            }
            return Outcome(written: written, wasCancelled: wasCancelled)
        }
    }

    // MARK: - Looking at frames

    /// One frame as the image its PNG holds, without writing anything: for whoever wants to
    /// look at a frame rather than keep it.
    static func image(of index: Int, in source: Source) async throws -> CGImage {
        try await look {
            let (reader, output) = try startReading(source, around: index...index)
            defer {
                if reader.status == .reading { reader.cancelReading() }
            }
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let found = source.frames.index(at: sample.presentationTimeStamp.seconds)
                if found == index {
                    return try makeImage(from: buffer, orientation: source.orientation)
                }
                if found > index { break }
            }
            throw reader.error ?? VideoError.imageCreationFailed
        }
    }

    /// Several frames as the images their PNGs hold, read in one go, and each put through
    /// `make` as soon as it's decoded: what's kept of a frame is what was made of it, not the
    /// frame at full size. `indices` rise, and are close enough together for everything from
    /// the first to the last to be worth decoding. A frame that doesn't come out of the file
    /// is missing from what's returned.
    static func frames<Made: Sendable>(
        _ indices: [Int],
        of source: Source,
        each make: @escaping @Sendable (Int, CGImage) throws -> Made
    ) async throws -> [(index: Int, made: Made)] {
        guard let first = indices.first, let last = indices.last else { return [] }
        return try await look {
            let (reader, output) = try startReading(source, around: first...last)
            defer {
                if reader.status == .reading { reader.cancelReading() }
            }

            var wanted = indices[...]
            var made: [(index: Int, made: Made)] = []
            while !wanted.isEmpty, let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let found = source.frames.index(at: sample.presentationTimeStamp.seconds)
                // A frame that has been passed without showing up isn't going to.
                while let next = wanted.first, next < found {
                    wanted.removeFirst()
                }
                guard wanted.first == found else { continue }
                wanted.removeFirst()
                made.append((found, try make(found, try makeImage(from: buffer, orientation: source.orientation))))
            }
            if !wanted.isEmpty, reader.status == .failed {
                throw reader.error ?? VideoError.unreadable
            }
            return made
        }
    }

    /// Where frames are read to be looked at: on threads kept for it, a few readers at a
    /// time, whoever is asking.
    ///
    /// A reader holds its thread while the file is decoded, and those who look are agents:
    /// one may ask for dozens of frames at once. Read on the threads that all async code
    /// shares — there's one per core — that many readers held every one of them, none ever
    /// got a frame, and nothing in the app that needed such a thread ran again.
    private static let lookers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FramePort.lookers"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static func look<Seen: Sendable>(_ read: @escaping @Sendable () throws -> Seen) async throws -> Seen {
        try await withCheckedThrowingContinuation { continuation in
            lookers.addOperation {
                continuation.resume(with: Result { try read() })
            }
        }
    }

    /// The bytes of the PNG that `export` writes for an image.
    static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// What a frame is decoded into to become a picture.
    private static let pictureSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        // Ask for standard-range Rec. 709 so HDR and wide-gamut sources are tone-mapped
        // by the decoder pipeline before they reach us.
        AVVideoColorPropertiesKey: FrameImage.standardRangeColor,
    ]

    /// Starts decoding at the frames of `range`. What comes out has to be matched against
    /// the `FrameTable`: there's a frame of margin on each side, so that nothing depends on
    /// how the reader rounds the edges of its time range.
    ///
    /// Frames come out as pictures unless other `settings` are asked for. Whoever reads
    /// them does it inside `look`, or `export`'s own way: never on a thread async code shares.
    static func startReading(_ source: Source, around range: ClosedRange<Int>, as settings: [String: Any]? = nil) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let frames = source.frames
        let reader = try AVAssetReader(asset: source.asset)
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: settings ?? pictureSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.unreadable }
        reader.add(output)

        let firstRead = max(range.lowerBound - 1, 0)
        let readEnd = range.upperBound + 2
        reader.timeRange = CMTimeRange(
            start: frames.times[firstRead],
            end: readEnd <= frames.lastIndex ? frames.times[readEnd] : .positiveInfinity
        )
        guard reader.startReading() else { throw reader.error ?? VideoError.unreadable }
        return (reader, output)
    }

    // MARK: - Pixels

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Turns a decoded frame into an upright, square-pixel, sRGB image — what the player shows.
    private static func makeImage(from buffer: CVPixelBuffer, orientation: CGAffineTransform) throws -> CGImage {
        let image = FrameImage.upright(CIImage(cvPixelBuffer: buffer), from: buffer, orientation: orientation)
        let bounds = CGRect(x: 0, y: 0, width: image.extent.width.rounded(), height: image.extent.height.rounded())
        guard bounds.width >= 1, bounds.height >= 1,
              let rendered = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: sRGB) else {
            throw VideoError.imageCreationFailed
        }
        return rendered.droppingAlpha()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            let folder = url.deletingLastPathComponent()
            throw FileManager.default.isWritableFile(atPath: folder.path) ? VideoError.writeFailed(url) : VideoError.folderNotWritable(folder)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            let folder = url.deletingLastPathComponent()
            throw FileManager.default.isWritableFile(atPath: folder.path) ? VideoError.writeFailed(url) : VideoError.folderNotWritable(folder)
        }
    }
}

