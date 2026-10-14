import SwiftUI

struct ContentView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @StateObject private var networkManager = globalNetworkManager
    @State private var showDownloadManager = false
    @State private var searchText = ""
    @StorageValue(\.apiVersion) private var currentApiVersion
    @Binding var showSettingsView: Bool

    private var filteredProducts: [UniqueProduct] {
        if searchText.isEmpty { return globalUniqueProducts }
        return globalUniqueProducts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) || 
            $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func openSettings() {
        showSettingsView = true
    }

    private func refreshData() {
        Task {
            await networkManager.fetchProducts()
        }
    }

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            BannerView()
            
            MainContentView(
                loadingState: networkManager.loadingState,
                filteredProducts: filteredProducts,
                searchText: searchText,
                onRetry: { networkManager.retryFetchData() },
                onOpenDownloadManager: { showDownloadManager = true }
            )
            .background(Color(.clear))
            .animation(.easeInOut, value: networkManager.loadingState)
        }
        .background(Color(.clear))
        .sheet(isPresented: $showDownloadManager) {
            DownloadManagerView() 
        }
        .toolbar {
            ToolbarView(
                currentApiVersion: $currentApiVersion,
                showDownloadManager: $showDownloadManager,
                isRefreshing: networkManager.isFetchingProducts,
                downloadTasksCount: networkManager.downloadTasks.count,
                onRefresh: refreshData,
                openSettings: openSettings
            )
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: AppLocalized("搜索应用或产品 ID"))
        .onChange(of: currentApiVersion) { newValue in
            refreshData()
        }
        .task {
            await networkManager.fetchProducts(forceRefresh: false)
        }
    }
}

struct SearchField: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @Binding var text: String

    var body: some View {
        let _ = interfaceLanguage
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(AppLocalized("搜索应用"), text: $text)
                .textFieldStyle(PlainTextFieldStyle())
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
