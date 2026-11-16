# FramePort

A small macOS app for going through a video frame by frame and saving frames as PNG.

It's made for screen recordings — finding the frame where an animation starts, a glitch flashes by or a layout jumps — and opens any video macOS can play. It also carries an MCP server, so an AI agent you're working with can see the frame you're looking at.

## What it does

- **Frame by frame.** Drop a video on the window and step through it with the arrow keys. The counter says which frame you're on, and that's the frame you get when you export.
- **PNG export.** Return saves the frame on screen at the video's own size. Select a segment and every frame of it is saved, in a folder of its own.
- **Zoom.** Pinch to get closer. A zoom comes to rest on a whole number of screen pixels per video pixel, so each pixel of the video is drawn as an exact square.
- **Tabs.** Drop a second video on the window and it opens in a tab next to the first.
- **MCP server.** Three read-only tools let an agent see what's on screen, look at any frame, or look at a run of frames.

## Using it

Open a video by dropping it on the window, with File › Open…, with Open With in Finder, or by dropping it on the Dock icon.

| Key | What it does |
| --- | --- |
| Space | Play or pause |
| ← → | Previous or next frame; hold to keep stepping |
| ⇧← ⇧→ | Back or forward 10 frames |
| Return | Export the frame on screen as PNG |
| S | Select a segment, with the yellow handles on the timeline (Esc to leave) |
| I, O | Start or end the segment at the frame on screen |
| ⇧⌘E | Export all frames in the segment |
| ⌘0, ⌘9 | Actual size, zoom to fit |
| ⌘+, ⌘− | Zoom in, zoom out |
| ⌃⇥, ⌃⇧⇥ | Next tab, previous tab |
| ⌘W | Close the tab in front — or, when it's the only video open, the video |

On a trackpad, a pinch zooms about the point under the pointer, a double tap with two fingers zooms in on that point and back out, and two fingers move the zoomed picture. With a mouse, a double click and a drag do the same.

### Where frames go

Frames are saved to Downloads unless you pick another folder with File › Choose Export Folder….

- A single frame is saved as `<video>_frame_0123.png`.
- A segment is saved in a folder named `<video>_frames_0100-0150`, one PNG per frame. Segments of more than 500 frames ask first.

Frame numbers start at 1, as in the window. Nothing is overwritten: a name that's taken gets `-2`, `-3` and so on.

## The MCP server

Inside the app there's a command-line program, `frameport-mcp`, that speaks MCP over stdin and stdout and asks the running app what's on screen. To give it to Claude Code:

```sh
claude mcp add --scope user frameport -- /Applications/FramePort.app/Contents/MacOS/frameport-mcp
```

Any other MCP client takes it as a stdio server with that path as its command.

| Tool | What it returns |
| --- | --- |
| `get_view` | The frame on screen as an image, and the part you've zoomed in on; the video's file, size and frame rate; the frame number, the selected segment and the videos in other tabs |
| `get_frame` | Any frame, by its number — or a region of it, enlarged in exact pixel blocks |
| `get_segment` | The frames of the selected segment, or of any other run of frames, in order; up to 48 in one answer — of a longer run, one frame in every so many |

The tools only look: they never change what you see in FramePort and they write nothing to disk. FramePort has to be open.

## Building

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml`:

```sh
xcodegen generate
xcodebuild -project FramePort.xcodeproj -scheme FramePort -configuration Release -derivedDataPath build build
```

The app is left in `build/Build/Products/Release/FramePort.app`; move it to `/Applications`.

It needs macOS 14 or later and a Swift 6.2 compiler or newer; it's built with Xcode 27. The app is signed to run locally (ad hoc) and isn't sandboxed.

`Tools/make-icon.swift` draws the app icon: `swift Tools/make-icon.swift` from the project root writes every size into the asset catalog.
