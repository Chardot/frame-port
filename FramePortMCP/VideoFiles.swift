import Foundation

/// The videos this program reads itself: files an agent names by their path, where the tools
/// are otherwise about what's open in FramePort. Nothing is asked of the app for these — it
/// needn't even be open — and nothing shows in its window: an agent can work on a recording
/// with nobody at the screen.
///
/// The answers are the ones the app gives for a video in one of its tabs (`FrameAnswers`),
/// read from the file the same way, so a frame has the same number and the same pixels
/// whichever of the two was asked for it.
final class VideoFiles: @unchecked Sendable {
    private let shelf = Shelf()

    /// Whether a call is about a file, and so one for this program to answer.
    static func concerns(_ arguments: [String: Any]) -> Bool {
        FrameAnswers.given(arguments["file"]) != nil
    }

    /// Answers a call about a file, with the call's result as MCP has it. It waits for the
    /// answer where it is: every tool call has a thread of its own.
    func answer(_ name: String, arguments: [String: Any]) -> [String: Any] {
        let call = Call(name: name, arguments: arguments)
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            answer.result = await reply(to: call).result
            done.signal()
        }
        done.wait()
        return answer.result
    }

    private func reply(to call: Call) async -> Reply {
        let arguments = call.arguments
        guard call.name != "get_view" else {
            return .failure("get_view is about what's on screen in FramePort, and takes no file. To look into a file, use get_changes, get_segment or get_frame.")
        }
        guard FrameAnswers.given(arguments["tab"]) == nil else {
            return .failure("file and tab don't go together: a file is read from disk, whatever FramePort has open. Give one or the other.")
        }
        let video: Video
        do {
            video = try await shelf.video(at: try Self.url(for: arguments["file"]))
        } catch let refusal as Refusal {
            return .failure(refusal.message)
        } catch {
            return .failure("The file couldn't be opened. \(error.localizedDescription)")
        }
        let subject = Subject(video: video)
        switch call.name {
        case "get_frame": return await FrameAnswers.frame(arguments, about: subject)
        case "get_segment": return await FrameAnswers.segment(arguments, about: subject)
        case "get_changes": return await FrameAnswers.changes(arguments, about: subject)
        default: return .failure("This version of FramePort has no tool called “\(call.name)”.")
        }
    }

    // MARK: - Which file

    /// The file an agent means by what it gave as `file`.
    private static func url(for wanted: Any?) throws(Refusal) -> URL {
        guard let text = wanted as? String, case let path = text.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw Refusal(message: "file is the path of a video file, as text.")
        }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            return url.standardizedFileURL
        }
        if path == "~" || path.hasPrefix("~/") {
            return URL(fileURLWithPath: MCPChannel.homeDirectory + path.dropFirst()).standardizedFileURL
        }
        // A path that doesn't start at the top is taken from where this program was started.
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// A call as it's handed from the thread it came in on to where it's answered. Nothing
    /// in it is changed on the way.
    private struct Call: @unchecked Sendable {
        let name: String
        let arguments: [String: Any]
    }

    private final class Answer: @unchecked Sendable {
        var result: [String: Any] = [:]
    }
}

/// The files that have been opened, kept for the next call about them: finding every frame of
/// a video takes a moment, and an agent asks about the same one again and again.
private actor Shelf {
    private struct Kept {
        var video: Video
        var stamp: Stamp
        var asked: Int
    }

    /// What tells a file from another that has taken its name since: its size, and when it
    /// was last written.
    private struct Stamp: Equatable {
        var size: Int
        var written: Date
    }

    private static let most = 6

    private var kept: [String: Kept] = [:]
    /// The files that are being opened, for others asking about them meanwhile to wait on.
    private var opening: [String: (stamp: Stamp, task: Task<Video, Error>)] = [:]
    /// The last file to have been asked to open: one is opened at a time.
    private var last: Task<Video, Error>?
    private var calls = 0

    func video(at url: URL) async throws -> Video {
        let path = url.path
        let stamp = try Self.stamp(of: url)
        calls += 1
        if let known = kept[path], known.stamp == stamp {
            kept[path]?.asked = calls
            return known.video
        }

        let task: Task<Video, Error>
        if let underway = opening[path], underway.stamp == stamp {
            task = underway.task
        } else {
            let before = last
            task = Task {
                _ = await before?.result
                return try await Self.open(url)
            }
            last = task
            opening[path] = (stamp, task)
        }
        defer {
            if opening[path]?.task == task { opening[path] = nil }
        }
        let video = try await task.value

        kept[path] = Kept(video: video, stamp: stamp, asked: calls)
        if kept.count > Self.most, let oldest = kept.min(by: { $0.value.asked < $1.value.asked }) {
            kept[oldest.key] = nil
        }
        return video
    }

    /// Checks that there's a file to read at `url`, and says what tells it apart.
    private static func stamp(of url: URL) throws(Refusal) -> Stamp {
        let path = url.path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            throw Refusal(message: "There's no file at \(path). Give the whole path of the video, starting with / or ~.")
        }
        guard !isFolder.boolValue else {
            throw Refusal(message: "\(path) is a folder, not a video file.")
        }
        do {
            // Opening it is what tells whether it can be read: macOS keeps programs out of
            // some folders, and says so only then.
            try FileHandle(forReadingFrom: url).close()
        } catch {
            throw Refusal(message: "“\(url.lastPathComponent)” can't be read: \(error.localizedDescription) If it's in a folder macOS guards — Desktop, Documents, Downloads — the program this server was started from needs to be allowed in, in System Settings › Privacy & Security › Files & Folders; or the file can be copied somewhere else.")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return Stamp(size: (attributes?[.size] as? NSNumber)?.intValue ?? 0, written: attributes?[.modificationDate] as? Date ?? .distantPast)
    }

    private static func open(_ url: URL) async throws -> Video {
        do {
            return try await Video.read(url)
        } catch let error as VideoError {
            throw Refusal(message: "“\(url.lastPathComponent)” can't be used. \(error.localizedDescription)")
        } catch {
            throw Refusal(message: "“\(url.lastPathComponent)” couldn't be opened as a video. \(error.localizedDescription)")
        }
    }
}
