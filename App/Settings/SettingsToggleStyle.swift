import SwiftUI

/// Explicit state feedback independent of the system accent and inactive-window switch tint.
struct SettingsToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Label(configuration.isOn ? "켜짐" : "꺼짐",
                      systemImage: configuration.isOn ? "checkmark" : "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minWidth: 76)
                    .background {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(configuration.isOn
                                  ? Color(red: 0.06, green: 0.34, blue: 0.76)
                                  : Color.secondary.opacity(0.14))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(configuration.isOn ? Color.clear : Color.secondary.opacity(0.25))
                    }
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
