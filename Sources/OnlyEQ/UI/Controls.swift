import SwiftUI

/// macOS-switch lookalike drawn in pure SwiftUI. AppKit's NSSwitch doesn't
/// render its state when drawn into an offscreen window (which breaks the
/// --screenshots mode), and this also guarantees an identical look everywhere.
struct AccentSwitchStyle: ToggleStyle {
    var width: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        let height = width * 0.585
        return HStack {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.18))
                .frame(width: width, height: height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(1.5)
                }
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}
