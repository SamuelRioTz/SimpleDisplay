import SwiftUI

struct LanguageSwitcherView: View {
    @Environment(LocaleManager.self) private var locale

    private let languages: [(code: String, label: String)] = [
        ("en", "EN"),
        ("es", "ES"),
        ("de", "DE"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(languages, id: \.code) { lang in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        locale.setLanguage(lang.code)
                    }
                } label: {
                    Text(verbatim: lang.label)
                        .font(.caption2)
                        .fontWeight(locale.language == lang.code ? .bold : .regular)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            locale.language == lang.code
                                ? Color.cyan.opacity(0.15)
                                : Color.clear
                        )
                        .foregroundStyle(
                            locale.language == lang.code
                                ? .primary
                                : .secondary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
