import Foundation

/// The tools FramePort's MCP server offers, as an agent is told about them. The app is what
/// carries them out (`MCPTools`, there); here is only what a model reads to decide when to
/// call one and how.
enum MCPTool {
    static let all: [[String: Any]] = [view, frame, segment]

    static var names: [String] {
        all.compactMap { $0["name"] as? String }
    }

    /// What a model is told about the server as a whole.
    static let instructions = """
        FramePort is a macOS app in which the user goes through a video frame by frame — usually a screen recording — and exports frames as PNG. This server lets you see what they have on screen there, as context for what they ask.

        When the user refers to something they're looking at in FramePort ("this frame", "the video", "what I'm seeing", "here"), or asks about a video they have open in it, call get_view before answering: it returns the frame on screen as an image, the part they've zoomed in on, and where in the video they are. What's on screen changes as they work, so call it again for a new question rather than trusting an earlier answer.

        Use get_segment when they ask about the segment they've selected, or about something that happens over a stretch of frames — an animation, a transition, a flicker: it returns those frames in one answer, in order. Use get_frame for single frames — the ones around the one on screen, two to compare — and for a closer look at part of a frame.

        These tools only look: they never change what the user sees in FramePort, and they write nothing to disk. They need FramePort to be open.
        """

    private static let view: [String: Any] = [
        "name": "get_view",
        "title": "See what's on screen in FramePort",
        "description": """
            See what the user is looking at in FramePort right now. Returns the frame on screen as an image — and, when they've zoomed in, a second image of just the part they're looking at, enlarged — together with the video's file, its size and frame rate, the number of the frame, whether it's playing, the zoom, the segment they've selected if any (get_segment returns its frames), and the videos open in other tabs.

            Call it when the user refers to what's in front of them in FramePort ("this frame", "the video", "what I'm looking at") or asks about a video they have open there: it's the context for their question. It shows the moment it's called, so call it again when they ask something new.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [String: Any](),
            "additionalProperties": false,
        ] as [String: Any],
        "annotations": annotations(title: "See what's on screen in FramePort"),
    ]

    private static let frame: [String: Any] = [
        "name": "get_frame",
        "title": "Look at a frame in FramePort",
        "description": """
            Look at any frame of a video that's open in FramePort, by its number, without changing what the user sees there. Use it to see the frames before and after the one on screen, to compare two frames, or to find where something starts or ends — and, with `region`, to look closer at part of a frame: a small part comes back enlarged, each pixel of the video as an exact square block, so that single pixels can be told apart.

            Frames are numbered as FramePort shows them: the first is 1, the last is the video's frame count. get_view says which frame the user is on and how many there are. The image is what FramePort exports for that frame as a PNG; a picture too large for a model to take in whole is scaled down, and a `region` of it then shows the detail.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "frame": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the frame, from 1 to the video's frame count. Left out: the frame that video is on.",
                ] as [String: Any],
                "tab": tab,
                "region": region("The part of the frame to return, in the video's own pixels counted from its top left corner. Left out: the whole frame."),
            ] as [String: Any],
            "additionalProperties": false,
        ] as [String: Any],
        "annotations": annotations(title: "Look at a frame in FramePort"),
    ]

    private static let segment: [String: Any] = [
        "name": "get_segment",
        "title": "Look at a segment in FramePort",
        "description": """
            See a run of consecutive frames of a video that's open in FramePort, each as an image, in order — by default the segment the user has selected there (get_view says whether there is one, and which frames it is). Call it when they ask about the segment, or about something that happens over several frames — an animation, a transition, a flicker — and to find the frame where something starts or changes. With `from` and `to` it returns any other run of frames instead. Like get_frame, it doesn't change what the user sees.

            All the frames come in one answer, so the more there are, the smaller each one is: up to 48 are returned, scaled down as needed, and of a longer run one in every so many, spread over it. To see more in them, ask for a shorter run, or for a `region` — the same part of every frame, enlarged in exact pixel blocks when it's small — or look at single frames with get_frame, which returns them at full size.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "from": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the first frame of the run; give it together with `to`. Both left out: the segment selected in FramePort.",
                ] as [String: Any],
                "to": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the last frame of the run.",
                ] as [String: Any],
                "tab": tab,
                "region": region("The part of each frame to return, in the video's own pixels counted from its top left corner. Left out: whole frames."),
            ] as [String: Any],
            "additionalProperties": false,
        ] as [String: Any],
        "annotations": annotations(title: "Look at a segment in FramePort"),
    ]

    // MARK: - What the tools have in common

    private static let tab: [String: Any] = [
        "type": "integer",
        "minimum": 1,
        "description": "Which of the open videos, by its tab number as get_view lists them. Left out: the one in front.",
    ]

    private static func region(_ description: String) -> [String: Any] {
        [
            "type": "object",
            "description": description,
            "properties": [
                "x": ["type": "integer", "minimum": 0, "description": "Left edge."] as [String: Any],
                "y": ["type": "integer", "minimum": 0, "description": "Top edge."] as [String: Any],
                "width": ["type": "integer", "minimum": 1] as [String: Any],
                "height": ["type": "integer", "minimum": 1] as [String: Any],
            ] as [String: Any],
            "required": ["x", "y", "width", "height"],
            "additionalProperties": false,
        ]
    }

    /// None of the tools changes anything, in FramePort or anywhere else.
    private static func annotations(title: String) -> [String: Any] {
        ["title": title, "readOnlyHint": true, "openWorldHint": false]
    }
}
