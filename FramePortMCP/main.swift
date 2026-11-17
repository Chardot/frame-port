import Foundation

// FramePort's MCP server: the program an AI agent starts in order to see what's on screen in
// FramePort, or to look into a video file. It speaks MCP over standard input and output
// (`MCPServer`). A tool call about what's open in the app is passed on to the app it lives
// inside of (`AppLink`), which is the one that knows the answer; one about a file is answered
// here (`VideoFiles`), with the app's own way of reading frames.

// A client that goes away in the middle of an answer is an error to notice when writing, not
// a signal to die of.
signal(SIGPIPE, SIG_IGN)

let app = AppLink.enclosing()

if isatty(STDIN_FILENO) != 0 {
    // Started by hand in a terminal, where there's nobody to speak MCP with.
    let note = """
        frameport-mcp is FramePort's MCP server: an AI agent starts it to see what's on screen in FramePort, or to look into a video file, and talks to it in MCP over standard input and output.
        To add it to Claude Code:  claude mcp add --scope user frameport -- "\(app.executablePath)"
        Other agents take that same path as the command of a stdio MCP server.

        """
    FileHandle.standardError.write(Data(note.utf8))
}

MCPServer(app: app).run()
