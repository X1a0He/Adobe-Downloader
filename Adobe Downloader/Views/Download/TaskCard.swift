import SwiftUI

struct TaskCard: View {
    @ObservedObject var task: NewDownloadTask
    let onAction: (TaskAction) -> Void

    @State private var isExpanded = false
    @State private var confirmAction: TaskAction? = nil
    @State private var isInstalling = false
    @State private var showHelperAlert = false
    @StateObject private var iconLoader = AsyncImageLoader()

    private var clampedTotalProgress: Double {
        min(max(task.totalProgress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            switch task.status {
            case .downloading, .preparing, .waiting:
                progressSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .paused:
                pausedSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .failed(let info):
                failedSection(info)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .completed:
                completedSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .retrying(let info):
                retryingSection(info)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            if !task.dependenciesToDownload.isEmpty {
                Divider()
                    .opacity(0.5)
                    .padding(.horizontal, 16)
                packageToggle
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                if isExpanded {
                    TaskCardPackageList(task: task)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .alert(
            confirmAction?.confirmTitle ?? "",
            isPresented: Binding(
                get: { confirmAction != nil },
                set: { if !$0 { confirmAction = nil } }
            )
        ) {
            Button(String(localized: "返回"), role: .cancel) { confirmAction = nil }
            Button(String(localized: "确认"), role: .destructive) {
                if let action = confirmAction {
                    onAction(action)
                    confirmAction = nil
                }
            }
        } message: {
            Text(confirmAction?.confirmMessage(for: task.displayName) ?? "")
        }
        .alert(String(localized: "Helper 未连接"), isPresented: $showHelperAlert) {
            Button(String(localized: "确定")) { }
        } message: {
            Text("Helper 未启用或未连接，请先在设置中启用并连接 Helper")
        }
        .sheet(isPresented: $isInstalling) {
            let installViewData = globalNetworkManager.makeInstallProgressViewData(productName: task.displayName)
            InstallProgressView(
                data: installViewData,
                onCancel: {
                    if case .running = installViewData.outcome {
                        globalNetworkManager.cancelInstallation()
                    }
                    isInstalling = false
                },
                onRetry: {
                    Task {
                        await globalNetworkManager.retryInstallation(at: task.directory)
                    }
                }
            )
            .frame(minWidth: 760, minHeight: 420)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear { iconLoader.load(productId: task.productId) }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(task.productVersion)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundColor(.blue.opacity(0.6))
                    Text(DownloadFormatters.shortenedPath(task.directory.path))
                        .font(.system(size: 10))
                        .foregroundColor(.primary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .onTapGesture {
                    NSWorkspace.shared.selectFile(
                        URL(fileURLWithPath: task.directory.path).path,
                        inFileViewerRootedAtPath: URL(fileURLWithPath: task.directory.path).deletingLastPathComponent().path
                    )
                }
                .help(task.directory.path)
            }

            Spacer()

            statusBadge

            actionButtons
        }
    }

    private var iconView: some View {
        Group {
            if let image = iconLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: task.status.statusIcon)
                .font(.system(size: 9))
            Text(task.status.description)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(task.status.badgeColor)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .fill(task.status.badgeColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(task.status.badgeColor.opacity(0.3), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch task.status {
            case .downloading, .preparing, .waiting:
                actionButton(.pause)
                actionButton(.cancel)

            case .paused:
                actionButton(.resume)
                actionButton(.cancel)

            case .failed(let info):
                if info.recoverable {
                    actionButton(.retry)
                }
                actionButton(.remove)

            case .completed:
                if task.displayInstallButton {
                    actionButton(.install)
                }
                actionButton(.remove)

            case .retrying:
                actionButton(.cancel)
            }
        }
    }

    private func actionButton(_ action: TaskAction) -> some View {
        Button(action: { handleAction(action) }) {
            Image(systemName: action.buttonIcon)
        }
        .buttonStyle(GlassIconButtonStyle(tint: action.buttonColor))
        .help(action.buttonLabel)
    }

    private func handleAction(_ action: TaskAction) {
        if action == .install {
            do {
                _ = try PrivilegedHelperAdapter.shared.getHelperProxy()
                isInstalling = true
                Task { await globalNetworkManager.installProduct(at: task.directory) }
            } catch {
                showHelperAlert = true
            }
            return
        }

        if action.needsConfirmation {
            confirmAction = action
        } else {
            onAction(action)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.06))
                        .frame(height: 8)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    task.status.progressBarColor.opacity(0.6),
                                    task.status.progressBarColor
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: CGFloat(clampedTotalProgress) * geometry.size.width, height: 8)
                        .shadow(color: task.status.progressBarColor.opacity(0.4), radius: 4, x: 0, y: 0)
                        .animation(.linear(duration: 0.3), value: clampedTotalProgress)
                }
            }
            .frame(height: 8)

            HStack {
                HStack(spacing: 4) {
                    Text(task.formattedDownloadedSize)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                    Text("/")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(task.formattedTotalSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(Int(clampedTotalProgress * 100))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(task.status.progressBarColor)

                if task.totalSpeed > 0 {
                    Text("·").foregroundColor(.secondary.opacity(0.3))
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down").font(.system(size: 8))
                        Text(DownloadFormatters.speed(task.totalSpeed)).font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)

                    let remaining = DownloadFormatters.remainingTime(
                        total: task.totalSize,
                        downloaded: task.totalDownloadedSize,
                        speed: task.totalSpeed
                    )
                    if !remaining.isEmpty {
                        Text("·").foregroundColor(.secondary.opacity(0.3))
                        HStack(spacing: 2) {
                            Image(systemName: "clock").font(.system(size: 8))
                            Text(remaining).font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: task.totalSpeed > 0)
        }
    }

    private var pausedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.06))
                        .frame(height: 8)

                    Capsule()
                        .fill(Color.orange.opacity(0.5))
                        .frame(width: CGFloat(clampedTotalProgress) * geometry.size.width, height: 8)
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(task.formattedDownloadedSize) / \(task.formattedTotalSize)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(clampedTotalProgress * 100))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)
            }
        }
    }

    private func failedSection(_ info: DownloadStatus.FailureInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.8))
            Text(info.message)
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.8))
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var completedSection: some View {
        HStack {
            Text(task.formattedTotalSize)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func retryingSection(_ info: DownloadStatus.RetryInfo) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text(String(localized: "重试中 (\(info.attempt)/\(info.maxAttempts))"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var packageToggle: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(String(localized: "包详情"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("(\(task.completedPackages)/\(task.totalPackages))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

final class AsyncImageLoader: ObservableObject {
    @Published var image: NSImage?

    func load(productId: String) {
        let product = findProduct(id: productId)
        guard let product = product else {
            self.image = NSImage(named: productId)
            return
        }

        guard let bestIcon = product.getBestIcon(),
              let iconURL = URL(string: bestIcon.value) else {
            self.image = NSImage(named: productId)
            return
        }

        if let cached = IconCache.shared.getIcon(for: bestIcon.value) {
            self.image = cached
            return
        }

        Task {
            do {
                var request = URLRequest(url: iconURL)
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let img = NSImage(data: data) else {
                    throw URLError(.badServerResponse)
                }
                IconCache.shared.setIcon(img, for: bestIcon.value)
                await MainActor.run { self.image = img }
            } catch {
                if let local = NSImage(named: productId) {
                    await MainActor.run { self.image = local }
                }
            }
        }
    }
}
