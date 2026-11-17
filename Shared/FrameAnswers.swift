import CoreGraphics
import Foundation

/// The result of a tool call as MCP has it: text and pictures, in the order to read them.
struct Reply: Sendable {
    enum Part: Sendable {
        case text(String)
        case picture(Shot)
    }

    var parts: [Part]
    var isError = false

    static func failure(_ message: String) -> Reply {
        Reply(parts: [.text(message)], isError: true)
    }

    /// The result as it goes out, to be made into JSON.
    var result: [String: Any] {
        let content: [[String: Any]] = parts.map { part in
            switch part {
            case .text(let text):
                ["type": "text", "text": text]
            case .picture(let shot):
                ["type": "image", "data": shot.data.base64EncodedString(), "mimeType": shot.mimeType]
            }
        }
        return ["content": content, "isError": isError]
    }

    @concurrent
    static func encoded(_ reply: Reply) async -> Data {
        (try? JSONSerialization.data(withJSONObject: reply.result, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"content":[{"type":"text","text":"FramePort couldn't put its answer together."}],"isError":true}"#.utf8)
    }
}

/// Why a call can't be answered, in words for the agent that made it.
struct Refusal: Error {
    var message: String
}

/// The video a call is about: one that's open in FramePort, with what the app is doing with
/// it at the time, or a file an agent named by its path, which nobody is looking at.
struct Subject: Sendable {
    var video: Video
    /// Which tab it is, for a sentence about its video; nothing where there's just the one,
    /// or for a file.
    var note = ""
    /// Nil for a file.
    var onScreen: OnScreen?

    /// What FramePort is doing with a video that's open in it.
    struct OnScreen: Sendable {
        /// The frame that tab is on.
        var frame: Int
        /// Whether it's the tab in front: the one the user is looking at.
        var isFront: Bool
        var isPlaying: Bool
        /// The segment that's selected, if one is.
        var selection: ClosedRange<Int>?
        /// The part of the picture that's on screen, if the tab is in front and zoomed in.
        var visiblePart: CGRect?
    }

    var isFile: Bool { onScreen == nil }
}

/// What the tools that return frames answer — one frame, or a run of them — whoever has the
/// video: the app, for one that's open in it, or `frameport-mcp`, for a file it reads itself.
///
/// The tools are described to agents by `frameport-mcp` (`MCPTool`, there). What that says of
/// their arguments is what's honoured here, and a frame comes back as the image its PNG holds.
enum FrameAnswers {
    typealias Limit = FramePictures.Limit

    // MARK: - Any frame

    static func frame(_ arguments: [String: Any], about subject: Subject) async -> Reply {
        let video = subject.video
        let index: Int
        let region: CGRect?
        do throws(Refusal) {
            index = try given(arguments["frame"]).map { wanted throws(Refusal) in try self.index(wanted, in: video) } ?? subject.onScreen?.frame ?? 0
            region = try given(arguments["region"]).map { wanted throws(Refusal) in try self.region(wanted, of: video.pictureSize) }
        } catch {
            return .failure(error.message)
        }
        let name = video.url.lastPathComponent

        var text = "Frame \(index + 1) of \(video.frames.count) of “\(name)”\(subject.note), at \(seconds(video.frames.seconds[index])) s."
        if let onScreen = subject.onScreen, index == onScreen.frame {
            text += onScreen.isFront ? " It's the frame on screen." : " It's the frame that tab is on."
        }

        let picture: CGImage
        do {
            picture = try await FrameExporter.image(of: index, in: video.exportSource)
        } catch {
            return .failure("Frame \(index + 1) of “\(name)” couldn't be read. \(error.localizedDescription)")
        }
        if let region {
            guard let part = await FramePictures.shot(of: picture, part: region, enlargedUpTo: Limit.enlargement) else {
                return .failure("That part of frame \(index + 1) couldn't be made into an image.")
            }
            return Reply(parts: [.text("\(text)\nOf it, \(caption(forPart: part, at: region))"), .picture(part)])
        }
        guard let whole = await FramePictures.shot(of: picture) else {
            return .failure("Frame \(index + 1) of “\(name)” couldn't be made into an image.")
        }
        return Reply(parts: [.text("\(text)\n\(caption(forWhole: whole, of: picture).capitalizedFirst)"), .picture(whole)])
    }

    // MARK: - A run of frames

    static func segment(_ arguments: [String: Any], about subject: Subject) async -> Reply {
        let video = subject.video
        let name = video.url.lastPathComponent
        let asked = (from: given(arguments["from"]), to: given(arguments["to"]))
        let run: ClosedRange<Int>
        let region: CGRect?
        do throws(Refusal) {
            switch (asked.from, asked.to) {
            case (nil, nil):
                if let onScreen = subject.onScreen {
                    guard let selection = onScreen.selection else {
                        throw Refusal(message: "No segment is selected in “\(name)”\(subject.note). The user selects one with FramePort's “Select segment” button and the yellow handles it brings up, or the I and O keys. For a run of frames of your own choosing, give from and to.")
                    }
                    run = selection
                } else {
                    run = 0...video.frames.lastIndex
                }
            case (let from?, let to?):
                let ends = (try index(from, in: video), try index(to, in: video))
                run = min(ends.0, ends.1)...max(ends.0, ends.1)
            default:
                throw Refusal(message: "from and to go together: give both for a run of frames of your own choosing, or neither for \(subject.isFile ? "the whole video" : "the segment selected in FramePort").")
            }
            region = try given(arguments["region"]).map { wanted throws(Refusal) in try self.region(wanted, of: video.pictureSize) }
        } catch {
            return .failure(error.message)
        }

        // More frames than fit in an answer: every so many of them, then.
        let (shown, step) = FramePictures.sample(of: run, atMost: Limit.pictures)
        let room = FramePictures.Room.shared(among: shown.count)
        let shots: [Int: Shot]
        do {
            shots = try await FramePictures.shots(of: shown, in: video.exportSource) { picture in
                if let region {
                    FramePictures.part(region, of: picture, enlargedUpTo: Limit.enlargement, in: room)
                } else {
                    FramePictures.whole(picture, in: room)
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
            ? "Frame \(run.lowerBound + 1) of “\(name)”\(subject.note)"
            : "Frames \(run.lowerBound + 1) to \(run.upperBound + 1) of “\(name)”\(subject.note)"
        if asked.from == nil {
            what += subject.isFile ? " — the whole video" : " — the segment selected in FramePort"
        }
        what += run.count == 1
            ? ": one frame, at \(self.seconds(seconds[run.lowerBound])) s."
            : ": \(run.count) frames, from \(self.seconds(seconds[run.lowerBound])) s to \(self.seconds(seconds[run.upperBound])) s."
        if asked.from != nil, let selected = subject.onScreen?.selection {
            what += selected.count == 1
                ? " (The segment selected in FramePort is frame \(selected.lowerBound + 1).)"
                : " (The segment selected in FramePort is frames \(selected.lowerBound + 1) to \(selected.upperBound + 1).)"
        }
        lines.append(what)
        if subject.isFile {
            // Nobody has told the agent what this video is: there's no get_view of a file.
            lines.append(facts(of: video))
        }

        // How they're shown.
        let pictureSize = video.pictureSize
        let form: String
        if let region {
            var part = "\(place(region)) of the picture"
            if sample.enlargement > 1 {
                part += ", enlarged \(sample.enlargement)×: each pixel of the video is \(block(sample.enlargement))"
            } else if sample.isScaledDown {
                part += ", scaled down to \(sample.width) × \(sample.height) px"
            } else {
                part += ", pixel for pixel"
            }
            form = part
        } else if sample.isScaledDown {
            form = "the whole picture, scaled down to \(sample.width) × \(sample.height) px (it's \(Int(pictureSize.width)) × \(Int(pictureSize.height)) px)"
        } else {
            form = "the whole picture, \(sample.width) × \(sample.height) px"
        }
        if shown.count == run.count {
            lines.append(run.count == 1 ? "It follows: \(form)." : "All \(run.count) follow, in order. Each is \(form).")
        } else {
            let every = step == 2 ? "every other frame" : "every \(ordinal(step)) frame"
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
        if region == nil, let visible = subject.onScreen?.visiblePart {
            lines.append("FramePort is zoomed in on \(place(visible)): given as the region, that returns what's on screen there, frame by frame.")
        }

        var parts: [Reply.Part] = [.text(lines.joined(separator: "\n"))]
        for index in shown {
            guard let shot = shots[index] else {
                parts.append(.text("Frame \(index + 1) couldn't be read."))
                continue
            }
            var caption = "Frame \(index + 1), at \(self.seconds(seconds[index])) s"
            if let onScreen = subject.onScreen, index == onScreen.frame, !onScreen.isPlaying {
                caption += onScreen.isFront ? " — the frame on screen" : " — the frame that tab is on"
            }
            parts += [.text(caption + ":"), .picture(shot)]
        }
        return Reply(parts: parts)
    }

    // MARK: - Where the picture changes

    static func changes(_ arguments: [String: Any], about subject: Subject, within time: Double = FrameChanges.Limit.seconds) async -> Reply {
        let video = subject.video
        let name = video.url.lastPathComponent
        let run: ClosedRange<Int>
        let region: CGRect?
        do throws(Refusal) {
            let from = try given(arguments["from"]).map { wanted throws(Refusal) in try index(wanted, in: video) } ?? 0
            let to = try given(arguments["to"]).map { wanted throws(Refusal) in try index(wanted, in: video) } ?? video.frames.lastIndex
            run = min(from, to)...max(from, to)
            region = try given(arguments["region"]).map { wanted throws(Refusal) in try self.region(wanted, of: video.pictureSize) }
        } catch {
            return .failure(error.message)
        }
        let isWhole = run == 0...video.frames.lastIndex
        let frames = run.count == 1 ? "frame \(run.lowerBound + 1)" : "frames \(run.lowerBound + 1) to \(run.upperBound + 1)"
        var lines = ["Where the picture changes in “\(name)”\(subject.note), \(frames)\(isWhole && run.count > 1 ? " — the whole video" : "")."]
        if subject.isFile {
            lines.append(facts(of: video))
        }
        if let region {
            lines.append("Only \(place(region)) of the picture was compared.")
        }
        guard run.count > 1 else {
            lines += ["", "That's one frame: there's nothing to compare it with. Give a run of at least two."]
            return Reply(parts: [.text(lines.joined(separator: "\n"))])
        }

        let report: FrameChanges.Report
        do {
            report = try await FrameChanges.find(in: video, frames: run, region: region, within: time)
        } catch {
            return .failure("\(frames.capitalizedFirst) of “\(name)” couldn't be read. \(error.localizedDescription)")
        }

        let seconds = video.frames.seconds
        let compared = report.frames
        let comparedFrames = "frames \(compared.lowerBound + 1) to \(compared.upperBound + 1)"
        let stretches = report.stretches
        let shown = stretches.prefix(Limit.stretches)
        lines.append("")
        if stretches.isEmpty {
            lines.append("Nothing changes\(report.isComplete ? "" : " in \(comparedFrames)"): every frame shows the same picture\(region == nil ? "" : " there").")
        } else {
            lines.append(stretches.count == 1
                ? "It changes over one stretch of frames, and is still before and after it:"
                : "It changes over \(stretches.count) stretches of frames, and is still in between:")
            for (position, stretch) in shown.enumerated() {
                let first = stretch.frames.lowerBound, last = stretch.frames.upperBound
                var line = "  \(position + 1). "
                if first == last {
                    // Said in full: on its own, "one frame" reads as something that came and went.
                    line += "Frame \(first + 1), at \(self.seconds(seconds[first])) s — one frame: the picture changes from frame \(first) to \(first + 1) and stays as it is then"
                } else {
                    // From the last frame of the picture as it was to the frame it settles on.
                    let lasts = seconds[last] - seconds[max(first - 1, 0)]
                    line += "Frames \(first + 1) to \(last + 1) — \(stretch.frames.count) frames, \(self.seconds(lasts)) s, from \(self.seconds(seconds[first])) s"
                }
                line += ". In \(place(stretch.place)). "
                if stretch.isOpen {
                    line += "Still changing at frame \(compared.upperBound + 1), where this stops."
                } else if stretch.returns {
                    let showed = last - first
                    line += showed <= 1
                        ? "Frame \(last + 1) is the picture as it was before: what showed was there for frame \(first + 1) only."
                        : "Frame \(last + 1) is the picture as it was before: what showed was there for \(showed) frames."
                } else {
                    line += "Afterwards \(percent(stretch.share)) of \(region == nil ? "the picture" : "that part") is different."
                }
                lines.append(line)
            }
            if stretches.count > shown.count, let next = stretches.dropFirst(shown.count).first {
                lines.append("  …and \(stretches.count - shown.count) more, from frame \(next.frames.lowerBound + 1) on: ask again with from \(next.frames.lowerBound) for those.")
            }
            lines += ["", "A stretch runs from the first frame that isn't the picture as it was to the last frame that still moves: the frame before a stretch is the picture before the change, and its last frame the picture it leaves. To see one, get_segment with from and to — and with its place as the region, for a closer look."]
            if let longest = stretches.max(by: { $0.frames.count < $1.frames.count }), longest.frames.count * 10 >= compared.count * 9, compared.count > 30 {
                lines.append("Something keeps the picture changing nearly all the way through — a video playing, an animation that repeats, a scroll. To find what else changes, give a region that leaves that part out.")
            }
        }
        if !report.isComplete {
            lines.append("That's as far as there was time for: \(comparedFrames) were compared, and \(run.upperBound - compared.upperBound) frames are left. Ask again with from \(compared.upperBound + 1) to go on.")
        }
        if report.isNoisy {
            lines.append("Even where nothing happens, the picture in this video isn't quite still — the noise of hard compression, most likely: a change fainter than that may not have been told from it.")
        }
        if let selected = subject.onScreen?.selection {
            lines.append(selected.count == 1
                ? "(The segment selected in FramePort is frame \(selected.lowerBound + 1).)"
                : "(The segment selected in FramePort is frames \(selected.lowerBound + 1) to \(selected.upperBound + 1).)")
        }
        return Reply(parts: [.text(lines.joined(separator: "\n"))])
    }

    /// "35%", "3%", "under 1%": how much of a picture.
    private static func percent(_ share: Double) -> String {
        let whole = Int((share * 100).rounded())
        return whole < 1 ? "under 1%" : "\(whole)%"
    }

    // MARK: - Words

    /// "Picture: 1170 × 2532 px, 60 fps, 55.98 s long".
    static func summary(of video: Video) -> String {
        var parts = ["\(Int(video.displaySize.width.rounded())) × \(Int(video.displaySize.height.rounded())) px"]
        if let rate = video.frameRateText {
            parts.append(rate)
        }
        parts.append("\(String(format: "%.2f", video.frames.span)) s long")
        return "Picture: " + parts.joined(separator: ", ")
    }

    /// What a video is, for an agent that has only its path: how many frames, and its picture.
    static func facts(of video: Video) -> String {
        let count = video.frames.count
        return "The video has \(count) \(count == 1 ? "frame" : "frames"). \(summary(of: video))."
    }

    static func seconds(_ time: Double) -> String {
        String(format: "%.3f", time)
    }

    /// A part of the picture, said the way `get_frame` takes one.
    static func place(_ part: CGRect) -> String {
        "x \(Int(part.minX)), y \(Int(part.minY)), width \(Int(part.width)), height \(Int(part.height))"
    }

    static func caption(forWhole shot: Shot, of picture: CGImage) -> String {
        guard shot.isScaledDown else { return "the whole picture, \(shot.width) × \(shot.height) px\(shot.lossNote):" }
        return "the whole picture, scaled down to \(shot.width) × \(shot.height) px\(shot.lossNote) (it's \(picture.width) × \(picture.height) px; get_frame with a region gives a part of it pixel for pixel):"
    }

    static func caption(forPart shot: Shot, at part: CGRect) -> String {
        var caption = place(part)
        if shot.enlargement > 1 {
            caption += ", enlarged \(shot.enlargement)×: each pixel of the video is \(block(shot.enlargement)) here"
        } else if shot.isScaledDown {
            caption += ", scaled down to \(shot.width) × \(shot.height) px"
        }
        return caption + shot.lossNote + ":"
    }

    /// "a 5 × 5 block", "an 8 × 8 block": what a pixel of the video is in an enlarged picture.
    static func block(_ factor: Int) -> String {
        "\(factor == 8 || factor == 11 ? "an" : "a") \(factor) × \(factor) block"
    }

    /// "3rd", "13th", "22nd".
    static func ordinal(_ number: Int) -> String {
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

    /// A frame of `video`, from the number an agent gave for it: the first is 1.
    static func index(_ wanted: Any, in video: Video) throws(Refusal) -> Int {
        let count = video.frames.count
        guard let frame = whole(wanted), (1...count).contains(frame) else {
            throw Refusal(message: "There's no frame \(plain(wanted)) in “\(video.url.lastPathComponent)”: it has \(count) frames, numbered 1 to \(count).")
        }
        return frame - 1
    }

    /// The part of a picture an agent asked for, kept to what there is of the picture.
    static func region(_ wanted: Any, of pictureSize: CGSize) throws(Refusal) -> CGRect {
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
    static func given(_ value: Any?) -> Any? {
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
    static func whole(_ value: Any) -> Int? {
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
    static func plain(_ value: Any) -> String {
        if let text = value as? String { return "“\(text)”" }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return number.stringValue }
            return number.boolValue ? "true" : "false"
        }
        return "like that"
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
