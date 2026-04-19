import SwiftUI

private func formatDurationLocal(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, secs)
}

struct TaskCard: View {
    @ObservedObject var task: NewDownloadTask
    let onAction: (TaskAction) -> Void

    @State private var isExpanded = false
    @State private var confirmAction: TaskAction? = nil
    @State private var isInstalling = false
    @State private var showHelperAlert = false
    @State private var showCopiedToast = false
    @StateObject private var iconLoader = AsyncImageLoader()

    private var clampedTotalProgress: Double {
        min(max(task.totalProgress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeaderView(
                task: task,
                iconImage: iconLoader.image,
                statusBadgeContent: { statusBadge },
                actionButtons: { actionButtons }
            )
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            switch task.status {
            case .downloading, .preparing, .waiting:
                CardProgressView(task: task, tint: task.status.progressBarColor, isIndeterminate: false)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .paused(let info):
                CardProgressView(task: task, tint: .orange, isIndeterminate: false)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                PausedInfoView(info: info)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .failed(let info):
                FailedInfoView(info: info, progressAtFailure: clampedTotalProgress)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .completed(let info):
                CompletedInfoView(task: task, info: info, onOpenInFinder: openInFinder)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

            case .retrying(let info):
                RetryingInfoView(info: info)
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
        .animation(.easeInOut(duration: 0.2), value: task.totalStatus)
        .contextMenu { contextMenuItems }
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
        .overlay(alignment: .top) {
            if showCopiedToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已复制任务信息")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear { iconLoader.load(productId: task.productId) }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: task.status.statusIcon)
                .font(.system(size: 9))
            Text(task.status.description)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
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

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch task.status {
            case .downloading, .preparing, .waiting:
                iconActionButton(.pause)
                iconActionButton(.cancel)

            case .paused:
                primaryActionButton(.resume)
                iconActionButton(.cancel)

            case .failed(let info):
                if info.recoverable {
                    primaryActionButton(.retry)
                }
                iconActionButton(.remove)

            case .completed:
                if task.displayInstallButton {
                    primaryActionButton(.install)
                }
                iconActionButton(.remove)

            case .retrying:
                iconActionButton(.cancel)
            }
        }
    }

    private func iconActionButton(_ action: TaskAction) -> some View {
        Button(action: { handleAction(action) }) {
            Image(systemName: action.buttonIcon)
        }
        .buttonStyle(GlassIconButtonStyle(tint: action.buttonColor))
        .help(action.buttonLabel)
    }

    private func primaryActionButton(_ action: TaskAction) -> some View {
        Button(action: { handleAction(action) }) {
            HStack(spacing: 4) {
                Image(systemName: action.buttonIcon)
                    .font(.system(size: 10, weight: .semibold))
                Text(action.buttonLabel)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: action.buttonColor))
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

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(action: openInFinder) {
            Label(String(localized: "在 Finder 中显示"), systemImage: "folder")
        }
        Button(action: copyTaskInfo) {
            Label(String(localized: "复制任务信息"), systemImage: "doc.on.doc")
        }
        if case .completed = task.status {
            Button(action: openProduct) {
                Label(String(localized: "打开产品"), systemImage: "arrow.up.forward.app")
            }
        }
        Divider()
        Button(role: .destructive, action: {
            confirmAction = .remove
        }) {
            Label(String(localized: "删除任务"), systemImage: "trash")
        }
    }

    private func openInFinder() {
        let url = URL(fileURLWithPath: task.directory.path)
        NSWorkspace.shared.selectFile(
            url.path,
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path
        )
    }

    private func openProduct() {
        if task.productId == "APRO" {
            NSWorkspace.shared.open(task.directory)
        } else {
            NSWorkspace.shared.open(task.directory)
        }
    }

    private func copyTaskInfo() {
        var lines: [String] = []
        lines.append("\(task.displayName) \(task.productVersion)")
        lines.append("产品: \(task.productId)")
        lines.append("平台: \(task.platform)")
        if !task.language.isEmpty {
            lines.append("语言: \(task.language)")
        }
        lines.append("路径: \(task.directory.path)")
        lines.append("状态: \(task.status.description)")
        lines.append("大小: \(task.formattedTotalSize)")
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedToast = false
            }
        }
    }
}

private struct CardHeaderView<Badge: View, Actions: View>: View {
    @ObservedObject var task: NewDownloadTask
    let iconImage: NSImage?
    @ViewBuilder let statusBadgeContent: () -> Badge
    @ViewBuilder let actionButtons: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

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
                    let url = URL(fileURLWithPath: task.directory.path)
                    NSWorkspace.shared.selectFile(
                        url.path,
                        inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                    )
                }
                .help(task.directory.path)
            }

            Spacer()

            statusBadgeContent()

            actionButtons()
        }
    }

    private var iconView: some View {
        Group {
            if let image = iconImage {
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
}

private struct CardProgressView: View {
    @ObservedObject var task: NewDownloadTask
    let tint: Color
    let isIndeterminate: Bool

    private var clampedProgress: Double {
        min(max(task.totalProgress, 0), 1)
    }

    private var currentFileInfo: (name: String, index: Int, total: Int)? {
        if case .downloading(let info) = task.status {
            return (info.fileName, info.currentPackageIndex + 1, info.totalPackages)
        }
        if let current = task.currentPackage {
            return (current.fullPackageName, task.completedPackages + 1, max(task.totalPackages, 1))
        }
        return nil
    }

    private var stageText: String? {
        if case .preparing(let info) = task.status {
            return info.stage.title
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.06))
                        .frame(height: 8)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.6), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: CGFloat(clampedProgress) * geometry.size.width, height: 8)
                        .shadow(color: tint.opacity(0.4), radius: 4, x: 0, y: 0)
                        .animation(.linear(duration: 0.3), value: clampedProgress)
                }
            }
            .frame(height: 8)

            HStack(spacing: 6) {
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

                if let stageText = stageText {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.3))
                    HStack(spacing: 3) {
                        Image(systemName: "gear.circle")
                            .font(.system(size: 9))
                        Text(stageText)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.purple.opacity(0.85))
                }

                Spacer()

                Text("\(Int(clampedProgress * 100))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(tint)

                if task.totalSpeed > 0 {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.3))
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

            if let info = currentFileInfo {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 9))
                        .foregroundColor(.blue.opacity(0.7))
                    Text(info.name)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("(\(info.index)/\(info.total))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .monospacedDigit()
                }
            }
        }
    }
}

private struct PausedInfoView: View {
    let info: DownloadStatus.PauseInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange.opacity(0.85))
            Text(info.reason.localizedText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange.opacity(0.9))
            if !info.resumable {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.3))
                Text(String(localized: "不可恢复"))
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.7))
            }
            Spacer()
            Text(info.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}

private struct FailedInfoView: View {
    let info: DownloadStatus.FailureInfo
    let progressAtFailure: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
                Text(info.message)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.9))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer()
            }
            HStack(spacing: 8) {
                if progressAtFailure > 0 {
                    Text("中断于 \(Int(progressAtFailure * 100))%")
                        .foregroundColor(.secondary.opacity(0.8))
                }
                if info.recoverable {
                    Text("·").foregroundColor(.secondary.opacity(0.3))
                    Text(String(localized: "可重试"))
                        .foregroundColor(.blue.opacity(0.85))
                } else {
                    Text("·").foregroundColor(.secondary.opacity(0.3))
                    Text(String(localized: "不可恢复"))
                        .foregroundColor(.red.opacity(0.75))
                }
                Spacer()
                Text(info.timestamp.formatted(date: .omitted, time: .shortened))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .font(.system(size: 10, weight: .medium))
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
}

private struct CompletedInfoView: View {
    @ObservedObject var task: NewDownloadTask
    let info: DownloadStatus.CompletionInfo
    let onOpenInFinder: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green.opacity(0.85))
            Text(task.formattedTotalSize)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
            if info.totalTime > 0 {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.3))
                Text(String(format: String(localized: "用时 %@"), formatDurationLocal(info.totalTime)))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text("·")
                .foregroundColor(.secondary.opacity(0.3))
            Text(info.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: onOpenInFinder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(String(localized: "打开目录"))
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(GlassButtonStyle(tint: .green))
        }
    }
}

private struct RetryingInfoView: View {
    let info: DownloadStatus.RetryInfo
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remainingSeconds: Int {
        max(0, Int(info.nextRetryDate.timeIntervalSince(now)))
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text(String(localized: "重试 \(info.attempt)/\(info.maxAttempts)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.yellow.opacity(0.95))
            if !info.reason.isEmpty {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.3))
                Text(info.reason)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if remainingSeconds > 0 {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.3))
                Text(String(format: String(localized: "%02d:%02d 后重试"), remainingSeconds / 60, remainingSeconds % 60))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                    .monospacedDigit()
            }
            Spacer()
        }
        .onReceive(timer) { now = $0 }
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
