#if os(macOS)
import SwiftUI

// Liquid Glass on macOS 26 and later, the regular native look before that.
//
// `#if compiler(>=6.2)` keeps the project building with Xcode 15 and 16, whose SDKs
// don't have the glass APIs. Built with Xcode 26, standard controls (switches,
// segmented controls, sliders) also pick up the glass look on their own.

extension View {
    /// A glass panel behind grouped controls.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 14) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.quaternary.opacity(0.5), in: .rect(cornerRadius: cornerRadius))
        }
        #else
        self.background(.quaternary.opacity(0.5), in: .rect(cornerRadius: cornerRadius))
        #endif
    }

    /// Glass button, prominent (accent-tinted) when `prominent` is true.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            legacyButtonStyle(prominent: prominent)
        }
        #else
        legacyButtonStyle(prominent: prominent)
        #endif
    }

    @ViewBuilder
    private func legacyButtonStyle(prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
#endif
