//
//  CheckForUpdatesViewModel.swift
//  Adobe Downloader
//
//  Created by X1a0He on 11/6/24.
//

import SwiftUI
import Sparkle

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater

        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        let _ = interfaceLanguage
        Button(action: updater.checkForUpdates) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                Text(AppLocalized("检查更新"))
                    .font(.system(size: 13))
            }
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
        .foregroundColor(.white)
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
        .opacity(!checkForUpdatesViewModel.canCheckForUpdates ? 0.6 : 1.0)
    }
}
