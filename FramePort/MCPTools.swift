import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What an AI agent can ask of FramePort through its MCP server, answered: what's on screen,
/// and any frame of the videos that are open, or a run of them — the selected segment, to
/// begin with. It only looks — nothing asked here changes what the user sees, and nothing is
/// written to disk.
///
/// The tools are described to agents by `frameport-mcp` (`MCPTool`, there). What that says of
/// their arguments is what's honoured here, and a frame comes back as the image its PNG holds.
@MainActor
final class MCPTools {
    private let windows: VideoWindows

    init(windows: VideoWindows) {
        self.windows = windows
    }

    /// Answers a question that came over `MCPChannel`: a tool call in, its result out.
    func answer(_ question: Data) async -> Data {
        let result: Reply
        if let call = (try? JSONSerialization.jsonObject(with: question)) as? [String: Any],
           let name = call["name"] as? String {
            let arguments = call["arguments"] as? [String: Any] ?? [:]
            switch name {
            case "get_view": result = await view()
            case "get_frame": result = await frame(arguments)
            case "get_segment": result = await segment(arguments)
            default: result = .failure("This version of FramePort has no tool called “\(name)”.")
            }
        } else {
            result = .failure("FramePort couldn't make out the request.")
        }
        return await Self.encoded(result)
    }

    // MARK: - What's on screen

    private func view() async -> Reply {
        let tabs = windows.openTabs
        guard let model = windows.active, let video = model.video else {
            var lines = [windows.active?.isLoading == true
                ? "FramePort is opening a video and isn't showing it yet. Ask again in a moment."
                : "FramePort is open, but there's no video in the tab in front."]
            if tabs.contains(where: { $0.model.video != nil }) {
                lines += ["", "Its tabs:"] + Self.list(tabs, front: windows.active)
            }
            return Reply(parts: [.text(lines.joined(separator: "\n"))])
        }

        let index = model.frame
        let count = video.frames.count
        let name = video.url.lastPathComponent
        let zoom = model.zoom
        let visible = model.visiblePart

        var lines = [
            model.isPlaying
                ? "FramePort is playing “\(name)”. It was on frame \(index + 1) of \(count) when asked."
                : "FramePort is showing frame \(index + 1) of \(count) of “\(name)”, paused.",
            "",
            "File: \(video.url.path)",
            Self.summary(of: video),
            "Frame \(index + 1) is at \(Self.seconds(video.frames.seconds[index])) s.",
        ]
        if let zoom {
            let percent = Int((zoom.scale * 100).rounded())
            lines.append(visible.map { "Zoom: \(percent)% — only part of the picture is on screen: \(Self.place($0)), in the video's pixels from its top left corner." }
                ?? "Zoom: \(percent)% — the whole picture is on screen.")
        } else {
            lines.append("Zoom: none — the whole picture is on screen, fitted to the window.")
        }
        if model.isSelecting {
            let segment = model.selection
            lines.append("Segment: frames \(segment.lowerBound + 1) to \(segment.upperBound + 1) are selected (\(segment.count) frames).")
        } else {
            lines.append("Segment: none selected.")
        }
        if tabs.count > 1 {
            lines += ["", "Open videos, by tab:"] + Self.list(tabs, front: model)
        }

        let picture: CGImage
        do {
            picture = try await FrameExporter.image(of: index, in: video.exportSource)
        } catch {
            lines += ["", "The frame itself couldn't be read. \(error.localizedDescription)"]
            return Reply(parts: [.text(lines.joined(separator: "\n"))], isError: true)
        }

        guard let whole = await Self.shot(of: picture) else {
            lines += ["", "The frame itself couldn't be made into an image."]
            return Reply(parts: [.text(lines.joined(separator: "\n"))], isError: true)
        }
        var parts: [Reply.Part] = [
            .text(lines.joined(separator: "\n")),
            .text("Frame \(index + 1) — \(Self.caption(forWhole: whole, of: picture))"),
            .picture(whole),
        ]
        if let visible, let zoom, let part = await Self.shot(of: picture, part: visible, enlargedUpTo: Int(zoom.scale)) {
            parts += [.text("The part of it that's on screen — \(Self.caption(forPart: part, at: visible))"), .picture(part)]
        }
        return Reply(parts: parts)
    }

    // MARK: - Any frame

    private func frame(_ arguments: [String: Any]) async -> Reply {
        let tab: Tab
        let index: Int
        let region: CGRect?
        do throws(Refusal) {
            tab = try self.tab(Self.given(arguments["tab"]))
            index = try Self.given(arguments["frame"]).map { wanted throws(Refusal) in try Self.index(wanted, in: tab.video) } ?? tab.model.frame
            region = try Self.given(arguments["region"]).map { wanted throws(Refusal) in try Self.region(wanted, of: tab.pictureSize) }
        } catch {
            return .failure(error.message)
        }
        let model = tab.model, video = tab.video
        let name = video.url.lastPathComponent

        var text = "Frame \(index + 1) of \(video.frames.count) of “\(name)”\(tab.note), at \(Self.seconds(video.frames.seconds[index])) s."
        if index == model.frame {
            text += model === windows.active ? " It's the frame on screen." : " It's the frame that tab is on."
        }

        let picture: CGImage
        do {
            picture = try await FrameExporter.image(of: index, in: video.exportSource)
        } catch {
            return .failure("Frame \(index + 1) of “\(name)” couldn't be read. \(error.localizedDescription)")
        }
        if let region {
            guard let part = await Self.shot(of: picture, part: region, enlargedUpTo: Limit.enlargement) else {
                return .failure("That part of frame \(index + 1) couldn't be made into an image.")
            }
            return Reply(parts: [.text("\(text)\nOf it, \(Self.caption(forPart: part, at: region))"), .picture(part)])
        }
        guard let whole = await Self.shot(of: picture) else {
            return .failure("Frame \(index + 1) of “\(name)” couldn't be made into an image.")
        }
        return Reply(parts: [.text("\(text)\n\(Self.caption(forWhole: whole, of: picture).capitalizedFirst)"), .picture(whole)])
    }

    // MARK: - A run of frames

    private func segment(_ arguments: [String: Any]) async -> Reply {
        let asked = (from: Self.given(arguments["from"]), to: Self.given(arguments["to"]))
        let tab: Tab
        let run: ClosedRange<Int>
        let region: CGRect?
        do throws(Refusal) {
            tab = try self.tab(Self.given(arguments["tab"]))
            switch (asked.from, asked.to) {
            case (nil, nil):
                guard tab.model.isSelecting else {
                    throw Refusal(message: "No segment is selected in “\(tab.video.url.lastPathComponent)”\(tab.note). The user selects one with FramePort's “Select segment” button and the yellow handles it brings up, or the I and O keys. For a run of frames of your own choosing, give from and to.")
                }
                run = tab.model.selection
            case (let from?, let to?):
                let ends = (try Self.index(from, in: tab.video), try Self.index(to, in: tab.video))
                run = min(ends.0, ends.1)...max(ends.0, ends.1)
            default:
                throw Refusal(message: "from and to go together: give both for a run of frames of your own choosing, or neither for the segment selected in FramePort.")
            }
            region = try Self.given(arguments["region"]).map { wanted throws(Refusal) in try Self.region(wanted, of: tab.pictureSize) }
        } catch {
            return .failure(error.message)
        }
        let model = tab.model, video = tab.video
        let name = video.url.lastPathComponent

        // More frames than fit in an answer: every so many of them, then.
        let (shown, step) = Self.sample(of: run, atMost: Limit.pictures)
        let room = Room.shared(among: shown.count)
        let shots: [Int: Shot]
        do {
            shots = try await Self.shots(of: shown, in: video.exportSource) { picture in
                if let region {
                    Self.part(region, of: picture, enlargedUpTo: Limit.enlargement, in: room)
                } else {
                    Self.whole(picture, in: room)
                }
            }
        } catch {
            return .failure("Frames \(run.lowerBound + 1) to \(run.upperBound + 1) of “\(name)” couldn't be read. \(error.localizedDescription)")
        }
        guard let sample = shown.lazy.compactMap({ shots[$0] }).first else {
            return .failure("Frames \(run.lowerBound + 1) to \(run.upperBound + 1) of “\(name)” couldn't be made into images.")
        }

        // What these frames are.
        let seconds = video.frames.seconds
        var lines: [String] = []
        var what = run.count == 1
            ? "Frame \(run.lowerBound + 1) of “\(name)”\(tab.note)"
            : "Frames \(run.lowerBound + 1) to \(run.upperBound + 1) of “\(name)”\(tab.note)"
        if asked.from == nil {
            what += " — the segment selected in FramePort"
        }
        what += run.count == 1
            ? ": one frame, at \(Self.seconds(seconds[run.lowerBound])) s."
            : ": \(run.count) frames, from \(Self.seconds(seconds[run.lowerBound])) s to \(Self.seconds(seconds[run.upperBound])) s."
        if asked.from != nil, model.isSelecting {
            let selected = model.selection
            what += selected.count == 1
                ? " (The segment selected in FramePort is frame \(selected.lowerBound + 1).)"
                : " (The segment selected in FramePort is frames \(selected.lowerBound + 1) to \(selected.upperBound + 1).)"
        }
        lines.append(what)

        // How they're shown.
        let form: String
        if let region {
            var part = "\(Self.place(region)) of the picture"
            if sample.enlargement > 1 {
                part += ", enlarged \(sample.enlargement)×: each pixel of the video is \(Self.block(sample.enlargement))"
            } else if sample.isScaledDown {
                part += ", scaled down to \(sample.width) × \(sample.height) px"
            } else {
                part += ", pixel for pixel"
            }
            form = part
        } else if sample.isScaledDown {
            form = "the whole picture, scaled down to \(sample.width) × \(sample.height) px (it's \(Int(tab.pictureSize.width)) × \(Int(tab.pictureSize.height)) px)"
        } else {
            form = "the whole picture, \(sample.width) × \(sample.height) px"
        }
        if shown.count == run.count {
            lines.append(run.count == 1 ? "It follows: \(form)." : "All \(run.count) follow, in order. Each is \(form).")
        } else {
            let every = step == 2 ? "every other frame" : "every \(Self.ordinal(step)) frame"
            let last = (run.count - 1).isMultiple(of: step) ? "" : ", and the last one"
            lines.append("That's more than fit in one answer, so \(shown.count) of them follow, in order: \(every)\(last). For the frames in between, ask for a shorter run with from and to. Each is \(form).")
        }

        let jpegs = shown.filter { shots[$0]?.mimeType == "image/jpeg" }.count
        if jpegs > 0 {
            let which = jpegs == shots.count ? (jpegs == 1 ? "It's a JPEG" : "They're JPEGs") : "\(jpegs) of them are JPEGs"
            lines.append("\(which), since \(jpegs == 1 ? "a PNG of it" : "PNGs of them") would make the answer too large to send.")
        }
        if sample.isScaledDown, region == nil {
            lines.append("The more frames in an answer, the smaller each has to be. For a closer look, ask for a shorter run with from and to, for a region — that part of each frame — or for one frame at full size with get_frame.")
        }
        if region == nil, model === windows.active, let visible = model.visiblePart {
            lines.append("FramePort is zoomed in on \(Self.place(visible)): given as the region, that returns what's on screen there, frame by frame.")
        }

        var parts: [Reply.Part] = [.text(lines.joined(separator: "\n"))]
        for index in shown {
            guard let shot = shots[index] else {
                parts.append(.text("Frame \(index + 1) couldn't be read."))
                continue
            }
            var caption = "Frame \(index + 1), at \(Self.seconds(seconds[index])) s"
            if index == model.frame, !model.isPlaying {
                caption += model === windows.active ? " — the frame on screen" : " — the frame that tab is on"
            }
            parts += [.text(caption + ":"), .picture(shot)]
        }
        return Reply(parts: parts)
    }

    /// The frames of `run` to show when no more than `most` fit: all of them, or one every
    /// `step` and the last.
    nonisolated private static func sample(of run: ClosedRange<Int>, atMost most: Int) -> (frames: [Int], step: Int) {
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
    private static func shots(
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

    // MARK: - Words

    private static func summary(of video: Video) -> String {
        var parts = ["\(Int(video.displaySize.width.rounded())) × \(Int(video.displaySize.height.rounded())) px"]
        if let rate = video.frameRateText {
            parts.append(rate)
        }
        parts.append("\(String(format: "%.2f", video.frames.span)) s long")
        return "Picture: " + parts.joined(separator: ", ")
    }

    /// One line per tab, numbered as `get_frame` takes them.
    private static func list(_ tabs: [(model: PlayerModel, window: Int)], front: PlayerModel?) -> [String] {
        let severalWindows = Set(tabs.map(\.window)).count > 1
        return tabs.enumerated().map { position, tab in
            var line = "  \(position + 1). "
            if let video = tab.model.video {
                line += "\(video.url.lastPathComponent) — on frame \(tab.model.frame + 1) of \(video.frames.count)"
            } else {
                line += "(no video)"
            }
            if severalWindows {
                line += ", in window \(tab.window)"
            }
            if tab.model === front {
                line += " (in front)"
            }
            return line
        }
    }

    private static func seconds(_ time: Double) -> String {
        String(format: "%.3f", time)
    }

    /// A part of the picture, said the way `get_frame` takes one.
    private static func place(_ part: CGRect) -> String {
        "x \(Int(part.minX)), y \(Int(part.minY)), width \(Int(part.width)), height \(Int(part.height))"
    }

    private static func caption(forWhole shot: Shot, of picture: CGImage) -> String {
        guard shot.isScaledDown else { return "the whole picture, \(shot.width) × \(shot.height) px\(shot.lossNote):" }
        return "the whole picture, scaled down to \(shot.width) × \(shot.height) px\(shot.lossNote) (it's \(picture.width) × \(picture.height) px; get_frame with a region gives a part of it pixel for pixel):"
    }

    private static func caption(forPart shot: Shot, at part: CGRect) -> String {
        var caption = place(part)
        if shot.enlargement > 1 {
            caption += ", enlarged \(shot.enlargement)×: each pixel of the video is \(block(shot.enlargement)) here"
        } else if shot.isScaledDown {
            caption += ", scaled down to \(shot.width) × \(shot.height) px"
        }
        return caption + shot.lossNote + ":"
    }

    /// "a 5 × 5 block", "an 8 × 8 block": what a pixel of the video is in an enlarged picture.
    private static func block(_ factor: Int) -> String {
        "\(factor == 8 || factor == 11 ? "an" : "a") \(factor) × \(factor) block"
    }

    /// "3rd", "13th", "22nd".
    private static func ordinal(_ number: Int) -> String {
        let suffix: String
        switch (number % 10, number % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(number)\(suffix)"
    }

    // MARK: - Arguments

    /// Why a call can't be answered, in words for the agent that made it.
    private struct Refusal: Error {
        var message: String
    }

    /// One of the open videos, as a call asks for it.
    private struct Tab {
        /// Its number, as `get_view` lists the tabs.
        var number: Int
        var model: PlayerModel
        var video: Video
        var pictureSize: CGSize
        /// Whether there are other tabs to tell it from.
        var isOneOfSeveral: Bool

        /// Which tab it is, for a sentence about its video; nothing, where there's just the one.
        var note: String {
            isOneOfSeveral ? " (tab \(number))" : ""
        }
    }

    /// The video a call is about: the one in the tab it names or, if it names none, the one
    /// in front.
    private func tab(_ wanted: Any?) throws(Refusal) -> Tab {
        let tabs = windows.openTabs
        let number: Int
        if let wanted {
            guard let tab = Self.whole(wanted), tabs.indices.contains(tab - 1) else {
                let open = tabs.count == 1 ? "one tab" : "\(tabs.count) tabs, numbered from 1"
                throw Refusal(message: "There's no tab \(Self.plain(wanted)): FramePort has \(open). get_view lists them.")
            }
            number = tab
        } else {
            guard let front = windows.active, let position = tabs.firstIndex(where: { $0.model === front }) else {
                throw Refusal(message: "FramePort has no video open.")
            }
            number = position + 1
        }
        let model = tabs[number - 1].model
        guard let video = model.video, let pictureSize = model.pictureSize else {
            throw Refusal(message: wanted == nil ? "There's no video in the tab in front of FramePort." : "Tab \(number) has no video in it.")
        }
        return Tab(number: number, model: model, video: video, pictureSize: pictureSize, isOneOfSeveral: tabs.count > 1)
    }

    /// A frame of `video`, from the number an agent gave for it: the first is 1.
    private static func index(_ wanted: Any, in video: Video) throws(Refusal) -> Int {
        let count = video.frames.count
        guard let frame = whole(wanted), (1...count).contains(frame) else {
            throw Refusal(message: "There's no frame \(plain(wanted)) in “\(video.url.lastPathComponent)”: it has \(count) frames, numbered 1 to \(count).")
        }
        return frame - 1
    }

    /// The part of a picture an agent asked for, kept to what there is of the picture.
    private static func region(_ wanted: Any, of pictureSize: CGSize) throws(Refusal) -> CGRect {
        guard let rectangle = rectangle(wanted) else {
            throw Refusal(message: "A region is given as x, y, width and height — numbers, in the video's pixels from its top left corner.")
        }
        let inside = rectangle.integral.intersection(CGRect(origin: .zero, size: pictureSize))
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else {
            throw Refusal(message: "That region is outside the picture, which is \(Int(pictureSize.width)) × \(Int(pictureSize.height)) px.")
        }
        return inside
    }

    /// What an agent sent for an argument; nil if it sent nothing, or said so with a null.
    private static func given(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // `true` and `false` arrive as numbers too, and aren't.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    /// A whole number, from an agent that may have sent it as 44, 44.0 or "44".
    private static func whole(_ value: Any) -> Int? {
        guard let number = number(value), number == number.rounded(), abs(number) < 1e9 else { return nil }
        return Int(number)
    }

    private static func rectangle(_ value: Any) -> CGRect? {
        guard let sides = value as? [String: Any],
              let x = number(sides["x"]), let y = number(sides["y"]),
              let width = number(sides["width"]), let height = number(sides["height"]),
              [x, y, width, height].allSatisfy({ abs($0) < 1e9 }), width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// An argument as the agent wrote it, for telling it what was wrong with it.
    private static func plain(_ value: Any) -> String {
        if let text = value as? String { return "“\(text)”" }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return number.stringValue }
            return number.boolValue ? "true" : "false"
        }
        return "like that"
    }

    // MARK: - Pictures

    private enum Limit {
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
    }

    /// How big a picture may be to go out.
    private struct Room: Sendable {
        var pixels = Limit.pixels
        var bytes = Limit.bytes

        /// What each of `count` pictures may be for all of them to go out in one answer.
        static func shared(among count: Int) -> Room {
            let count = max(count, 1)
            let tokens = Limit.answerTokens / Double(count) - Limit.tokensWithEachPicture
            return Room(pixels: min(Limit.pixels, tokens * Limit.pixelsPerToken), bytes: min(Limit.bytes, Limit.answerBytes / count))
        }
    }

    /// A picture ready to be sent: a PNG — or a JPEG, where the PNG would be too heavy.
    private struct Shot {
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

    /// The whole of `image`: as it is, or scaled down to what a model takes in.
    @concurrent
    private static func shot(of image: CGImage) async -> Shot? {
        whole(image, in: Room())
    }

    /// `part` of `image`, each of its pixels repeated as a block of up to `ceiling` on a
    /// side if that leaves it a reasonable size; scaled down, if it's that big a part.
    @concurrent
    private static func shot(of image: CGImage, part: CGRect, enlargedUpTo ceiling: Int) async -> Shot? {
        self.part(part, of: image, enlargedUpTo: ceiling, in: Room())
    }

    /// The whole of `image`: as it is, or scaled down to what there's `room` for.
    nonisolated private static func whole(_ image: CGImage, in room: Room) -> Shot? {
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
    nonisolated private static func part(_ part: CGRect, of image: CGImage, enlargedUpTo ceiling: Int, in room: Room) -> Shot? {
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

    nonisolated private static func shot(holding image: CGImage, in room: Room) -> Shot? {
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
    nonisolated private static func enlarged(_ image: CGImage, by factor: Int) -> CGImage? {
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

    // MARK: - Results

    /// The result of a tool call as MCP has it: text and pictures, in the order to read them.
    private struct Reply {
        enum Part {
            case text(String)
            case picture(Shot)
        }

        var parts: [Part]
        var isError = false

        static func failure(_ message: String) -> Reply {
            Reply(parts: [.text(message)], isError: true)
        }
    }

    @concurrent
    private static func encoded(_ result: Reply) async -> Data {
        let content: [[String: Any]] = result.parts.map { part in
            switch part {
            case .text(let text):
                ["type": "text", "text": text]
            case .picture(let shot):
                ["type": "image", "data": shot.data.base64EncodedString(), "mimeType": shot.mimeType]
            }
        }
        let answer: [String: Any] = ["content": content, "isError": result.isError]
        return (try? JSONSerialization.data(withJSONObject: answer, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"content":[{"type":"text","text":"FramePort couldn't put its answer together."}],"isError":true}"#.utf8)
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
