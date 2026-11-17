import AppKit

/// What an AI agent can ask of FramePort through its MCP server, answered: what's on screen,
/// any frame of the videos that are open, or a run of them — the selected segment, to begin
/// with — and where in a video the picture changes. It only looks — nothing asked here
/// changes what the user sees, and nothing is written to disk.
///
/// The tools are described to agents by `frameport-mcp` (`MCPTool`, there), and what they
/// answer about frames is `FrameAnswers`' to say: `frameport-mcp` gives the same answers
/// itself for a video file an agent names. Here is what only the app knows — what's on
/// screen, and which of its tabs a call is about.
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
            case "get_frame": result = await answer(arguments) { await FrameAnswers.frame($0, about: $1) }
            case "get_segment": result = await answer(arguments) { await FrameAnswers.segment($0, about: $1) }
            case "get_changes": result = await answer(arguments) { await FrameAnswers.changes($0, about: $1) }
            default: result = .failure("This version of FramePort has no tool called “\(name)”.")
            }
        } else {
            result = .failure("FramePort couldn't make out the request.")
        }
        return await Reply.encoded(result)
    }

    /// What `answers` has to say to a call about the video in one of the tabs.
    private func answer(_ arguments: [String: Any], with answers: ([String: Any], Subject) async -> Reply) async -> Reply {
        let subject: Subject
        do throws(Refusal) {
            subject = try self.subject(FrameAnswers.given(arguments["tab"]))
        } catch {
            return .failure(error.message)
        }
        return await answers(arguments, subject)
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
            FrameAnswers.summary(of: video),
            "Frame \(index + 1) is at \(FrameAnswers.seconds(video.frames.seconds[index])) s.",
        ]
        if let zoom {
            let percent = Int((zoom.scale * 100).rounded())
            lines.append(visible.map { "Zoom: \(percent)% — only part of the picture is on screen: \(FrameAnswers.place($0)), in the video's pixels from its top left corner." }
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

        guard let whole = await FramePictures.shot(of: picture) else {
            lines += ["", "The frame itself couldn't be made into an image."]
            return Reply(parts: [.text(lines.joined(separator: "\n"))], isError: true)
        }
        var parts: [Reply.Part] = [
            .text(lines.joined(separator: "\n")),
            .text("Frame \(index + 1) — \(FrameAnswers.caption(forWhole: whole, of: picture))"),
            .picture(whole),
        ]
        if let visible, let zoom, let part = await FramePictures.shot(of: picture, part: visible, enlargedUpTo: Int(zoom.scale)) {
            parts += [.text("The part of it that's on screen — \(FrameAnswers.caption(forPart: part, at: visible))"), .picture(part)]
        }
        return Reply(parts: parts)
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

    // MARK: - Which video

    /// The video a call is about — the one in the tab it names or, if it names none, the one
    /// in front — and what the app is doing with it right now.
    private func subject(_ wanted: Any?) throws(Refusal) -> Subject {
        let tabs = windows.openTabs
        let number: Int
        if let wanted {
            guard let tab = FrameAnswers.whole(wanted), tabs.indices.contains(tab - 1) else {
                let open = tabs.count == 1 ? "one tab" : "\(tabs.count) tabs, numbered from 1"
                throw Refusal(message: "There's no tab \(FrameAnswers.plain(wanted)): FramePort has \(open). get_view lists them.")
            }
            number = tab
        } else {
            guard let front = windows.active, let position = tabs.firstIndex(where: { $0.model === front }) else {
                throw Refusal(message: "FramePort has no video open.")
            }
            number = position + 1
        }
        let model = tabs[number - 1].model
        guard let video = model.video else {
            throw Refusal(message: wanted == nil ? "There's no video in the tab in front of FramePort." : "Tab \(number) has no video in it.")
        }
        let isFront = model === windows.active
        return Subject(
            video: video,
            // Which tab it is, where there are others to tell it from.
            note: tabs.count > 1 ? " (tab \(number))" : "",
            onScreen: Subject.OnScreen(
                frame: model.frame,
                isFront: isFront,
                isPlaying: model.isPlaying,
                selection: model.isSelecting ? model.selection : nil,
                visiblePart: isFront ? model.visiblePart : nil
            )
        )
    }
}
