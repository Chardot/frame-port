import Foundation

/// The app's end of `MCPChannel`: it listens on the socket for as long as the app is open and
/// hands each question that comes in — from FramePort's MCP server, on behalf of an AI agent —
/// to whoever answers them.
final class MCPSocket: @unchecked Sendable {
    typealias Answer = @Sendable (_ question: Data) async -> Data

    private let path: String
    private let answer: Answer
    /// Everything that touches `listener` and `source` happens here.
    private let queue = DispatchQueue(label: "FramePort.MCPSocket")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    /// A question is a tool's name and a few arguments; an answer may hold pictures.
    private static let longestQuestion = 1 << 16
    private static let secondsToWait = 20

    init(path: String, answer: @escaping Answer) {
        self.path = path
        self.answer = answer
    }

    /// Starts listening. If that can't be done — or another copy of this app is already
    /// listening there — nothing is: the MCP server then finds nobody home, and says so.
    func open() {
        queue.sync {
            guard listener < 0 else { return }
            let folder = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            // A socket's file outlives an app that didn't get to quit properly. Left behind,
            // nobody answers at it, and it only has to be cleared away.
            if let other = MCPChannel.connect(to: path) {
                Darwin.close(other)
                return
            }
            unlink(path)

            guard let descriptor = MCPChannel.listen(at: path) else { return }
            // So that taking the calls that have come in never waits for one more.
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            listener = descriptor

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                self?.takeCalls()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            source.resume()
            self.source = source
        }
    }

    /// Stops listening and takes the socket away: the app is quitting.
    func close() {
        queue.sync {
            guard listener >= 0 else { return }
            listener = -1
            source?.cancel()
            source = nil
            unlink(path)
        }
    }

    private func takeCalls() {
        while listener >= 0 {
            let caller = accept(listener, nil, nil)
            guard caller >= 0 else { return }       // none left, for now
            serve(caller)
        }
    }

    private func serve(_ caller: Int32) {
        let answer = answer
        // Reading and writing wait on the other end, so they get a thread of their own.
        DispatchQueue.global(qos: .userInitiated).async {
            MCPChannel.prepare(caller, timeout: Self.secondsToWait)
            guard MCPChannel.peerIsSameUser(caller),
                  let question = MCPChannel.receive(from: caller, line: true, limit: Self.longestQuestion) else {
                Darwin.close(caller)
                return
            }
            Task {
                let reply = await answer(question)
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = MCPChannel.send(reply, over: caller)
                    Darwin.close(caller)
                }
            }
        }
    }
}
