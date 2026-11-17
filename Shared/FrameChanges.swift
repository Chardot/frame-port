import AVFoundation
import CoreVideo

/// Finds where the picture changes in a run of frames, by comparing every one of them with
/// what came before it — so that an agent can be told where something happens in a video
/// without being sent its frames to look through.
///
/// What's compared isn't the pixels but the picture in blocks of 8 × 8, each by its average:
/// of the luma, and of the two chromas. The frames of a video are never the same twice.
/// Compression leaves the pixels of a picture that's standing still a little different from
/// one frame to the next, some of them by more than a faint change in the picture would.
/// Over a block that noise evens out, and a change doesn't.
///
/// And a frame is compared with the picture as it was at rest, not just with the frame before
/// it: a slow fade moves too little from one frame to the next to tell from noise, and adds up.
///
/// The numbers below come from measuring: test videos with known things at known frames, and
/// screen recordings made on an iPhone, whose picture is cleaner at rest than it is for a
/// few frames after it has moved.
enum FrameChanges {
    /// A stretch of frames over which the picture changes.
    struct Stretch: Sendable, Equatable {
        /// From the first frame that isn't the picture as it was, to the last one that moves:
        /// the frame before these is the picture before the change, and the last of them the
        /// picture it leaves.
        var frames: ClosedRange<Int>
        /// The part of the picture that was different at some point from how it was before,
        /// in the video's pixels from its top left corner.
        var place: CGRect
        /// How much of what was compared is different once it's over, from 0 to 1.
        var share: Double
        /// Whether the picture is back to what it was, once it's over.
        var returns: Bool
        /// Whether it was still going where the frames to compare ended.
        var isOpen = false
    }

    struct Report: Sendable {
        /// The frames that were compared: the ones asked for, unless time ran out first.
        var frames: ClosedRange<Int>
        var stretches: [Stretch]
        /// False if there wasn't the time for all the frames that were asked for.
        var isComplete: Bool
        /// Whether the video is noisy enough for a faint change to go unseen in it.
        var isNoisy: Bool
    }

    enum Limit {
        /// How far the average of a block has to be from what it was at rest, out of 255,
        /// for the picture to have changed…
        static let changed = 5.0
        /// …and from where it last was, for it to be moving still. More than a picture strays
        /// by while it settles: for a few frames after it has moved, a recording made on an
        /// iPhone goes on sharpening what's there, by up to 3 or so.
        static let moving = 3.5
        /// Chroma has a quarter of the samples in a block, so its average is that much less
        /// steady: it has to be this many times further off.
        static let chromaOverLuma = 2.0
        /// The average of everything that's compared is steadier than any block's by far, and
        /// a fade moves it when it's too slow to move a block: it only has to be this far
        /// from what it was, as a part of what a block has to be. (More, where it's only a
        /// few blocks that are compared.)
        static let wholeOverBlock = 0.1
        /// In a noisy video both are more: this many times what its noise comes to.
        static let changedOverNoise = 1.4
        static let movingOverNoise = 1.2
        /// Where two frames of a picture at rest differ by more than this, it isn't noise.
        static let mostNoise = 12.0
        /// How much of the noise that was measured the video's noise is taken to be no worse
        /// than. The little that's left out may be a faint change that looked like noise.
        static let worstNoise = 0.97
        /// How many frames are looked at in a row, at each place a video's noise is measured…
        static let restingFrames = 32
        /// …and how many of them in a row, after one, have to stay close to that one for
        /// the picture to count as at rest over them.
        static let restingSteps = 7
        /// A picture that hasn't moved for longer than this many seconds has come to rest.
        /// A shorter pause is part of the change: a frame that was dropped, an animation
        /// drawn at half the rate of the recording.
        static let rest = 0.1
        /// A picture that has edged a little away from what it was and then not moved for
        /// this many seconds has only settled: what it is now is the picture at rest. And a
        /// change that only drifts — the red pill of an iPhone that's recording, getting
        /// brighter — is over when it hasn't moved for this long, not for `rest`: it takes
        /// longer than that between one step that counts and the next.
        static let settling = 0.5
        /// What the second frame of a video differs by from its first, as a share of the
        /// picture, when it's only that the first frame is the rougher one.
        static let roughStart = 0.01
        /// How long a search may take, in seconds. Whoever asked is told how far it got.
        static let seconds = 12.0
    }

    /// Compares the frames of `run` with each other, in the part of the picture `region` is
    /// (all of it, without one), and says over which of them the picture changes — as far
    /// as it gets in `seconds`.
    static func find(in video: Video, frames run: ClosedRange<Int>, region: CGRect?, within seconds: Double = Limit.seconds) async throws -> Report {
        let source = video.exportSource
        let pictureSize = video.pictureSize
        let times = video.frames.seconds
        return try await FrameExporter.look {
            var search = Search(source: source, pictureSize: pictureSize, region: region, seconds: times)
            return try search.go(over: run, until: Date().addingTimeInterval(seconds))
        }
    }

    // MARK: - The search

    private struct Search {
        let source: FrameExporter.Source
        let pictureSize: CGSize
        let region: CGRect?
        let seconds: [Double]
        private var grid: Grid?

        init(source: FrameExporter.Source, pictureSize: CGSize, region: CGRect?, seconds: [Double]) {
            self.source = source
            self.pictureSize = pictureSize
            self.region = region
            self.seconds = seconds
        }

        mutating func go(over run: ClosedRange<Int>, until deadline: Date) throws -> Report {
            // How noisy a video is doesn't depend on which of its frames are asked about, and
            // what counts as a change shouldn't either.
            let level = try noise(over: 0...source.frames.lastIndex)
            let changed = max(Limit.changed, level * Limit.changedOverNoise)
            let moving = max(Limit.moving, level * Limit.movingOverNoise)
            let seconds = self.seconds

            var stretches: [Stretch] = []
            var last = run.lowerBound
            var isComplete = true

            // What the picture is at rest, and how it has been edging away from that, if it
            // has, without having changed yet.
            var rest = Picture()
            var edging: Edging?
            // The change that's under way, if one is.
            var change: Change?

            var limits = (changed: Limits(), moving: Limits())
            var previous = Picture()
            var seen = 0
            try read(run) { index, picture, grid in
                seen += 1
                if seen == 1 {
                    limits = (grid.limits(for: changed), grid.limits(for: moving))
                    rest = picture
                    previous = picture
                    last = index
                    return true
                }
                defer { previous = picture }
                // Whether the picture has moved since the frame before, as far as it has to
                // for that to count. Something that drifts doesn't: it only adds up.
                let jumped = grid.differ(picture, previous, by: limits.moving)

                if let under = change {
                    // A change has run its course if the picture didn't move for a while after
                    // it — which, in a recording that only has a frame when something changed,
                    // may be the wait before this very frame. A drift is given longer: it moves
                    // too slowly to be seen to at every frame.
                    var isOver = seconds[index] - seconds[under.lastMoved] > (under.isDrift ? Limit.settling : Limit.rest)
                    // And it's over where something else begins: where the picture moves again
                    // after a pause, however short, in another part of it than before — or
                    // moves at once there, while this has only been drifting.
                    if !isOver, jumped, under.isDrift || under.lastMoved < index - 1 {
                        let moved = grid.difference(picture, previous, over: limits.moving)
                        isOver = !moved.isEmpty && !under.box.isEmpty && !moved.overlaps(under.box)
                    }
                    if isOver {
                        stretches.append(under.stretch(in: grid, limits: limits.changed))
                        rest = under.reached
                        edging = nil
                        change = nil
                    }
                }
                if var under = change {
                    if grid.differ(picture, under.reached, by: limits.moving) {
                        under.lastMoved = index
                        under.reached = picture
                        under.box.add(grid.difference(picture, under.before, over: limits.changed))
                        if jumped { under.isDrift = false }
                    }
                    change = under
                } else {
                    let difference = grid.difference(picture, rest, over: limits.changed)
                    if difference.count > 0 || grid.wholeDiffers(picture, rest, by: limits.changed) {
                        var box = Box()
                        box.add(difference)
                        // It began where the picture started creeping towards this, if it crept:
                        // if it has drifted here, that is, or was edging away a moment ago
                        // still — and in the place that has changed now. Something else that
                        // had stirred a while before, or somewhere else, isn't the beginning
                        // of this.
                        var start = index
                        if let creeping = edging, !jumped || seconds[index] - seconds[creeping.lastMoved] <= Limit.rest / 2 {
                            let crept = grid.difference(creeping.reached, rest, over: limits.moving)
                            if crept.isEmpty || difference.isEmpty || crept.overlaps(difference) {
                                start = creeping.since
                            }
                        }
                        change = Change(start: start, before: rest, lastMoved: index, reached: picture, box: box, isDrift: !jumped)
                        edging = nil
                    } else if grid.differ(picture, rest, by: limits.moving) {
                        if var creeping = edging {
                            if grid.differ(picture, creeping.reached, by: limits.moving) {
                                creeping.lastMoved = index
                                creeping.reached = picture
                                edging = creeping
                            } else if seconds[index] - seconds[creeping.lastMoved] > Limit.settling {
                                // It went a little way and stopped: a picture settling, as it
                                // does for a moment when a recording starts or after it has
                                // moved. That's the picture at rest now.
                                rest = picture
                                edging = nil
                            }
                        } else {
                            edging = Edging(since: index, lastMoved: index, reached: picture)
                        }
                    } else {
                        edging = nil
                    }
                }
                last = index
                if seen % 16 == 0, Date() > deadline, index < run.upperBound {
                    isComplete = false
                    return false
                }
                return true
            }
            if let under = change, let grid {
                var stretch = under.stretch(in: grid, limits: limits.changed)
                // Cut off rather than over, if the last frame that was compared still moved
                // and there are more after it.
                stretch.isOpen = under.lastMoved == last && last < seconds.count - 1
                stretches.append(stretch)
            }
            // The very first frame of a video is often rougher than the ones that follow it,
            // enough for the second to look like a change: a small one, over at once.
            if run.lowerBound == 0, let first = stretches.first, first.frames == 1...1, first.share < Limit.roughStart {
                stretches.removeFirst()
            }
            return Report(frames: run.lowerBound...last, stretches: stretches, isComplete: isComplete, isNoisy: changed > Limit.changed)
        }

        /// How far apart two frames of this video get when nothing has changed between them:
        /// the most that the average of a block differs, out of 255 — nothing, if the picture
        /// wasn't found at rest anywhere it was looked at.
        ///
        /// It's measured only where the picture is at rest: over frames in a row that stay
        /// close to the first of them. Two frames that are a little apart aren't noise if the
        /// picture is on its way somewhere — the end of a scroll, a fade, a video playing in
        /// a corner of the screen — and counting those would make every recording of something
        /// that moves look like a noisy one.
        ///
        /// Looked for at several places along the video: its noise isn't the same all the
        /// way through, and it's the worst of it that matters — short of the very worst, which
        /// may be frames that are a faint change apart, and look like noise too.
        private mutating func noise(over run: ClosedRange<Int>) throws -> Double {
            let length = Limit.restingFrames, places = 8
            // All of a short video, a few stretches of a long one — and a few more, between
            // those, if the picture wasn't at rest in any of them.
            var rounds: [[ClosedRange<Int>]] = [[run]]
            if run.count > length * places {
                let last = run.upperBound - length + 1
                let spacing = (run.count - length) / (places - 1)
                rounds = [0, spacing / 2].map { offset in
                    (0..<places).map { run.lowerBound + offset + $0 * spacing }.filter { $0 <= last }.map { $0...($0 + length - 1) }
                }
            }
            for bursts in rounds {
                var shifts: [Double] = []
                for burst in bursts {
                    // The frames since the picture last went anywhere: the first of them, and
                    // how far each was from the one before it.
                    var first: Picture?
                    var previous = Picture()
                    var steps: [Double] = []
                    try read(burst) { _, picture, grid in
                        defer { previous = picture }
                        guard let anchor = first else {
                            first = picture
                            return true
                        }
                        let step = grid.largestShift(picture, previous)
                        guard step <= Limit.mostNoise, grid.largestShift(picture, anchor) <= Limit.mostNoise else {
                            first = picture
                            steps = []
                            return true
                        }
                        steps.append(step)
                        if steps.count == Limit.restingSteps {
                            shifts += steps
                            first = picture
                            steps = []
                        }
                        return true
                    }
                }
                if !shifts.isEmpty {
                    shifts.sort()
                    return shifts[min(Int(Double(shifts.count) * Limit.worstNoise), shifts.count - 1)]
                }
            }
            return 0
        }

        /// Decodes the frames of `range` one after another and hands `each` what's compared
        /// of each. Stops when `each` returns false.
        private mutating func read(_ range: ClosedRange<Int>, each: (Int, Picture, Grid) throws -> Bool) throws {
            let (reader, output) = try FrameExporter.startReading(source, around: range, as: [
                // The frame as it's stored, nearly: luma and chroma, eight bits of each.
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ])
            defer {
                if reader.status == .reading { reader.cancelReading() }
            }
            var previous = range.lowerBound - 1
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let index = source.frames.index(at: sample.presentationTimeStamp.seconds)
                if index > range.upperBound { break }
                guard index > previous else { continue }
                previous = index

                let grid: Grid
                if let made = self.grid {
                    grid = made
                } else {
                    grid = Grid(over: buffer, pictureSize: pictureSize, orientation: source.orientation, region: region)
                    self.grid = grid
                }
                guard grid.fits(buffer) else { throw VideoError.unreadable }
                if try !each(index, grid.picture(of: buffer), grid) { return }
            }
            if reader.status == .failed {
                throw reader.error ?? VideoError.unreadable
            }
        }
    }

    /// A picture at rest that's a little way from what it was, and may be on its way further.
    private struct Edging {
        /// The first frame that was that little way off.
        var since: Int
        /// The last frame at which it moved on, and what it was then.
        var lastMoved: Int
        var reached: Picture
    }

    /// A change that's under way.
    private struct Change {
        /// The first frame that wasn't the picture as it had been.
        var start: Int
        /// The picture as it had been, at rest.
        var before: Picture
        /// The last frame at which the picture moved, and what it was then.
        var lastMoved: Int
        var reached: Picture
        /// Where it has been different from `before`.
        var box: Box
        /// Whether it has only drifted so far: come to be different a little at a time,
        /// without the picture ever moving much from one frame to the next.
        var isDrift: Bool

        func stretch(in grid: Grid, limits: Limits) -> Stretch {
            let left = grid.difference(reached, before, over: limits)
            let wholeDiffers = grid.wholeDiffers(reached, before, by: limits)
            // No one block is far from what it was, and all of them are a little: a faint
            // change of the whole picture.
            let isFaint = box.isEmpty
            return Stretch(
                frames: start...max(lastMoved, start),
                place: isFaint ? grid.wholePlace : grid.place(of: box),
                share: left.count == 0 && wholeDiffers ? 1 : Double(left.count) / Double(grid.columns * grid.rows),
                returns: left.count == 0 && !wholeDiffers
            )
        }
    }

    /// What's compared of a frame: the sum of the luma of each block, then of each of its two
    /// chromas, and the average of each of the three over everything that's compared.
    private struct Picture {
        var sums: [Int32] = []
        var means = [0.0, 0.0, 0.0]
    }

    /// How far apart two pictures may be and still count as the same: the sum of each block,
    /// and the three averages of the whole.
    private struct Limits {
        var sums: [Int32] = []
        var mean = 0.0
    }

    /// The blocks that differ between two pictures: how many, and the rows and columns they're in.
    private struct Box {
        var count = 0
        var minColumn = Int.max, maxColumn = Int.min
        var minRow = Int.max, maxRow = Int.min

        var isEmpty: Bool { maxColumn < minColumn }

        func overlaps(_ other: Box) -> Bool {
            !isEmpty && !other.isEmpty && minColumn <= other.maxColumn && other.minColumn <= maxColumn
                && minRow <= other.maxRow && other.minRow <= maxRow
        }

        mutating func add(_ other: Box) {
            guard !other.isEmpty else { return }
            minColumn = min(minColumn, other.minColumn)
            maxColumn = max(maxColumn, other.maxColumn)
            minRow = min(minRow, other.minRow)
            maxRow = max(maxRow, other.maxRow)
        }
    }

    // MARK: - The picture in blocks

    /// How a frame is cut into blocks to be compared: the part of the decoded picture that's
    /// looked at, in blocks of 8 × 8 pixels of luma, each with the 4 × 4 of chroma that go
    /// with it. The blocks of the last column and of the last row take in what's left over.
    private struct Grid {
        static let side = 8

        /// The part that's compared, in the pixels of the decoded picture: even all round,
        /// so that chroma goes with it.
        let x: Int, y: Int, width: Int, height: Int
        let columns: Int, rows: Int
        /// The size of the decoded picture this was made for.
        let bufferWidth: Int, bufferHeight: Int
        /// From the decoded picture to the one that's shown: upright, and in the video's pixels.
        private let upright: CGAffineTransform
        private let pictureSize: CGSize

        init(over buffer: CVPixelBuffer, pictureSize: CGSize, orientation: CGAffineTransform, region: CGRect?) {
            let bufferWidth = CVPixelBufferGetWidth(buffer), bufferHeight = CVPixelBufferGetHeight(buffer)
            self.bufferWidth = bufferWidth
            self.bufferHeight = bufferHeight
            self.pictureSize = pictureSize

            // The picture that's shown is the decoded one turned as the track says, and
            // stretched if its pixels aren't square. (Video transforms count from the top
            // left, as these pixels do.)
            let turned = abs(orientation.b) > 0.5
            let natural = turned ? CGSize(width: pictureSize.height, height: pictureSize.width) : pictureSize
            var upright = CGAffineTransform(scaleX: natural.width / CGFloat(bufferWidth), y: natural.height / CGFloat(bufferHeight))
            upright = upright.concatenating(CGAffineTransform(a: orientation.a, b: orientation.b, c: orientation.c, d: orientation.d, tx: 0, ty: 0))
            let whole = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight).applying(upright)
            self.upright = upright.concatenating(CGAffineTransform(translationX: -whole.minX, y: -whole.minY))

            var part = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight)
            if let region {
                let asked = region.applying(self.upright.inverted()).standardized.integral.intersection(part)
                if !asked.isNull, asked.width >= 1, asked.height >= 1 {
                    part = asked
                }
            }
            let left = Int(part.minX) & ~1, top = Int(part.minY) & ~1
            let right = min((Int(part.maxX) + 1) & ~1, bufferWidth & ~1), bottom = min((Int(part.maxY) + 1) & ~1, bufferHeight & ~1)
            x = left
            y = top
            width = max(right - left, 2)
            height = max(bottom - top, 2)
            columns = max(width / Self.side, 1)
            rows = max(height / Self.side, 1)
        }

        func fits(_ buffer: CVPixelBuffer) -> Bool {
            CVPixelBufferGetWidth(buffer) == bufferWidth && CVPixelBufferGetHeight(buffer) == bufferHeight
                && CVPixelBufferGetPlaneCount(buffer) == 2
        }

        private var blocks: Int { columns * rows }

        /// Where the pixels of a block's column or row begin and end, in luma; the last takes
        /// what's left over.
        private func span(_ index: Int, of count: Int, in length: Int) -> Range<Int> {
            index * Self.side..<(index == count - 1 ? length : (index + 1) * Self.side)
        }

        /// What's compared of a frame.
        func picture(of buffer: CVPixelBuffer) -> Picture {
            let sums = sums(of: buffer)
            let blocks = self.blocks
            var totals = [0.0, 0.0, 0.0]
            for plane in 0..<3 {
                var total = 0
                for block in plane * blocks..<(plane + 1) * blocks {
                    total += Int(sums[block])
                }
                totals[plane] = Double(total)
            }
            let chromaSamples = Double(max((width / 2) * (height / 2), 1))
            return Picture(sums: sums, means: [totals[0] / Double(width * height), totals[1] / chromaSamples, totals[2] / chromaSamples])
        }

        /// The sums of a frame: of the luma of each block, then of each of its two chromas.
        private func sums(of buffer: CVPixelBuffer) -> [Int32] {
            var sums = [Int32](repeating: 0, count: blocks * 3)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return sums }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaWidth = min(width / 2, CVPixelBufferGetWidthOfPlane(buffer, 1) - x / 2)
            let chromaHeight = min(height / 2, CVPixelBufferGetHeightOfPlane(buffer, 1) - y / 2)
            let full = columns - 1, half = Self.side / 2

            sums.withUnsafeMutableBufferPointer { sums in
                guard let out = sums.baseAddress else { return }
                for row in 0..<rows {
                    let into = out + row * columns
                    for line in span(row, of: rows, in: height) {
                        let pixels = luma.advanced(by: (y + line) * lumaStride + x)
                        for column in 0..<full {
                            let eight = pixels.loadUnaligned(fromByteOffset: column * Self.side, as: UInt64.self)
                            let pairs = (eight & 0x00FF_00FF_00FF_00FF) &+ ((eight >> 8) & 0x00FF_00FF_00FF_00FF)
                            into[column] &+= Int32(truncatingIfNeeded: (pairs &* 0x0001_0001_0001_0001) >> 48)
                        }
                        var rest: Int32 = 0
                        for offset in full * Self.side..<width {
                            rest &+= Int32(pixels.load(fromByteOffset: offset, as: UInt8.self))
                        }
                        into[full] &+= rest
                    }

                    // Chroma: half as many samples each way, the two kinds side by side.
                    let blue = out + blocks + row * columns, red = out + 2 * blocks + row * columns
                    let lines = row * half..<(row == rows - 1 ? chromaHeight : (row + 1) * half)
                    for line in lines {
                        let samples = chroma.advanced(by: (y / 2 + line) * chromaStride + x)
                        for column in 0..<full {
                            let four = samples.loadUnaligned(fromByteOffset: column * Self.side, as: UInt64.self)
                            blue[column] &+= Int32(truncatingIfNeeded: ((four & 0x00FF_00FF_00FF_00FF) &* 0x0001_0001_0001_0001) >> 48)
                            red[column] &+= Int32(truncatingIfNeeded: (((four >> 8) & 0x00FF_00FF_00FF_00FF) &* 0x0001_0001_0001_0001) >> 48)
                        }
                        var restBlue: Int32 = 0, restRed: Int32 = 0
                        for sample in full * half..<chromaWidth {
                            restBlue &+= Int32(samples.load(fromByteOffset: sample * 2, as: UInt8.self))
                            restRed &+= Int32(samples.load(fromByteOffset: sample * 2 + 1, as: UInt8.self))
                        }
                        blue[full] &+= restBlue
                        red[full] &+= restRed
                    }
                }
            }
            return sums
        }

        /// How many pixels of luma, and samples of each chroma, are in each block.
        private func areas() -> (luma: [Int32], chroma: [Int32]) {
            var luma = [Int32](repeating: 0, count: blocks), chroma = luma
            let chromaWidth = width / 2, chromaHeight = height / 2, half = Self.side / 2
            for row in 0..<rows {
                let tall = span(row, of: rows, in: height).count
                let chromaTall = (row == rows - 1 ? chromaHeight : (row + 1) * half) - row * half
                for column in 0..<columns {
                    let wide = span(column, of: columns, in: width).count
                    let chromaWide = (column == columns - 1 ? chromaWidth : (column + 1) * half) - column * half
                    luma[row * columns + column] = Int32(wide * tall)
                    chroma[row * columns + column] = Int32(max(chromaWide * chromaTall, 1))
                }
            }
            return (luma, chroma)
        }

        /// What two pictures have to differ by for the average of a block to differ by
        /// `levels` — twice that, for a block's chroma — and for the average of the whole to
        /// differ by its part of that.
        func limits(for levels: Double) -> Limits {
            let (luma, chroma) = areas()
            let ofLuma = luma.map { Int32((Double($0) * levels).rounded(.up)) }
            let ofChroma = chroma.map { Int32((Double($0) * levels * Limit.chromaOverLuma).rounded(.up)) }
            // The fewer the blocks, the less their average is steadier than any one of them.
            let steadier = max(Limit.wholeOverBlock, 1 / Double(blocks).squareRoot())
            return Limits(sums: ofLuma + ofChroma + ofChroma, mean: levels * steadier)
        }

        /// The blocks whose average is further apart in `a` and `b` than `limits` allow.
        func difference(_ a: Picture, _ b: Picture, over limits: Limits) -> Box {
            var box = Box()
            let blocks = self.blocks
            let a = a.sums, b = b.sums, limits = limits.sums
            for row in 0..<rows {
                for column in 0..<columns {
                    let block = row * columns + column
                    guard abs(a[block] - b[block]) >= limits[block]
                        || abs(a[blocks + block] - b[blocks + block]) >= limits[blocks + block]
                        || abs(a[2 * blocks + block] - b[2 * blocks + block]) >= limits[2 * blocks + block] else { continue }
                    box.count += 1
                    box.minColumn = min(box.minColumn, column)
                    box.maxColumn = max(box.maxColumn, column)
                    box.minRow = min(box.minRow, row)
                    box.maxRow = max(box.maxRow, row)
                }
            }
            return box
        }

        /// Whether the average of everything that's compared is further apart in `a` and `b`
        /// than `limits` allow.
        func wholeDiffers(_ a: Picture, _ b: Picture, by limits: Limits) -> Bool {
            for plane in 0..<3 where abs(a.means[plane] - b.means[plane]) >= limits.mean {
                return true
            }
            return false
        }

        /// Whether `a` and `b` are further apart than `limits` allow: in any block, or as a whole.
        func differ(_ a: Picture, _ b: Picture, by limits: Limits) -> Bool {
            if wholeDiffers(a, b, by: limits) { return true }
            let a = a.sums, b = b.sums, limits = limits.sums
            for index in 0..<a.count where abs(a[index] - b[index]) >= limits[index] {
                return true
            }
            return false
        }

        /// The most that the average of a block differs between `a` and `b`, out of 255,
        /// its chroma counted for as much less as it's less steady.
        func largestShift(_ a: Picture, _ b: Picture) -> Double {
            let (luma, chroma) = areas()
            let blocks = self.blocks
            let a = a.sums, b = b.sums
            var largest = 0.0
            for block in 0..<blocks {
                let chromaShift = max(abs(a[blocks + block] - b[blocks + block]), abs(a[2 * blocks + block] - b[2 * blocks + block]))
                largest = max(largest, Double(abs(a[block] - b[block])) / Double(luma[block]), Double(chromaShift) / Double(chroma[block]) / Limit.chromaOverLuma)
            }
            return largest
        }

        /// Everything that's compared, in the picture that's shown.
        var wholePlace: CGRect {
            CGRect(x: x, y: y, width: width, height: height).applying(upright).standardized.integral.intersection(CGRect(origin: .zero, size: pictureSize))
        }

        /// Where the blocks of `box` are in the picture that's shown, in the video's pixels
        /// from its top left corner.
        func place(of box: Box) -> CGRect {
            guard !box.isEmpty else { return .zero }
            let across = span(box.minColumn, of: columns, in: width).lowerBound..<span(box.maxColumn, of: columns, in: width).upperBound
            let down = span(box.minRow, of: rows, in: height).lowerBound..<span(box.maxRow, of: rows, in: height).upperBound
            let decoded = CGRect(x: x + across.lowerBound, y: y + down.lowerBound, width: across.count, height: down.count)
            return decoded.applying(upright).standardized.integral.intersection(CGRect(origin: .zero, size: pictureSize))
        }
    }
}
