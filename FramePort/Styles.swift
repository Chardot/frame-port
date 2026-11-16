import SwiftUI

enum Palette {
    /// The yellow of the trim handles.
    static let banana = Color(red: 1.0, green: 0.80, blue: 0.10)
    /// Text and marks drawn on top of the yellow.
    static let bananaInk = Color(red: 0.20, green: 0.14, blue: 0.0)
    static let bar = Color(white: 0.105)
    static let stripPlaceholder = Color(white: 0.17)
}

/// The step and play buttons: quiet icons that light up under the pointer.
struct TransportButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, isPrimary: isPrimary)
    }

    private struct Content: View {
        let configuration: Configuration
        let isPrimary: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: isPrimary ? 16 : 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.28))
                .frame(width: isPrimary ? 48 : 36, height: 30)
                .background(.white.opacity(fillOpacity), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var fillOpacity: Double {
            guard isEnabled else { return isPrimary ? 0.05 : 0 }
            if configuration.isPressed { return 0.26 }
            if isHovered { return isPrimary ? 0.19 : 0.12 }
            return isPrimary ? 0.11 : 0
        }
    }
}

/// Capsule buttons with a text label: the segment toggle and the export button.
struct PillButtonStyle: ButtonStyle {
    enum Tone {
        /// The main action.
        case accent
        /// The main action while a segment is selected.
        case banana
        /// A toggle that's switched on.
        case bananaTint
        /// A secondary action.
        case quiet
    }

    var tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, tone: tone)
    }

    private struct Content: View {
        let configuration: Configuration
        let tone: Tone
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(background, in: Capsule())
                .brightness(configuration.isPressed ? -0.07 : (isHovered && isEnabled ? 0.05 : 0))
                .opacity(isEnabled ? 1 : 0.38)
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
        }

        private var foreground: Color {
            switch tone {
            case .accent: .white
            case .banana: Palette.bananaInk
            case .bananaTint: Palette.banana
            case .quiet: .white.opacity(0.9)
            }
        }

        private var background: Color {
            switch tone {
            case .accent: .accentColor
            case .banana: Palette.banana
            case .bananaTint: Palette.banana.opacity(isHovered && isEnabled ? 0.26 : 0.2)
            case .quiet: .white.opacity(isHovered && isEnabled ? 0.16 : 0.11)
            }
        }
    }
}

/// `m:ss.mmm`, or `h:mm:ss.mmm` past the hour.
func timecode(_ seconds: Double) -> String {
    let total = max(seconds, 0)
    let whole = Int(total)
    let milliseconds = min(Int((total - Double(whole)) * 1000), 999)
    let (hours, minutes, secs) = (whole / 3600, (whole % 3600) / 60, whole % 60)
    return hours > 0
        ? String(format: "%d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
        : String(format: "%d:%02d.%03d", minutes, secs, milliseconds)
}
