import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One open video: its model, and the view that shows it and its controls. A window holds
/// one or more of these as tabs; only the tab that's showing has its view in the window.
@MainActor
final class VideoTab: Identifiable {
    let model = PlayerModel()
    let view: NSView

    init(openVideos: OpenVideosAction) {
        let content = NSHostingView(
            rootView: ContentView()
                .environment(model)
                .environment(\.openVideos, openVideos)
                .preferredColorScheme(.dark)
        )
        // The window's size and title are the window's business, not its content's.
        content.sizingOptions = []
        content.sceneBridgingOptions = []
        content.autoresizingMask = [.width, .height]
        view = content
    }
}

/// The tabs of a window, in order, and the one that's showing: what its tab strip draws.
@MainActor
@Observable
final class TabList {
    fileprivate(set) var tabs: [VideoTab] = []
    fileprivate(set) var selected: VideoTab?
}

/// A window of the app: the video of the tab that's showing and, once it holds more than
/// one video, a strip of tabs under the title bar.
///
/// The windows are AppKit's rather than a SwiftUI scene's, so that the app decides where a
/// video opens. And the tabs are the app's own rather than the system's window tabs, which
/// can only share out the whole width of the window between them.
@MainActor
final class VideoWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let list = TabList()

    /// The window has become the one the user is working in.
    var didBecomeMain: () -> Void = {}
    /// The window has been moved or resized.
    var didChangeFrame: () -> Void = {}
    var willClose: () -> Void = {}
    /// The user asked for a tab to have a window of its own.
    var moveToNewWindow: (VideoTab) -> Void = { _ in }
    /// An empty tab for the window to go back to when its only video is closed with ⌘W —
    /// or nil, if the window is to close with its video as it always did.
    var emptyTab: () -> VideoTab? = { nil }

    /// The window is on its way into or out of full screen.
    private(set) var isChangingFullScreen = false

    private let content = NSView()
    private let strip = NSTitlebarAccessoryViewController()

    private static let defaultSize = CGSize(width: 1040, height: 720)

    init(tab: VideoTab) {
        let window = TabbedWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        self.window = window
        super.init()

        window.isReleasedWhenClosed = false
        // Nothing for the system to restore: the app puts its window back itself.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentMinSize = ContentView.minimumSize
        window.center()
        window.contentView = content
        window.delegate = self
        window.closeInstead = { [weak self] in
            self?.closeLessThanTheWindow() ?? false
        }

        // Where the system would put its own tab bar: under the title bar, as part of it.
        // (It goes into the window when there's a second tab: see `showOrHideStrip`.)
        strip.layoutAttribute = .bottom
        strip.fullScreenMinHeight = TabStrip.height
        strip.view = makeStrip()

        insert(tab)
        followTitle()
    }

    private func makeStrip() -> NSView {
        let tabs = NSHostingView(rootView: TabStrip(
            list: list,
            select: { [weak self] in self?.select($0) },
            close: { [weak self] in self?.close($0) },
            closeOthers: { [weak self] in self?.closeAll(but: $0) },
            moveToNewWindow: { [weak self] in self?.moveToNewWindow($0) }
        ))
        // As wide as the tabs are, and narrower when the window is: the tabs then give way.
        tabs.sizingOptions = [.intrinsicContentSize]
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.setContentHuggingPriority(.required, for: .horizontal)
        tabs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let background = StripBackground(frame: CGRect(x: 0, y: 0, width: Self.defaultSize.width, height: TabStrip.height))
        background.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: background.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor),
        ])
        return background
    }

    /// Keeps the title bar naming the video that's showing: the file, then its size and
    /// frame rate.
    private func followTitle() {
        withObservationTracking {
            let video = list.selected?.model.video
            window.title = video?.url.lastPathComponent ?? "FramePort"
            window.subtitle = video?.summary ?? ""
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followTitle()
            }
        }
    }

    // MARK: - Tabs

    /// Adds a tab after `neighbour` (at the end, without one). It isn't shown unless it's
    /// the window's first.
    func insert(_ tab: VideoTab, after neighbour: VideoTab? = nil) {
        let index = neighbour.flatMap { neighbour in list.tabs.firstIndex { $0 === neighbour } }.map { $0 + 1 }
        list.tabs.insert(tab, at: index ?? list.tabs.count)
        if list.selected == nil {
            select(tab)
        } else {
            tab.model.pause()                   // it comes in behind the tab that's showing
        }
        showOrHideStrip()
    }

    /// Shows a tab in place of the one that's showing. It doesn't while a sheet is up: that
    /// belongs to the tab it came from.
    @discardableResult
    func select(_ tab: VideoTab) -> Bool {
        guard list.tabs.contains(where: { $0 === tab }), window.attachedSheet == nil else { return false }
        guard tab !== list.selected else { return true }
        if let previous = list.selected {
            previous.model.pause()              // nothing keeps playing where it can't be seen
            previous.view.removeFromSuperview()
        }
        list.selected = tab
        tab.view.frame = content.bounds
        content.addSubview(tab.view)
        return true
    }

    /// Shows the tab before or after the one that's showing, going round at the ends.
    func selectTab(offset: Int) {
        guard let selected = list.selected, let index = list.tabs.firstIndex(where: { $0 === selected }) else { return }
        let count = list.tabs.count
        select(list.tabs[((index + offset) % count + count) % count])
    }

    /// Closes a tab and its video; with it the window, if it's the only one.
    func close(_ tab: VideoTab) {
        guard list.tabs.contains(where: { $0 === tab }), window.attachedSheet == nil else { return }
        guard list.tabs.count > 1 else {
            window.close()
            return
        }
        remove(tab)
        tab.model.shutDown()
    }

    func closeAll(but tab: VideoTab) {
        for other in list.tabs where other !== tab {
            close(other)
        }
    }

    /// Takes a tab out of the window with its video still open: it's on its way to another
    /// window. This can leave the window with no tabs, for whoever asked to close it.
    func detach(_ tab: VideoTab) {
        remove(tab)
    }

    private func remove(_ tab: VideoTab) {
        guard let index = list.tabs.firstIndex(where: { $0 === tab }) else { return }
        list.tabs.remove(at: index)
        if list.selected === tab {
            tab.view.removeFromSuperview()
            list.selected = nil
            if !list.tabs.isEmpty {
                select(list.tabs[min(index, list.tabs.count - 1)])
            }
        }
        showOrHideStrip()
    }

    /// The strip is part of the window only while there's more than one tab to show in it.
    private func showOrHideStrip() {
        let index = window.titlebarAccessoryViewControllers.firstIndex(of: strip)
        if list.tabs.count > 1, index == nil {
            window.addTitlebarAccessoryViewController(strip)
        } else if list.tabs.count < 2, let index {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    /// Puts `fresh` where `tab` is, and closes `tab`'s video.
    func replace(_ tab: VideoTab, with fresh: VideoTab) {
        guard let index = list.tabs.firstIndex(where: { $0 === tab }) else { return }
        list.tabs[index] = fresh
        if list.selected === tab {
            tab.view.removeFromSuperview()
            list.selected = fresh
            fresh.view.frame = content.bounds
            content.addSubview(fresh.view)
        } else {
            fresh.model.pause()                 // like any tab that isn't the one showing
        }
        tab.model.shutDown()
    }

    /// What the Close menu item (⌘W) closes when it isn't the window: the tab in front, if
    /// there are others; or the video of the only tab, which leaves the window as it is
    /// before a video is opened — where `emptyTab` has a tab to leave in it. False, and
    /// nothing done, when it's the window that should close: an empty one, for instance.
    private func closeLessThanTheWindow() -> Bool {
        guard window.attachedSheet == nil, let tab = list.selected else { return false }
        if list.tabs.count > 1 {
            close(tab)
            return true
        }
        guard !tab.model.isEmpty, let fresh = emptyTab() else { return false }
        replace(tab, with: fresh)
        return true
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        didBecomeMain()
    }

    func windowDidMove(_ notification: Notification) {
        didChangeFrame()
    }

    func windowDidResize(_ notification: Notification) {
        // While an edge is being dragged this comes many times over; the end of it is enough.
        if !window.inLiveResize {
            didChangeFrame()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        didChangeFrame()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
    }

    func windowWillClose(_ notification: Notification) {
        for tab in list.tabs {
            tab.model.shutDown()
        }
        willClose()
    }
}

/// The window itself, which tells the Close menu item (⌘W) from its own close button: the
/// first closes the tab in front — or just its video, if that's all there is open in the
/// app —, the second the window and every tab in it.
private final class TabbedWindow: NSWindow {
    /// Closes what the Close menu item is for, short of the window, and returns true — or
    /// returns false if there's nothing of the kind, and the window should close.
    var closeInstead: () -> Bool = { false }

    override func performClose(_ sender: Any?) {
        if let item = sender as? NSMenuItem, item.action == #selector(performClose(_:)), closeInstead() {
            return
        }
        super.performClose(sender)
    }
}

/// What's behind the tabs. Dragging it moves the window, like the rest of the title bar.
private final class StripBackground: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The app's windows and the rule for where a video opens: in the tab it's meant for if
/// that one is empty, otherwise in a new tab next to it.
@MainActor
final class VideoWindows {
    private typealias Place = (window: VideoWindow, tab: VideoTab)

    private var windows: [VideoWindow] = []
    private weak var lastMain: VideoWindow?

    /// The name the window's position is saved under: the one this app has always used.
    private static let frameName = "main"

    // MARK: - The video in front

    /// The video the menus act on: the one showing in the window in front.
    var active: PlayerModel? { front?.list.selected?.model }

    /// The video showing in a window, if it's one of the app's.
    func model(in window: NSWindow) -> PlayerModel? {
        windows.first { $0.window === window }?.list.selected?.model
    }

    /// The video of every tab that's open, with the number of its window: window after window
    /// in the order they were opened, and tab after tab as the strip has them.
    var openTabs: [(model: PlayerModel, window: Int)] {
        windows.enumerated().flatMap { index, window in
            window.list.tabs.map { (model: $0.model, window: index + 1) }
        }
    }

    /// In the background the app has no main window: then it's the last one it had.
    private var front: VideoWindow? {
        windows.first { $0.window === NSApp.mainWindow } ?? lastMain ?? windows.last
    }

    private var frontPlace: Place? {
        guard let front, let tab = front.list.selected else { return nil }
        return (front, tab)
    }

    private func place(of model: PlayerModel?) -> Place? {
        guard let model else { return nil }
        for window in windows {
            if let tab = window.list.tabs.first(where: { $0.model === model }) {
                return (window, tab)
            }
        }
        return nil
    }

    // MARK: - Opening

    /// Shows an empty window if there's no window yet: the app has just started.
    func showFirstWindowIfNeeded() {
        if windows.isEmpty {
            showFirstWindow()
        }
    }

    /// Opens videos on behalf of the tab showing `source` (the one in front, if none is
    /// given). The first takes that tab if it's empty; every other gets a new tab next to
    /// it, in the order given.
    func open(_ urls: [URL], from source: PlayerModel? = nil) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        let start = place(of: source) ?? frontPlace ?? showFirstWindow()

        Task {
            // Where the next video goes: into this tab if it's empty, into a new one next to
            // it if it isn't.
            var spot = start
            var revealed = false
            for url in files {
                // The tab, or its whole window, may have been closed while the last file was
                // being read.
                guard let current = stillOpen(spot) else { return }
                spot = current
                if spot.tab.model.isEmpty {
                    spot.tab.model.open(url)
                    revealed = true             // that tab is the one in front already
                    continue
                }
                guard let video = await spot.tab.model.read(forNewTab: url) else { continue }
                // Made ready before it's shown: with its first frame drawn, the new tab comes
                // up as a picture rather than as black that fills in a moment later.
                let tab = makeTab()
                tab.model.install(video)
                await tab.model.firstFrame()
                guard let home = stillOpen(spot) else {
                    tab.model.shutDown()
                    return
                }
                if home.tab.model.isEmpty {
                    // The video it was to go next to has been closed meanwhile, and its
                    // tab left empty: that's the tab it takes, then, as it would have had
                    // the tab been empty from the start.
                    let isShowing = home.window.list.selected === home.tab
                    home.window.replace(home.tab, with: tab)
                    revealed = revealed || isShowing
                } else {
                    home.window.insert(tab, after: home.tab)
                    // The first of them is the one to look at; the rest wait in their tabs.
                    if !revealed {
                        home.window.select(tab)
                        revealed = true
                    }
                }
                spot = (home.window, tab)
            }
        }
    }

    /// `place` if it's still there; the tab showing in its window if only the tab has gone;
    /// the tab in front if the window has; nothing if no window is left.
    private func stillOpen(_ place: Place) -> Place? {
        guard windows.contains(where: { $0 === place.window }) else { return frontPlace }
        if place.window.list.tabs.contains(where: { $0 === place.tab }) {
            return place
        }
        return place.window.list.selected.map { (place.window, $0) }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a video to open"

        let source = frontPlace
        let opened: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                self?.open(panel.urls, from: source?.tab.model)
            }
        }
        if let window = source?.window.window {
            panel.beginSheetModal(for: window, completionHandler: opened)
        } else {
            panel.begin(completionHandler: opened)
        }
    }

    // MARK: - Tabs

    /// Shows the tab before or after the one in front.
    func showTab(offset: Int) {
        front?.selectTab(offset: offset)
    }

    /// Gives the tab in front a window of its own.
    func moveTabToNewWindow() {
        guard let place = frontPlace else { return }
        moveToNewWindow(place.tab, from: place.window)
    }

    private func moveToNewWindow(_ tab: VideoTab, from window: VideoWindow) {
        guard window.list.tabs.count > 1, window.window.attachedSheet == nil else { return }
        window.detach(tab)
        let moved = makeWindow(with: tab)
        // The same size, a little down and to the right, as a new window of a document is.
        let frame = window.window.frame
        moved.window.setFrame(frame.offsetBy(dx: 28, dy: -28), display: false)
        moved.window.makeKeyAndOrderFront(nil)
    }

    /// Brings the tabs of every other window into the one in front.
    func mergeAllWindows() {
        guard let front else { return }
        for other in windows where other !== front && other.window.attachedSheet == nil {
            for tab in other.list.tabs {
                other.detach(tab)
                front.insert(tab)
            }
            other.window.close()
        }
    }

    // MARK: - Windows

    private func makeTab() -> VideoTab {
        VideoTab(openVideos: OpenVideosAction { [weak self] urls, model in
            self?.open(urls, from: model)
        })
    }

    private func makeWindow(with tab: VideoTab) -> VideoWindow {
        let window = VideoWindow(tab: tab)
        window.didBecomeMain = { [weak self, weak window] in
            guard let self, let window else { return }
            self.lastMain = window
        }
        window.didChangeFrame = { [weak self, weak window] in
            guard let self, let window else { return }
            self.rememberFrame(of: window)
        }
        window.willClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.closed(window)
        }
        window.moveToNewWindow = { [weak self, weak window] tab in
            guard let self, let window else { return }
            self.moveToNewWindow(tab, from: window)
        }
        window.emptyTab = { [weak self] in
            // Closing the only video that's open doesn't close the app's last window, and
            // the app with it: the window stays, empty, for the next video. A window that
            // isn't the last has no such reason to stay.
            guard let self, self.windows.count == 1 else { return nil }
            return self.makeTab()
        }
        windows.append(window)
        return window
    }

    @discardableResult
    private func showFirstWindow() -> Place {
        let tab = makeTab()
        let window = makeWindow(with: tab)
        // Back where the window was the last time, if that's known.
        if !(Self.reopensInPlace && putBackExactly(window.window)) {
            window.window.setFrameUsingName(Self.frameName)
        }
        window.window.makeKeyAndOrderFront(nil)
        return (window, tab)
    }

    /// Whether the window comes back exactly where it was left. It does, unless the
    /// `reopenWindowInPlace` setting says otherwise (`-reopenWindowInPlace NO` on the command
    /// line does, for one launch). Left to itself, the system puts a window it restores on
    /// whichever display is in use at the time, which may not be the one it was left on.
    private static var reopensInPlace: Bool {
        let key = "reopenWindowInPlace"
        return UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
    }

    /// Puts a window at the saved position as it is, without the system's say on which
    /// display it goes to. Only if the display it was saved on is still there, in the same
    /// place; false, and nothing done, otherwise.
    private func putBackExactly(_ window: NSWindow) -> Bool {
        // "x y width height" of the window, then of the display it was on (less its menu bar).
        guard let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") else { return false }
        let numbers = saved.split(separator: " ").prefix(8).compactMap { Double($0) }
        guard numbers.count == 8 else { return false }
        let frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        let display = CGRect(x: numbers[4], y: numbers[5], width: numbers[6], height: numbers[7])
        let isStillThere = NSScreen.screens.contains { screen in
            screen.frame.origin == display.origin && screen.frame.width == display.width
                && (0...60).contains(screen.frame.height - display.height)
        }
        guard isStillThere, frame.width >= 1, frame.height >= 1 else { return false }
        window.setFrame(frame, display: false)
        return true
    }

    /// Remembers where `window` is, for the next launch: the window the user moved or resized
    /// last is where the app comes back.
    ///
    /// AppKit can do this by itself (`setFrameAutosaveName`), but only for one window per
    /// name, and giving the name to a window that's already up moves it to where the saved
    /// frame says — to another display, even. Saving by hand never moves anything.
    private func rememberFrame(of window: VideoWindow) {
        let moved = window.window
        // Not a window that isn't up yet (which is how the system's own choice of display
        // at launch stays out of it), nor one that's full screen.
        guard moved.isVisible, !moved.styleMask.contains(.fullScreen), !window.isChangingFullScreen else { return }
        moved.saveFrame(usingName: Self.frameName)
    }

    private func closed(_ window: VideoWindow) {
        windows.removeAll { $0 === window }
        // The window is still in the middle of closing: it's let go of once that's over.
        Task { @MainActor in
            _ = window
        }
    }
}
