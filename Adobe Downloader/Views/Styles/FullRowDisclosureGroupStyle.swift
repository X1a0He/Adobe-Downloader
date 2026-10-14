import SwiftUI

struct FullRowDisclosureGroupStyle: DisclosureGroupStyle {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage

    func makeBody(configuration: Configuration) -> some View {
        let _ = interfaceLanguage
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? AppLocalized("已展开") : AppLocalized("已收起"))

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
