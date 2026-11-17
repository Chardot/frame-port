import Foundation

/// The way between FramePort and its MCP server — `frameport-mcp`, the small program inside
/// the app that an AI agent starts in order to see what's on screen in it. The app listens
/// on a socket in the user's own Library for as long as it's open, and the server calls there.
///
/// One question and one answer per connection. The question is a line of JSON: the name of a
/// tool and its arguments, as MCP's `tools/call` carries them. The answer is the result of
/// that call as MCP has it (`content`, `isError`), after which the app hangs up.
enum MCPChannel {
    /// Where the app with this bundle identifier listens. The identifier is part of the name
    /// so that each copy of the app has a socket of its own, and the `frameport-mcp` inside a
    /// copy finds that one.
    static func socketPath(forBundle identifier: String) -> String {
        "\(homeDirectory)/Library/Application Support/\(identifier)/mcp.sock"
    }

    /// The user's home as their account has it. Not `HOME`: an agent may start its tools with
    /// one of its own.
    static var homeDirectory: String {
        if let record = getpwuid(getuid()), let home = record.pointee.pw_dir {
            return String(cString: home)
        }
        return NSHomeDirectory()
    }

    // MARK: - Sockets

    /// A socket bound to `path` and listening — nil if that can't be (the path may be longer
    /// than a socket's address holds, for one). Only the user's own programs can reach it.
    static func listen(at path: String) -> Int32? {
        guard var address = address(for: path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // As many callers may wait to be taken as the system lets a socket hold: an agent
        // asks for dozens of frames at once.
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            close(descriptor)
            return nil
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return descriptor
    }

    /// A socket connected to whoever listens at `path` — nil if nobody does.
    static func connect(to path: String) -> Int32? {
        if case .connected(let descriptor) = reach(path) { return descriptor }
        return nil
    }

    /// What came of trying to connect to a socket.
    enum Reach {
        case connected(Int32)
        /// There's a socket there and it didn't take the call: nobody's listening at it any
        /// more — or whoever is has, right now, as many callers waiting as it can hold.
        case refused
        /// There's no socket there, or no way to it.
        case absent
    }

    static func reach(_ path: String) -> Reach {
        guard var address = address(for: path) else { return .absent }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .absent }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let wasRefused = errno == ECONNREFUSED
            close(descriptor)
            return wasRefused ? .refused : .absent
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return .connected(descriptor)
    }

    private static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        // One byte is left for the zero that ends the path.
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Makes a connected socket ready to talk over: reads and writes block, but not for longer
    /// than `seconds`, and a peer that has gone away shows as an error rather than as the
    /// signal that would end the whole program.
    static func prepare(_ descriptor: Int32, timeout seconds: Int) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK != 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Whether the program at the other end of a socket belongs to the same user as this one.
    static func peerIsSameUser(_ descriptor: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(descriptor, &user, &group) == 0 && user == getuid()
    }

    // MARK: - Talking

    /// Sends all of `data`. False if the other end stopped taking it.
    static func send(_ data: Data, over descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var sent = 0
            while sent < buffer.count {
                let count = write(descriptor, base + sent, buffer.count - sent)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// What the other end sends: its first line, without the line break (`line`), or
    /// everything until it hangs up. Nil if it sends more than `limit` bytes, breaks off, or
    /// takes longer than the socket waits.
    static func receive(from descriptor: Int32, line: Bool, limit: Int) -> Data? {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 {
                // The other end is done. That only makes an answer if it wasn't owed a line break.
                return line ? nil : received
            }
            if line, let end = chunk[..<count].firstIndex(of: 0x0A) {
                received.append(contentsOf: chunk[..<end])
                return received.count <= limit ? received : nil
            }
            received.append(contentsOf: chunk[..<count])
            guard received.count <= limit else { return nil }
        }
    }
}
