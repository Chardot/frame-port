import SwiftUI

@main
struct FramePortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The video windows are made by `VideoWindows`, which decides where each video opens
        // and gives a window its tabs. This scene is only there for SwiftUI to hang the menus
        // on: its window is never shown, and the menu item that would show it is taken out.
        Settings {
            EmptyView()
        }
        .commands {
            AppCommands(windows: appDelegate.windows)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let windows = VideoWindows()
    private var keyMonitor: Any?
    private var mcpSocket: MCPSocket?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The app has tabs of its own (see `VideoWindow`); the system's aren't used, and
        // this takes its tab commands out of the menus.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keyboard control lives in a local event monitor rather than in focus-dependent
        // handlers, so Space, the arrows and Return work no matter what was clicked last.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKeyDown(event) else { return event }
            return nil
        }
        // Unless a video the app was launched with has already brought one up.
        windows.showFirstWindowIfNeeded()
        listenForMCP()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mcpSocket?.close()
    }

    /// Lets FramePort's MCP server — and through it, an AI agent the user is working with —
    /// see what's on screen here: see `MCPTools` for what it can ask.
    private func listenForMCP() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let tools = MCPTools(windows: windows)
        let socket = MCPSocket(path: MCPChannel.socketPath(forBundle: identifier)) { question in
            await tools.answer(question)
        }
        socket.open()
        mcpSocket = socket
    }

    /// Videos opened from Finder ("Open With") or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        windows.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Returns true when the key was handled and shouldn't travel any further.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Only a video window: sheets, alerts and open panels keep their own keys.
        guard let window = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              window.sheetParent == nil,
              window.attachedSheet == nil,
              !(window is NSPanel),
              !(window.firstResponder is NSText),
              let model = windows.model(in: window),
              model.video != nil else { return false }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let plain = modifiers.isEmpty
        let step = modifiers == .shift ? 10 : 1

        switch event.keyCode {
        case KeyCode.space where plain:
            if !event.isARepeat { model.togglePlayback() }
        case KeyCode.leftArrow where plain || modifiers == .shift:
            model.step(by: -step)                       // holding the key keeps stepping
        case KeyCode.rightArrow where plain || modifiers == .shift:
            model.step(by: step)
        case KeyCode.return where plain, KeyCode.keypadEnter where plain:
            if !event.isARepeat { model.exportCurrentFrame() }
        case KeyCode.escape where plain && model.isSelecting:
            model.stopSelecting()
        case _ where modifiers == .command && event.charactersIgnoringModifiers == "=":
            // Zoom In is ⌘+ in the menu; on keyboards where the plus sign takes Shift, this
            // is the key people actually press for it.
            model.zoomIn()
        default:
            // Letters are matched by character so they follow the keyboard layout.
            guard plain, !event.isARepeat else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": model.toggleSelecting()
            case "i": model.markSelectionStart()
            case "o": model.markSelectionEnd()
            default: return false
            }
        }
        return true
    }

    private enum KeyCode {
        static let space: UInt16 = 49
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let `return`: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
    }
}

/// Menu bar commands, which act on the video in front. The single-key shortcuts shown here
/// are the same ones the key monitor handles; listing them in the menus keeps them discoverable.
struct AppCommands: Commands {
    let windows: VideoWindows

    private var model: PlayerModel? { windows.active }

    var body: some Commands {
        // The "Settings…" item of the scene the menus hang from. (What's left is its
        // separator next to the one that follows it, which the system draws as one.)
        CommandGroup(replacing: .appSettings) {}

        CommandGroup(replacing: .newItem) {
            Button("Open…") { windows.presentOpenPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Export Frame as PNG") { model?.exportCurrentFrame() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Export All Frames in Segment") { model?.exportSegment() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Choose Export Folder…") { model?.chooseExportFolder() }
            Button("Use Downloads as Export Folder") { model?.resetExportFolder() }
            Button("Show Export Folder in Finder") { model?.revealExportFolder() }
        }

        CommandMenu("Playback") {
            Button("Play/Pause") { model?.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
            Divider()
            Button("Next Frame") { model?.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous Frame") { model?.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward 10 Frames") { model?.step(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("Back 10 Frames") { model?.step(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Divider()
            Button("Select Segment") { model?.toggleSelecting() }
                .keyboardShortcut("s", modifiers: [])
            Button("Start Segment at Current Frame") { model?.markSelectionStart() }
                .keyboardShortcut("i", modifiers: [])
            Button("End Segment at Current Frame") { model?.markSelectionEnd() }
                .keyboardShortcut("o", modifiers: [])
        }

        // In the View menu, with the names and keys they have in Preview.
        CommandGroup(before: .toolbar) {
            Button("Actual Size") { model?.zoomToActualSize() }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { model?.zoomToFit() }
                .keyboardShortcut("9")
            Button("Zoom In") { model?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut("-")
            Divider()
        }

        // Where the system puts the same commands for its own window tabs.
        CommandGroup(after: .windowList) {
            Button("Show Previous Tab") { windows.showTab(offset: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Show Next Tab") { windows.showTab(offset: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Move Tab to New Window") { windows.moveTabToNewWindow() }
            Button("Merge All Windows") { windows.mergeAllWindows() }
        }

        CommandGroup(replacing: .help) {}
    }
}
