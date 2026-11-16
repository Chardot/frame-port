import Foundation

/// MCP as `frameport-mcp` speaks it: JSON-RPC messages over standard input and output, one
/// to a line, with nothing else ever written to standard output.
///
/// It speaks the protocol both of the ways there have been. The current one (revision
/// 2026-07-28) has no opening handshake: each request says in its `_meta` which revision it's
/// in, and `server/discover` tells a client what this server is. The earlier ones open with
/// `initialize`. Which of them a request belongs to shows in the request itself, so nothing
/// has to be remembered from one to the next.
final class MCPServer {
    /// The revision without a handshake.
    static let currentRevision = "2026-07-28"
    /// The revisions that open with `initialize`, newest first.
    static let earlierRevisions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let app: AppLink

    private let outputLock = NSLock()
    private let callsLock = NSLock()
    /// Tool calls being carried out, and those among them that the client has called off.
    private var underway: Set<String> = []
    private var calledOff: Set<String> = []

    init(app: AppLink) {
        self.app = app
    }

    /// Answers what comes in until the client closes this program's input, which is how it
    /// says it's done.
    func run() {
        while let line = readLine(strippingNewline: true) {
            receive(line)
        }
    }

    // MARK: - Messages

    private func receive(_ line: String) {
        guard line.contains(where: { !$0.isWhitespace }) else { return }
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) else {
            send(Self.failure(-32700, "Parse error: that line isn't JSON.", id: nil))
            return
        }
        if let several = message as? [Any] {
            answer(several)
        } else if let one = message as? [String: Any] {
            answer(one) { [self] reply in
                if let reply { send(reply) }
            }
        } else {
            send(Self.failure(-32600, "Invalid request: a message is a JSON object.", id: nil))
        }
    }

    /// Several messages in one line, which revision 2025-03-26 allowed: answered in one line.
    private func answer(_ several: [Any]) {
        guard !several.isEmpty else {
            send(Self.failure(-32600, "Invalid request: an empty batch.", id: nil))
            return
        }
        let pending = DispatchGroup()
        let repliesLock = NSLock()
        var replies: [[String: Any]] = []
        for message in several {
            guard let message = message as? [String: Any] else {
                repliesLock.withLock { replies.append(Self.failure(-32600, "Invalid request: a message is a JSON object.", id: nil)) }
                continue
            }
            pending.enter()
            answer(message) { reply in
                if let reply {
                    repliesLock.withLock { replies.append(reply) }
                }
                pending.leave()
            }
        }
        pending.wait()
        if !replies.isEmpty {
            send(replies)
        }
    }

    /// Deals with one message. `reply` gets the response to send — nil when there's none to
    /// send, as with a notification — and may get it later, from another thread.
    private func answer(_ message: [String: Any], reply: @escaping ([String: Any]?) -> Void) {
        guard let method = message["method"] as? String else {
            // A response to a request of ours would look like this, and this server makes
            // none. Anything else without a method isn't a message at all.
            let isResponse = message["result"] != nil || message["error"] != nil
            reply(isResponse ? nil : Self.failure(-32600, "Invalid request: no method.", id: RequestID(message["id"])))
            return
        }
        let parameters = message["params"] as? [String: Any] ?? [:]
        guard let rawID = message["id"] else {
            notified(method, parameters)
            reply(nil)
            return
        }
        guard let id = RequestID(rawID) else {
            reply(Self.failure(-32600, "Invalid request: an id is a string or a number.", id: nil))
            return
        }

        // A request of the current revision says so itself; one that doesn't is of the
        // earlier kind, from a client that began with `initialize`.
        let meta = parameters["_meta"] as? [String: Any] ?? [:]
        guard let stated = meta[Key.protocolVersion] else {
            answerEarlier(method, parameters, id: id, reply: reply)
            return
        }
        guard let revision = stated as? String else {
            reply(Self.failure(-32602, "Invalid params: \(Key.protocolVersion) is a string.", id: id))
            return
        }
        if revision == Self.currentRevision {
            answerCurrent(method, parameters, meta: meta, id: id, reply: reply)
        } else if Self.earlierRevisions.contains(revision) {
            answerEarlier(method, parameters, id: id, reply: reply)
        } else {
            reply(Self.failure(-32022, "Unsupported protocol version", id: id, data: [
                "supported": [Self.currentRevision] + Self.earlierRevisions,
                "requested": revision,
            ]))
        }
    }

    /// A request in the current revision, complete in itself.
    private func answerCurrent(_ method: String, _ parameters: [String: Any], meta: [String: Any], id: RequestID, reply: @escaping ([String: Any]?) -> Void) {
        if method == "server/discover" {
            reply(Self.success(discovery, id: id))
            return
        }
        guard meta[Key.clientCapabilities] is [String: Any] else {
            reply(Self.failure(-32602, "Invalid params: a request carries \(Key.clientCapabilities) in its _meta.", id: id))
            return
        }
        switch method {
        case "tools/list":
            reply(Self.success(completed(["tools": MCPTool.all, "ttlMs": 300_000, "cacheScope": "public"]), id: id))
        case "tools/call":
            call(parameters, id: id, reply: reply) { [self] in completed($0) }
        case "subscriptions/listen":
            // Nothing about this server changes while it runs, so there's nothing it could
            // announce: the subscription is taken, for none of what was asked, and stays
            // open and silent until the client ends it.
            send([
                "jsonrpc": "2.0",
                "method": "notifications/subscriptions/acknowledged",
                "params": ["_meta": [Key.subscriptionID: id.value], "notifications": [String: Any]()] as [String: Any],
            ] as [String: Any])
            reply(nil)
        default:
            reply(Self.failure(-32601, "Method not found: \(method)", id: id))
        }
    }

    /// A request in one of the earlier revisions.
    private func answerEarlier(_ method: String, _ parameters: [String: Any], id: RequestID, reply: @escaping ([String: Any]?) -> Void) {
        switch method {
        case "initialize":
            // The revision the client asks for if it's one of these; otherwise the newest of
            // them, for the client to take or leave.
            let asked = parameters["protocolVersion"] as? String
            let revision = asked.flatMap { Self.earlierRevisions.contains($0) ? $0 : nil } ?? Self.earlierRevisions[0]
            reply(Self.success([
                "protocolVersion": revision,
                "capabilities": Self.capabilities,
                "serverInfo": identity,
                "instructions": MCPTool.instructions,
            ], id: id))
        case "ping":
            reply(Self.success([:], id: id))
        case "tools/list":
            reply(Self.success(["tools": MCPTool.all], id: id))
        case "tools/call":
            call(parameters, id: id, reply: reply) { $0 }
        case "server/discover":
            // A client finding out which way this server speaks before saying which it does.
            reply(Self.success(discovery, id: id))
        default:
            reply(Self.failure(-32601, "Method not found: \(method)", id: id))
        }
    }

    private func notified(_ method: String, _ parameters: [String: Any]) {
        // The one notification that asks anything of this server: to drop a call it's still
        // busy with.
        guard method == "notifications/cancelled", let id = RequestID(parameters["requestId"]) else { return }
        callsLock.withLock {
            if underway.contains(id.key) {
                calledOff.insert(id.key)
            }
        }
    }

    // MARK: - Tools

    /// Has the app carry out a tool call, on a thread of its own so that other messages are
    /// answered meanwhile. `finish` dresses the result for the revision it was asked in.
    private func call(_ parameters: [String: Any], id: RequestID, reply: @escaping ([String: Any]?) -> Void, finish: @escaping ([String: Any]) -> [String: Any]) {
        guard let name = parameters["name"] as? String else {
            reply(Self.failure(-32602, "Invalid params: a tool call names its tool.", id: id))
            return
        }
        guard MCPTool.names.contains(name) else {
            reply(Self.failure(-32602, "Unknown tool: \(name)", id: id))
            return
        }
        var arguments: [String: Any] = [:]
        if let given = parameters["arguments"], !(given is NSNull) {
            guard let given = given as? [String: Any] else {
                reply(Self.failure(-32602, "Invalid params: a tool's arguments are a JSON object.", id: id))
                return
            }
            arguments = given
        }

        callsLock.withLock { _ = underway.insert(id.key) }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = app.call(name, arguments: arguments)
            let isCalledOff = callsLock.withLock {
                underway.remove(id.key)
                return calledOff.remove(id.key) != nil
            }
            // Called off meanwhile: the client isn't waiting for this any more.
            reply(isCalledOff ? nil : Self.success(finish(result), id: id))
        }
    }

    // MARK: - What this server is

    private var identity: [String: Any] {
        ["name": "frameport", "title": "FramePort", "version": app.version]
    }

    private static let capabilities: [String: Any] = ["tools": [String: Any]()]

    /// The answer to `server/discover`.
    private var discovery: [String: Any] {
        completed([
            "supportedVersions": [Self.currentRevision] + Self.earlierRevisions,
            "capabilities": Self.capabilities,
            "instructions": MCPTool.instructions,
            "ttlMs": 3_600_000,
            "cacheScope": "public",
        ])
    }

    /// A result as the current revision wants one: marked as final, and signed.
    private func completed(_ result: [String: Any]) -> [String: Any] {
        var result = result
        var meta = result["_meta"] as? [String: Any] ?? [:]
        meta[Key.serverInfo] = identity
        result["_meta"] = meta
        result["resultType"] = "complete"
        return result
    }

    private enum Key {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
        static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
    }

    // MARK: - Responses

    private static func success(_ result: [String: Any], id: RequestID) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id.value, "result": result]
    }

    private static func failure(_ code: Int, _ message: String, id: RequestID?, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data {
            error["data"] = data
        }
        var response: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id {
            response["id"] = id.value
        }
        return response
    }

    /// Writes a message — or several, as one — to standard output as a line of its own.
    private func send(_ message: Any) {
        guard JSONSerialization.isValidJSONObject(message),
              var line = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        outputLock.withLock {
            do {
                try FileHandle.standardOutput.write(contentsOf: line)
            } catch {
                exit(0)         // nobody's reading: the client has gone
            }
        }
    }
}

/// The id of a request: a string or a number, to be handed back as it came.
struct RequestID {
    let value: Any
    /// Tells one id from another, and the string "1" from the number 1.
    let key: String

    init?(_ raw: Any?) {
        switch raw {
        case .some(let text as String):
            value = text
            key = "s:\(text)"
        case .some(let number as NSNumber) where CFGetTypeID(number) != CFBooleanGetTypeID():
            value = number
            key = "n:\(number.stringValue)"
        default:
            return nil
        }
    }
}
