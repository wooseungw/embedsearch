import SwiftUI

/// An iPhone-style switch whose color and thumb position remain clear in inactive windows.
struct SettingsToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(configuration.isOn
                              ? Color(red: 0.20, green: 0.78, blue: 0.35)
                              : Color.secondary.opacity(0.28))
                    Circle()
                        .fill(.white)
                        .frame(width: 27, height: 27)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                        .offset(x: configuration.isOn ? 20 : 0)
                        .padding(2)
                }
                .frame(width: 51, height: 31)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.45)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(configuration.isOn ? "클릭하여 끄기" : "클릭하여 켜기")
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}
