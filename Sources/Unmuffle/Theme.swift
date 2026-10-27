#if os(macOS)
import SwiftUI
import UnmuffleDSP

enum Theme {
    static let violet = Color(red: 0.49, green: 0.36, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.37, blue: 0.56)
    static let gradient = LinearGradient(colors: [violet, pink], startPoint: .leading, endPoint: .trailing)
    static let diagonal = LinearGradient(colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color.primary.opacity(0.05)
    static let stroke = Color.primary.opacity(0.08)
}

extension Preset {
    var symbol: String {
        switch id {
        case "cam": return "film"
        case "telesync": return "waveform"
        case "quiet": return "speaker.wave.1.fill"
        case "night": return "moon.stars.fill"
        case "max": return "bolt.fill"
        default: return "slider.horizontal.3"
        }
    }

    var shortName: String {
        switch id {
        case "cam": return "Cam"
        case "telesync": return "Line"
        case "quiet": return "Quiet"
        case "night": return "Night"
        case "max": return "Max"
        default: return name
        }
    }
}

/// The app mark: a gradient squircle with a waveform.
struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Theme.diagonal)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}
#endif
