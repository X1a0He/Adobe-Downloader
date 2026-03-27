import SwiftUI

struct BannerView: View {
    var body: some View {
        HStack {
            Spacer()
            
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                    Text("Adobe Downloader 完全开源免费")
                    Link("GitHub", destination: URL(string: "https://github.com/X1a0He/Adobe-Downloader")!)
                }
                
                HStack(spacing: 6) {
                    Image(systemName: "seal")
                    Text("开源免费")
                    Link("GitHub", destination: URL(string: "https://github.com/X1a0He/Adobe-Downloader")!)
                }
                
                Link("GitHub", destination: URL(string: "https://github.com/X1a0He/Adobe-Downloader")!)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.6)
        }
    }
}
