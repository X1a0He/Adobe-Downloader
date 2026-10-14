//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import SwiftUI

struct BeautifulLanguageSearchField: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @Binding var text: String
    
    var body: some View {
        let _ = interfaceLanguage
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))
            
            TextField(AppLocalized("搜索语言"), text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 13))
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

struct LanguagePickerView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let languages: [(code: String, name: String)]
    let onLanguageSelected: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var selectedLanguage: String = ""
    
    private var filteredLanguages: [(code: String, name: String)] {
        guard !searchText.isEmpty else {
            return languages
        }
        
        let searchTerms = searchText.lowercased()
        return languages.filter { language in
            language.name.lowercased().contains(searchTerms) ||
            language.code.lowercased().contains(searchTerms)
        }
    }
    
    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            HStack {
                Text(AppLocalized("选择安装语言"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary.opacity(0.9))
                Spacer()
                Button(AppLocalized("取消")) {
                    dismiss()
                }
                .font(.system(size: 14))
                .foregroundColor(.blue)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color(NSColor.windowBackgroundColor)
                    .overlay(
                        Rectangle()
                            .frame(height: 0.5)
                            .foregroundColor(Color.secondary.opacity(0.2)),
                        alignment: .bottom
                    )
            )

            BeautifulLanguageSearchField(text: $searchText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 1)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredLanguages.enumerated()), id: \.element.code) { index, language in
                        LanguageRow(
                            language: language,
                            isSelected: language.code == selectedLanguage,
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedLanguage = language.code
                                }
                                onLanguageSelected(language.code)
                                dismiss()
                            }
                        )
                        
                        if index < filteredLanguages.count - 1 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.06))
                                .frame(height: 0.5)
                                .padding(.leading, 46)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if filteredLanguages.isEmpty {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(spacing: 8) {
                        Text(AppLocalized("未找到语言"))
                            .font(.system(size: 16, weight: .medium))
                        
                        Text(AppLocalized("尝试其他搜索关键词"))
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -20)
            }
        }
        .frame(width: 320, height: 400)
    }
}

struct LanguageRow: View {
    let language: (code: String, name: String)
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: getLanguageIcon(language.code))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.blue)
                }

                Text(language.name)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(language.code)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.8))
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                        .frame(width: 20)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
    
    private func getLanguageIcon(_ code: String) -> String {
        switch code {
        case "zh_CN", "zh_TW":
            return "character.textbox"
        case "en_US", "en_GB":
            return "a.square"
        case "ja_JP":
            return "j.square"
        case "ko_KR":
            return "k.square"
        case "fr_FR":
            return "f.square"
        case "de_DE":
            return "d.square"
        case "es_ES":
            return "e.square"
        case "it_IT":
            return "i.square"
        case "ru_RU":
            return "r.square"
        case "ALL":
            return "globe"
        default:
            return "character.square"
        }
    }
}

#Preview {
    LanguagePickerView(
        languages: AppStatics.supportedLanguages,
        onLanguageSelected: { _ in }
    )
}
