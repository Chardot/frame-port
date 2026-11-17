import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture ready to be sent to an agent: a PNG — or a JPEG, where the PNG would be too heavy.
struct Shot: Sendable {
    var data: Data
    var mimeType: String
    var width: Int
    var height: Int
    /// How many times each pixel of the video is repeated along a side.
    var enlargement = 1
    var isScaledDown = false

    /// What to say of a picture that isn't the pixels themselves any more.
    var lossNote: String {
        mimeType == "image/jpeg" ? " — as a JPEG, since a PNG of it would be too large to send" : ""
    }
}

/// Frames made into pictures for an agent: how big one may be, how many go in one answer, and
/// the reading of several at a time. Both the app and `frameport-mcp` send frames this way,
/// so a frame looks the same whichever of them was asked for it.
enum FramePictures {
    enum Limit {
        /// No picture goes out longer than this on a side, or with more pixels than this. It's
        /// as much as a model takes in; anything bigger would only be scaled down on its way.
        static let side = 2576.0
        static let pixels = 3_750_000.0
        /// A part of a frame is enlarged by a whole factor, at most this one, for as long as
        /// its longer side stays within what any model takes in without scaling it.
        static let enlargement = 16
        static let enlargedSide = 1568
        /// No picture goes out heavier than this: a PNG that would be becomes a JPEG. (Sent
        /// as text, a picture is a third bigger, and agents take 5 MB of that at most.)
        static let bytes = 3_000_000

        /// An answer made of many pictures — the frames of a segment — has no more of them
        /// than this, and all of them together come to no more than this many tokens and
        /// bytes. What an agent runs in counts an answer in tokens and cuts it short past
        /// a number of them — 25,000 in Claude Code, which this keeps well away from. A
        /// picture is a token for every 28 × 28 pixels or so, and some more go with each
        /// one: its caption, and a line of the agent's own on where it has put the picture.
        /// The bytes are for the agent having to carry every picture along for the rest of
        /// the conversation. (How many pictures there can be is something `MCPTool` tells
        /// agents, in `frameport-mcp`.)
        static let pictures = 48
        static let answerTokens = 20_000.0
        static let pixelsPerToken = 784.0
        static let tokensWithEachPicture = 150.0
        static let answerBytes = 4_000_000
        /// Frames no further apart than this are read in one go, the ones between them
        /// decoded and dropped; further apart, finding each on its own is quicker.
        static let skippedFrames = 8
        /// An answer about where a video changes lists no more stretches than this: the
        /// rest are for another call.
        static let stretches = 40
    }

    /// How big a picture may be to go out.
    struct Room: Sendable {
        var pixels = Limit.pixels
        var bytes = Limit.bytes

        /// What each of `count` pictures may be for all of them to go out in one answer.
        static func shared(among count: Int) -> Room {
            let count = max(count, 1)
            let tokens = Limit.answerTokens / Double(count) - Limit.tokensWithEachPicture
            return Room(pixels: min(Limit.pixels, tokens * Limit.pixelsPerToken), bytes: min(Limit.bytes, Limit.answerBytes / count))
        }
    }

    // MARK: - One picture

    /// The whole of `image`: as it is, or scaled down to what a model takes in.
    @concurrent
    static func shot(of image: CGImage) async -> Shot? {
        whole(image, in: Room())
    }

    /// `part` of `image`, each of its pixels repeated as a block of up to `ceiling` on a
    /// side if that leaves it a reasonable size; scaled down, if it's that big a part.
    @concurrent
    static func shot(of image: CGImage, part: CGRect, enlargedUpTo ceiling: Int) async -> Shot? {
        self.part(part, of: image, enlargedUpTo: ceiling, in: Room())
    }

    /// The whole of `image`: as it is, or scaled down to what there's `room` for.
    static func whole(_ image: CGImage, in room: Room) -> Shot? {
        let width = Double(image.width), height = Double(image.height)
        let factor = min(Limit.side / max(width, height), (room.pixels / (width * height)).squareRoot())
        guard factor < 1 else { return shot(holding: image, in: room) }
        let smaller = CGSize(width: max((width * factor).rounded(.down), 1), height: max((height * factor).rounded(.down), 1))
        guard let scaled = FrameImage.resampled(image, to: smaller), var shot = shot(holding: scaled, in: room) else { return nil }
        shot.isScaledDown = true
        return shot
    }

    /// `part` of `image`, enlarged by a whole factor for as long as there's `room` for it,
    /// and scaled down if there isn't even for the part as it is.
    static func part(_ part: CGRect, of image: CGImage, enlargedUpTo ceiling: Int, in room: Room) -> Shot? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let inside = part.integral.intersection(bounds)
        guard !inside.isNull, inside.width >= 1, inside.height >= 1, let cut = image.cropping(to: inside) else { return nil }
        let fitting = Int((room.pixels / Double(cut.width * cut.height)).squareRoot())
        let factor = min(ceiling, Limit.enlargement, Limit.enlargedSide / max(cut.width, cut.height), fitting)
        guard factor > 1 else { return whole(cut, in: room) }
        guard let blocks = enlarged(cut, by: factor), var shot = shot(holding: blocks, in: room) else { return nil }
        shot.enlargement = factor
        return shot
    }

    private static func shot(holding image: CGImage, in room: Room) -> Shot? {
        if let png = FrameExporter.pngData(of: image), png.count <= room.bytes {
            return Shot(data: png, mimeType: "image/png", width: image.width, height: image.height)
        }
        // More detail than a PNG of a sendable size holds — film grain, noise. A JPEG then,
        // as good a one as fits.
        let qualities = [0.9, 0.8, 0.7, 0.55, 0.4]
        for quality in qualities {
            let jpeg = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if jpeg.length <= room.bytes || quality == qualities.last {
                return Shot(data: jpeg as Data, mimeType: "image/jpeg", width: image.width, height: image.height)
            }
        }
        return nil
    }

    /// `image` with each of its pixels repeated as a `factor` × `factor` block: nothing is
    /// blended, so what was one pixel of the video can be told from its neighbours.
    private static func enlarged(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width, height = image.height
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return nil }
        // Into memory of the same colour space at the same size: the pixels as they are.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.bindMemory(to: UInt32.self, capacity: width * height) else { return nil }

        let wide = width * factor, tall = height * factor
        var blocks = Data(count: wide * tall * 4)
        blocks.withUnsafeMutableBytes { buffer in
            guard let target = buffer.bindMemory(to: UInt32.self).baseAddress else { return }
            for y in 0..<height {
                let row = target + y * factor * wide
                for x in 0..<width {
                    let pixel = pixels[y * width + x]
                    for offset in 0..<factor {
                        row[x * factor + offset] = pixel
                    }
                }
                for copy in 1..<factor {
                    (row + copy * wide).update(from: row, count: wide)
                }
            }
        }
        guard let provider = CGDataProvider(data: blocks as CFData) else { return nil }
        return CGImage(
            width: wide, height: tall,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: wide * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Many pictures

    /// The frames of `run` to show when no more than `most` fit: all of them, or one every
    /// `step` and the last.
    static func sample(of run: ClosedRange<Int>, atMost most: Int) -> (frames: [Int], step: Int) {
        guard run.count > most, most > 1 else { return (Array(run), 1) }
        // One step fewer than there's room for: the last frame may not fall on a step.
        let step = Int((Double(run.count - 1) / Double(most - 1)).rounded(.up))
        var frames = Array(stride(from: run.lowerBound, through: run.upperBound, by: step))
        if frames.last != run.upperBound {
            frames.append(run.upperBound)
        }
        return (frames, step)
    }

    /// What `make` makes of each of `frames`, which rise. Several stretches of the file are
    /// asked for at a time: frames that are next to each other, or nearly, in one go, and the
    /// rest each on its own — reading everything in between would take longer. (How many
    /// are being read at once, for everyone who's asking, is `FrameExporter`'s to say.)
    @concurrent
    static func shots(
        of frames: [Int],
        in source: FrameExporter.Source,
        each make: @escaping @Sendable (CGImage) -> Shot?
    ) async throws -> [Int: Shot] {
        let readers = 4
        // No stretch holds more than its share, so that there's something for every reader.
        let share = max((frames.count + readers - 1) / readers, 1)
        var stretches: [[Int]] = []
        for frame in frames {
            if let last = stretches.last?.last, frame - last <= Limit.skippedFrames, stretches[stretches.count - 1].count < share {
                stretches[stretches.count - 1].append(frame)
            } else {
                stretches.append([frame])
            }
        }

        return try await withThrowingTaskGroup(of: [(index: Int, made: Shot?)].self) { group in
            var waiting = stretches[...]
            var reading = 0
            var shots: [Int: Shot] = [:]
            while true {
                while reading < readers, let stretch = waiting.popFirst() {
                    group.addTask {
                        try await FrameExporter.frames(stretch, of: source) { _, picture in make(picture) }
                    }
                    reading += 1
                }
                guard let read = try await group.next() else { break }
                reading -= 1
                for (index, shot) in read {
                    shots[index] = shot
                }
            }
            return shots
        }
    }
}
