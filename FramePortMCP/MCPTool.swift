import Foundation

/// The tools FramePort's MCP server offers, as an agent is told about them. What carries them
/// out is the app, for a video that's open in it (`MCPTools`, there), or this program, for a
/// video file (`VideoFiles`); here is only what a model reads to decide when to call one
/// and how.
enum MCPTool {
    static let all: [[String: Any]] = [view, frame, segment, changes]

    static var names: [String] {
        all.compactMap { $0["name"] as? String }
    }

    /// What a model is told about the server as a whole.
    static let instructions = """
        FramePort is a macOS app in which the user goes through a video frame by frame — usually a screen recording — and exports frames as PNG. This server lets you see what they have on screen there, as context for what they ask, and look into any video file yourself.

        When the user refers to something they're looking at in FramePort ("this frame", "the video", "what I'm seeing", "here"), or asks about a video they have open in it, call get_view before answering: it returns the frame on screen as an image, the part they've zoomed in on, and where in the video they are. What's on screen changes as they work, so call it again for a new question rather than trusting an earlier answer.

        Use get_segment when they ask about the segment they've selected, or about something that happens over a stretch of frames — an animation, a transition, a flicker: it returns those frames in one answer, in order. Use get_frame for single frames — the ones around the one on screen, two to compare — and for a closer look at part of a frame.

        To work on a video without the user — a recording you made, or one they name by its path — give that path as `file` to get_changes, get_segment or get_frame: the file is read directly, FramePort needn't be open, and nothing shows in its window. Start with get_changes: it says, in text, over which frames the picture changes and where, so you can go straight to those frames.

        These tools only look: they never change what the user sees in FramePort, and they write nothing to disk. Without a `file`, they need FramePort to be open.
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
        "title": "Look at a frame of a video",
        "description": """
            Look at any frame of a video, by its number: a video that's open in FramePort, without changing what the user sees there, or a video `file`. Use it to see the frames before and after the one on screen, to compare two frames, or to find where something starts or ends — and, with `region`, to look closer at part of a frame: a small part comes back enlarged, each pixel of the video as an exact square block, so that single pixels can be told apart.

            Frames are numbered as FramePort shows them: the first is 1, the last is the video's frame count. get_view says which frame the user is on and how many there are. The image is what FramePort exports for that frame as a PNG; a picture too large for a model to take in whole is scaled down, and a `region` of it then shows the detail.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "frame": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the frame, from 1 to the video's frame count. Left out: the frame that video is on in FramePort — the first, for a file.",
                ] as [String: Any],
                "file": file,
                "tab": tab,
                "region": region("The part of the frame to return, in the video's own pixels counted from its top left corner. Left out: the whole frame."),
            ] as [String: Any],
            "additionalProperties": false,
        ] as [String: Any],
        "annotations": annotations(title: "Look at a frame of a video"),
    ]

    private static let segment: [String: Any] = [
        "name": "get_segment",
        "title": "Look at a run of frames of a video",
        "description": """
            See a run of consecutive frames of a video, each as an image, in order. For a video that's open in FramePort that's by default the segment the user has selected there (get_view says whether there is one, and which frames it is); for a video `file`, the whole video. Call it when they ask about the segment, or about something that happens over several frames — an animation, a transition, a flicker — and to find the frame where something starts or changes. With `from` and `to` it returns any other run of frames instead. Like get_frame, it doesn't change what the user sees.

            All the frames come in one answer, so the more there are, the smaller each one is: up to 48 are returned, scaled down as needed, and of a longer run one in every so many, spread over it. To see more in them, ask for a shorter run, or for a `region` — the same part of every frame, enlarged in exact pixel blocks when it's small — or look at single frames with get_frame, which returns them at full size. To find which frames are worth looking at in the first place, get_changes.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "from": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the first frame of the run; give it together with `to`. Both left out: the segment selected in FramePort — the whole video, for a file.",
                ] as [String: Any],
                "to": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the last frame of the run.",
                ] as [String: Any],
                "file": file,
                "tab": tab,
                "region": region("The part of each frame to return, in the video's own pixels counted from its top left corner. Left out: whole frames."),
            ] as [String: Any],
            "additionalProperties": false,
        ] as [String: Any],
        "annotations": annotations(title: "Look at a run of frames of a video"),
    ]

    private static let changes: [String: Any] = [
        "name": "get_changes",
        "title": "Find where the picture changes in a video",
        "description": """
            Find where something happens in a video without looking through its frames. Every frame is compared with what came before it, and the answer says — in text, with no images — over which stretches of frames the picture changes, where in the picture, and whether it ends up different or goes back to what it was, as something that only flashed by does. Between those stretches the picture is still. No frame is skipped, so one that differs for a single frame shows up, which a sample of frames can miss.

            Call it first on a video you haven't seen — a `file`, or one that's open in FramePort — and to find where an animation or a transition starts and ends. Then look at those frames with get_segment or get_frame. A part of the picture that never stops changing — a video playing, a spinner — hides what else happens: give a `region` to compare only the part you care about. The noise of compression isn't counted as a change; a very faint or very slow one can go unnoticed.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "from": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the first frame to compare. Left out: the first frame of the video.",
                ] as [String: Any],
                "to": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "The number of the last frame to compare. Left out: the last frame of the video.",
                ] as [String: Any],
                "file": file,
                "tab": tab,
                "region": region("The part of the picture to compare, in the video's own pixels counted from its top left corner. Left out: the whole picture."),
            ] as [String: Any],
            "additionalProperties": false,
        ] as [String: Any],
        "annotations": annotations(title: "Find where the picture changes in a video"),
    ]

    // MARK: - What the tools have in common

    private static let file: [String: Any] = [
        "type": "string",
        "description": "The path of a video file to read, instead of a video that's open in FramePort: FramePort needn't be open for it, and nothing shows in its window. The whole path, or one that starts with ~.",
    ]

    private static let tab: [String: Any] = [
        "type": "integer",
        "minimum": 1,
        "description": "Which of the videos open in FramePort, by its tab number as get_view lists them. Left out: the one in front.",
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
