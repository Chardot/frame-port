import Foundation

/// The FramePort this program lives inside of, and the way to ask it things.
///
/// `frameport-mcp` sits next to the app's own executable, so the app is found by looking
/// around: no path or name is assumed, and a second copy of the app gets asked by the
/// `frameport-mcp` inside that copy.
struct AppLink {
    /// Nil if this program isn't inside an app at all.
    let bundleIdentifier: String?
    /// The app's version.
    let version: String
    /// Where this program is.
    let executablePath: String

    /// An answer may hold a couple of full-size pictures, or the many of a segment.
    private static let longestAnswer = 64 << 20
    /// Reading a frame from the file and making a PNG of it takes a moment; not this long.
    private static let secondsToWait = 30

    static func enclosing() -> AppLink {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        // FramePort.app/Contents/MacOS/frameport-mcp
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        let isApp = info?["CFBundlePackageType"] as? String == "APPL"
        return AppLink(
            bundleIdentifier: isApp ? info?["CFBundleIdentifier"] as? String : nil,
            version: info?["CFBundleShortVersionString"] as? String ?? "1.0",
            executablePath: executable.path
        )
    }

    /// Has the app carry out a tool call. What comes back is the call's result as MCP has
    /// it — also when the app can't be asked: that's then an error the model gets to read.
    func call(_ name: String, arguments: [String: Any]) -> [String: Any] {
        guard let bundleIdentifier else {
            return Self.failure("To see what's open in FramePort, frameport-mcp has to be the one inside FramePort.app, and this copy is at \(executablePath). It can still read a video file: give its path as file.")
        }
        guard let app = Self.connect(to: MCPChannel.socketPath(forBundle: bundleIdentifier)) else {
            return Self.failure("FramePort isn't open. Ask the user to open it, with the video they mean, and try again — or, if it's a video file you have the path of, give that as file: reading a file doesn't take FramePort.")
        }
        defer { close(app) }
        MCPChannel.prepare(app, timeout: Self.secondsToWait)

        let question: [String: Any] = ["name": name, "arguments": arguments]
        guard var line = try? JSONSerialization.data(withJSONObject: question) else {
            return Self.failure("The arguments of this call couldn't be passed on to FramePort.")
        }
        line.append(0x0A)
        guard MCPChannel.send(line, over: app),
              let answer = MCPChannel.receive(from: app, line: false, limit: Self.longestAnswer),
              let result = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              result["content"] is [Any] else {
            return Self.failure("FramePort is open but didn't answer. If it stays that way, quitting and reopening FramePort should fix it.")
        }
        return result
    }

    /// A socket connected to the app, if it's open. From outside, an app that's taking as
    /// many calls as it can hold looks the same as a socket that an app which didn't quit
    /// properly left behind: both refuse. So a refusal is tried again for a moment before
    /// it's taken to mean that nobody's there.
    private static func connect(to path: String) -> Int32? {
        for _ in 0..<16 {
            switch MCPChannel.reach(path) {
            case .connected(let descriptor): return descriptor
            case .absent: return nil
            case .refused: usleep(20_000)
            }
        }
        return nil
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}
