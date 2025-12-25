//
//  CleanupView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 4/6/25.
//
import SwiftUI
import Sparkle

struct CustomSettingsView: View {
    @State private var selectedTab = "general_settings"
    @StateObject private var cleanupViewModel = CleanupViewModel()
    @StateObject private var helperPlaygroundViewModel = HelperPlaygroundViewModel()
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) var colorScheme
    
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
    }
    
    var body: some View {
        ZStack {
            BlurView()
                .ignoresSafeArea()
            
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    HStack {
                        HStack(spacing: 0) {
                            SquareTabButton(
                                imageName: "gear",
                                title: String(localized: "通用"),
                                isSelected: selectedTab == "general_settings"
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedTab = "general_settings"
                                }
                            }
                            
                            SquareTabButton(
                                imageName: "lock.shield",
                                title: String(localized: "Helper 设置"),
                                isSelected: selectedTab == "helper_view"
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedTab = "helper_view"
                                }
                            }
                            .accessibilityLabel("Helper 设置")
                            
                            SquareTabButton(
                                imageName: "trash",
                                title: String(localized: "清理工具"),
                                isSelected: selectedTab == "cleanup_view"
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedTab = "cleanup_view"
                                }
                            }
                            .accessibilityLabel("清理工具")
                            
                            SquareTabButton(
                                imageName: "questionmark.circle",
                                title: String(localized: "常见问题"),
                                isSelected: selectedTab == "qa_view"
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedTab = "qa_view"
                                }
                            }
                            .accessibilityLabel("常见问题")
                            
                            SquareTabButton(
                                imageName: "info.circle",
                                title: String(localized: "关于"),
                                isSelected: selectedTab == "about_app"
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedTab = "about_app"
                                }
                            }
                            .accessibilityLabel("关于")
                        }
                        .padding(.leading, 8)
                        
                        Spacer()
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    
                    Divider()
                        .opacity(0.6)

                    ScrollView {
                        ZStack {
                            if selectedTab == "general_settings" {
                                GeneralSettingsView(updater: updater)
                                    .transition(contentTransition)
                                    .id("general_settings")
                            } else if selectedTab == "cleanup_view" {
                                CleanupView(viewModel: cleanupViewModel)
                                    .transition(contentTransition)
                                    .id("cleanup_view")
                            } else if selectedTab == "qa_view" {
                                QAView()
                                    .transition(contentTransition)
                                    .id("qa_view")
                            } else if selectedTab == "about_app" {
                                AboutAppView()
                                    .transition(contentTransition)
                                    .id("about_app")
                            } else if selectedTab == "helper_view" {
                                HelperView(updater: updater, playgroundViewModel: helperPlaygroundViewModel)
                                    .transition(contentTransition)
                                    .id("helper_view")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .background(Color.clear)
                }

                Button(action: {
                    withAnimation {
                        presentationMode.wrappedValue.dismiss()
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.gray)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? 
                                    Color.gray.opacity(0.3) : 
                                    Color.gray.opacity(0.15))
                        )
                        .help("关闭")
                }
                .buttonStyle(PlainButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                .padding(.top, 10)
                .padding(.trailing, 10)
            }
        }
        .frame(width: 700, height: 650)
        .onAppear {
            selectedTab = "general_settings"
        }
    }
    
    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98)).animation(.easeInOut(duration: 0.2)),
            removal: .opacity.animation(.easeInOut(duration: 0.1))
        )
    }
}

struct SquareTabButton: View {
    let imageName: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 40, height: 40)
                    }
                    
                    Image(systemName: imageName)
                        .font(.system(size: isSelected ? 18 : 17))
                        .foregroundColor(isSelected ? .blue : colorScheme == .dark ? .white : .black)
                }
                
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .blue : colorScheme == .dark ? .white : .primary)
            }
            .frame(width: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
} 
