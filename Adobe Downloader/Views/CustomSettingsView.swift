//
//  CleanupView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 4/6/25.
//
import SwiftUI
import Sparkle

struct CustomSettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @StateObject private var cleanupViewModel = CleanupViewModel()
    @StateObject private var helperPlaygroundViewModel = HelperPlaygroundViewModel()
    @Environment(\.presentationMode) var presentationMode

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case helper
        case cleanup
        case qa
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return String(localized: "通用")
            case .helper:  return String(localized: "Helper 设置")
            case .cleanup: return String(localized: "清理工具")
            case .qa:      return String(localized: "常见问题")
            case .about:   return String(localized: "关于")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .helper:  return "lock.shield.fill"
            case .cleanup: return "trash.fill"
            case .qa:      return "questionmark.circle.fill"
            case .about:   return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .blue
            case .helper:  return .indigo
            case .cleanup: return .red
            case .qa:      return .orange
            case .about:   return .gray
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedTab: $selectedTab)
                .frame(width: 200)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .frame(width: 0.5)
                                .foregroundColor(.secondary.opacity(0.15)),
                            alignment: .trailing
                        )
                )

            ScrollView(showsIndicators: false) {
                content
                    .padding(.top, 42)
                    .padding(.leading, 24)
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    .id(selectedTab)
            }
            .background(Color(.windowBackgroundColor).opacity(0.3))
        }
        .overlay(alignment: .topTrailing) {
            SettingsCloseButton(onClose: { presentationMode.wrappedValue.dismiss() })
                .padding(12)
        }
        .frame(
            minWidth: 720,
            idealWidth: 780,
            maxWidth: 1100,
            minHeight: 560,
            idealHeight: 620,
            maxHeight: 900
        )
        .background(.ultraThinMaterial)
        .onAppear {
            selectedTab = .general
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView(updater: updater)
        case .helper:
            HelperView(updater: updater, playgroundViewModel: helperPlaygroundViewModel)
        case .cleanup:
            CleanupView(viewModel: cleanupViewModel)
        case .qa:
            QAView()
        case .about:
            AboutAppView()
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: CustomSettingsView.SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(CustomSettingsView.SettingsTab.allCases) { tab in
                    SettingsSidebarItem(
                        tab: tab,
                        isActive: selectedTab == tab,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
    }
}

private struct SettingsSidebarItem: View {
    let tab: CustomSettingsView.SettingsTab
    let isActive: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tab.tint.opacity(isActive ? 0.22 : 0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .foregroundColor(tab.tint)
                }
                Text(tab.title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(.primary.opacity(isActive ? 0.95 : 0.75))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? Color.secondary.opacity(0.14) : (isHovered ? Color.secondary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(tab.title)
    }
}

private struct SettingsCloseButton: View {
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovered ? Color.secondary.opacity(0.28) : Color.secondary.opacity(0.14))
                )
                .overlay(
                    Circle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .onHover { isHovered = $0 }
        .help(String(localized: "关闭"))
    }
}
