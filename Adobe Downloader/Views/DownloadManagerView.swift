//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//

import SwiftUI

struct DownloadManagerView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var networkManager = globalNetworkManager
    @State private var sortOrder: SortOrder = .addTime
    @State private var showClearConfirmation = false
    @State private var searchText: String = ""
    @State private var activeStatusFilter: Set<StatusFilterChip> = []
    @State private var showAdvancedFilter = false
    @State private var sapCodeFilter: String = ""
    @State private var pathFilter: String = ""

    enum SortOrder: Hashable {
        case addTime, name, status, size, progress, remaining

        var label: String {
            switch self {
            case .addTime:   return String(localized: "按添加时间")
            case .name:      return String(localized: "按名称")
            case .status:    return String(localized: "按状态")
            case .size:      return String(localized: "按大小")
            case .progress:  return String(localized: "按进度")
            case .remaining: return String(localized: "按剩余时间")
            }
        }

        var icon: String {
            switch self {
            case .addTime:   return "clock"
            case .name:      return "textformat"
            case .status:    return "dot.radiowaves.up.forward"
            case .size:      return "externaldrive"
            case .progress:  return "chart.line.uptrend.xyaxis"
            case .remaining: return "hourglass"
            }
        }
    }

    enum StatusFilterChip: String, CaseIterable, Identifiable, Hashable {
        case downloading, waiting, paused, retrying, completed, failed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .downloading: return String(localized: "下载中")
            case .waiting:     return String(localized: "等待中")
            case .paused:      return String(localized: "已暂停")
            case .retrying:    return String(localized: "重试中")
            case .completed:   return String(localized: "已完成")
            case .failed:      return String(localized: "失败")
            }
        }

        var icon: String {
            switch self {
            case .downloading: return "arrow.down.circle"
            case .waiting:     return "clock.circle"
            case .paused:      return "pause.circle"
            case .retrying:    return "arrow.clockwise.circle"
            case .completed:   return "checkmark.circle"
            case .failed:      return "xmark.circle"
            }
        }

        var tint: Color {
            switch self {
            case .downloading: return .blue
            case .waiting:     return .gray
            case .paused:      return .orange
            case .retrying:    return .yellow
            case .completed:   return .green
            case .failed:      return .red
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DownloadManagerHeaderView(
                sortOrder: $sortOrder,
                canPauseAll: hasPausableTasks,
                canResumeAll: hasResumableTasks,
                canClearFinished: hasFinishedTasks,
                onPauseAll: pauseAll,
                onResumeAll: resumeAll,
                onClear: { showClearConfirmation = true },
                onClose: { dismiss() }
            )

            DownloadManagerStatsBar(tasks: networkManager.downloadTasks)

            DownloadManagerFilterBar(
                searchText: $searchText,
                activeFilters: $activeStatusFilter,
                showAdvanced: $showAdvancedFilter,
                sapCodeFilter: $sapCodeFilter,
                pathFilter: $pathFilter,
                statusCounts: statusCounts
            )

            Divider().opacity(0.4)

            if filteredTasks.isEmpty {
                DownloadManagerEmptyView(
                    hasRawTasks: !networkManager.downloadTasks.isEmpty,
                    onClearFilters: clearAllFilters
                )
            } else {
                taskList
            }
        }
        .background(.ultraThinMaterial)
        .frame(
            minWidth: 720,
            idealWidth: 780,
            maxWidth: 1100,
            minHeight: 560,
            idealHeight: 620,
            maxHeight: 900
        )
        .alert(String(localized: "确认删除"), isPresented: $showClearConfirmation) {
            Button(String(localized: "取消"), role: .cancel) { }
            Button(String(localized: "确认"), role: .destructive) { clearFinishedTasks() }
        } message: {
            if StorageData.shared.deleteCompletedTasksWithFiles {
                Text("确定要删除所有已完成和失败的下载任务吗？\n\n• 所有任务：将删除任务记录和本地文件")
            } else {
                Text("确定要删除所有已完成和失败的下载任务吗？\n\n• 所有任务：仅删除任务记录，保留本地文件")
            }
        }
    }

    private var taskList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(filteredTasks) { task in
                    TaskCard(task: task) { action in
                        handleAction(action, for: task)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var sortedTasks: [NewDownloadTask] {
        let tasks = networkManager.downloadTasks
        switch sortOrder {
        case .addTime:
            return tasks.sorted { $0.createAt > $1.createAt }
        case .name:
            return tasks.sorted { $0.displayName < $1.displayName }
        case .status:
            return tasks.sorted { $0.status.sortOrder < $1.status.sortOrder }
        case .size:
            return tasks.sorted { $0.totalSize > $1.totalSize }
        case .progress:
            return tasks.sorted { $0.totalProgress > $1.totalProgress }
        case .remaining:
            return tasks.sorted { lhs, rhs in
                remainingSeconds(for: lhs) < remainingSeconds(for: rhs)
            }
        }
    }

    private var filteredTasks: [NewDownloadTask] {
        var list = sortedTasks

        if !activeStatusFilter.isEmpty {
            list = list.filter { task in
                if let chip = classify(task.status) {
                    return activeStatusFilter.contains(chip)
                }
                return false
            }
        }

        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.productId.lowercased().contains(q)
                    || $0.productVersion.lowercased().contains(q)
            }
        }

        let sapQuery = sapCodeFilter.trimmingCharacters(in: .whitespaces).lowercased()
        if !sapQuery.isEmpty {
            list = list.filter { task in
                task.dependenciesToDownload.contains {
                    $0.sapCode.lowercased().contains(sapQuery)
                }
            }
        }

        let pathQuery = pathFilter.trimmingCharacters(in: .whitespaces).lowercased()
        if !pathQuery.isEmpty {
            list = list.filter {
                $0.directory.path.lowercased().contains(pathQuery)
            }
        }

        return list
    }

    private var statusCounts: [StatusFilterChip: Int] {
        var result: [StatusFilterChip: Int] = [:]
        for task in networkManager.downloadTasks {
            if let chip = classify(task.status) {
                result[chip, default: 0] += 1
            }
        }
        return result
    }

    private var hasPausableTasks: Bool {
        networkManager.downloadTasks.contains { task in
            if case .downloading = task.status { return true }
            return false
        }
    }

    private var hasResumableTasks: Bool {
        networkManager.downloadTasks.contains { task in
            if case .paused = task.status { return true }
            return false
        }
    }

    private var hasFinishedTasks: Bool {
        networkManager.downloadTasks.contains { task in
            if case .completed = task.status { return true }
            if case .failed = task.status { return true }
            return false
        }
    }

    private func classify(_ status: DownloadStatus) -> StatusFilterChip? {
        switch status {
        case .downloading, .preparing: return .downloading
        case .waiting:    return .waiting
        case .paused:     return .paused
        case .retrying:   return .retrying
        case .completed:  return .completed
        case .failed:     return .failed
        }
    }

    private func remainingSeconds(for task: NewDownloadTask) -> Int {
        guard task.totalSpeed > 0 else { return Int.max }
        return Int(Double(task.totalSize - task.totalDownloadedSize) / task.totalSpeed)
    }

    private func clearAllFilters() {
        withAnimation(.easeInOut(duration: 0.15)) {
            searchText = ""
            activeStatusFilter.removeAll()
            sapCodeFilter = ""
            pathFilter = ""
        }
    }

    private func handleAction(_ action: TaskAction, for task: NewDownloadTask) {
        Task {
            switch action {
            case .pause:
                await globalNewDownloadUtils.pauseDownloadTask(taskId: task.id, reason: .userRequested)
            case .resume, .retry:
                await globalNewDownloadUtils.resumeDownloadTask(taskId: task.id)
            case .cancel:
                await globalNewDownloadUtils.cancelDownloadTask(taskId: task.id)
            case .remove:
                removeTask(task)
            case .install:
                break
            }
        }
    }

    private func removeTask(_ task: NewDownloadTask) {
        let shouldRemoveFiles: Bool
        if case .failed = task.status {
            shouldRemoveFiles = StorageData.shared.deleteCompletedTasksWithFiles
        } else if case .completed = task.status {
            shouldRemoveFiles = StorageData.shared.deleteCompletedTasksWithFiles
        } else {
            shouldRemoveFiles = StorageData.shared.deleteCompletedTasksWithFiles
        }
        globalNetworkManager.removeTask(taskId: task.id, removeFiles: shouldRemoveFiles)
    }

    private func pauseAll() {
        Task {
            for task in networkManager.downloadTasks {
                if case .downloading = task.status {
                    await globalNewDownloadUtils.pauseDownloadTask(taskId: task.id, reason: .userRequested)
                }
            }
        }
    }

    private func resumeAll() {
        Task {
            for task in networkManager.downloadTasks {
                if case .paused = task.status {
                    await globalNewDownloadUtils.resumeDownloadTask(taskId: task.id)
                }
            }
        }
    }

    private func clearFinishedTasks() {
        let tasksToRemove = networkManager.downloadTasks.filter { task in
            if case .completed = task.status { return true }
            if case .failed = task.status { return true }
            return false
        }
        for task in tasksToRemove {
            removeTask(task)
        }
        globalNetworkManager.updateDockBadge()
    }
}

private struct DownloadManagerHeaderView: View {
    @Binding var sortOrder: DownloadManagerView.SortOrder
    let canPauseAll: Bool
    let canResumeAll: Bool
    let canClearFinished: Bool
    let onPauseAll: () -> Void
    let onResumeAll: () -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(String(localized: "下载管理"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                sortMenu

                batchButton(
                    label: String(localized: "全部暂停"),
                    icon: "pause.fill",
                    color: .orange,
                    enabled: canPauseAll,
                    action: onPauseAll
                )
                batchButton(
                    label: String(localized: "全部继续"),
                    icon: "play.fill",
                    color: .blue,
                    enabled: canResumeAll,
                    action: onResumeAll
                )
                batchButton(
                    label: String(localized: "清除已完成"),
                    icon: "trash",
                    color: .red,
                    enabled: canClearFinished,
                    action: onClear
                )

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(GlassIconButtonStyle(tint: .secondary))
                .help(String(localized: "关闭"))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.5)
        }
        .background(.thinMaterial)
    }

    private func batchButton(label: String, icon: String, color: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: color))
        .opacity(enabled ? 1.0 : 0.4)
        .disabled(!enabled)
        .help(label)
    }

    private var sortMenu: some View {
        Menu {
            ForEach([DownloadManagerView.SortOrder.addTime, .name, .status, .size, .progress, .remaining], id: \.self) { order in
                Button(action: { sortOrder = order }) {
                    HStack {
                        Image(systemName: order.icon)
                        Text(order.label)
                        if sortOrder == order {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sortOrder.icon)
                    .font(.system(size: 10))
                Text(sortOrder.label)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .foregroundColor(.primary.opacity(0.8))
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct DownloadManagerStatsBar: View {
    let tasks: [NewDownloadTask]

    private var stats: AggregatedStats {
        var running = 0
        var waiting = 0
        var completed = 0
        var failed = 0
        var totalSpeed: Double = 0
        var remainingSize: Int64 = 0
        for task in tasks {
            switch task.status {
            case .downloading, .preparing, .retrying:
                running += 1
                totalSpeed += task.totalSpeed
                remainingSize += max(task.totalSize - task.totalDownloadedSize, 0)
            case .waiting, .paused:
                waiting += 1
            case .completed:
                completed += 1
            case .failed:
                failed += 1
            }
        }
        return AggregatedStats(
            running: running,
            waiting: waiting,
            completed: completed,
            failed: failed,
            totalSpeed: totalSpeed,
            remainingSize: remainingSize
        )
    }

    var body: some View {
        if tasks.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                StatPill(icon: "arrow.down.circle.fill", label: String(localized: "运行中"), value: "\(stats.running)", tint: .blue)
                StatPill(icon: "clock.fill", label: String(localized: "等待"), value: "\(stats.waiting)", tint: .gray)
                StatPill(icon: "checkmark.circle.fill", label: String(localized: "已完成"), value: "\(stats.completed)", tint: .green)
                StatPill(icon: "xmark.circle.fill", label: String(localized: "失败"), value: "\(stats.failed)", tint: .red)

                Spacer()

                if stats.totalSpeed > 0 {
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 10))
                            Text(DownloadFormatters.speed(stats.totalSpeed))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                        }
                        .foregroundColor(.blue)

                        if stats.totalSpeed > 0 && stats.remainingSize > 0 {
                            let remaining = DownloadFormatters.remainingTime(
                                total: stats.remainingSize,
                                downloaded: 0,
                                speed: stats.totalSpeed
                            )
                            if !remaining.isEmpty {
                                Text("·")
                                    .foregroundColor(.secondary.opacity(0.4))
                                HStack(spacing: 3) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 10))
                                    Text(String(format: String(localized: "剩余 %@"), remaining))
                                        .font(.system(size: 12))
                                        .monospacedDigit()
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.08))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
    }

    private struct AggregatedStats {
        let running: Int
        let waiting: Int
        let completed: Int
        let failed: Int
        let totalSpeed: Double
        let remainingSize: Int64
    }
}

private struct StatPill: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(tint.opacity(0.9))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.9))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(tint.opacity(0.15), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct DownloadManagerFilterBar: View {
    @Binding var searchText: String
    @Binding var activeFilters: Set<DownloadManagerView.StatusFilterChip>
    @Binding var showAdvanced: Bool
    @Binding var sapCodeFilter: String
    @Binding var pathFilter: String
    let statusCounts: [DownloadManagerView.StatusFilterChip: Int]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                searchField
                advancedMenu
            }

            HStack(spacing: 6) {
                ForEach(DownloadManagerView.StatusFilterChip.allCases) { chip in
                    DMFilterChip(
                        chip: chip,
                        count: statusCounts[chip] ?? 0,
                        isActive: activeFilters.contains(chip),
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if activeFilters.contains(chip) {
                                    activeFilters.remove(chip)
                                } else {
                                    activeFilters.insert(chip)
                                }
                            }
                        }
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
            TextField(String(localized: "搜索产品名 / 版本 / productId"), text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var advancedMenu: some View {
        Menu {
            Section(String(localized: "进阶过滤")) {
                EmptyView()
            }
            TextFieldMenuItem(title: String(localized: "sapCode 包含"), placeholder: "PHSP", text: $sapCodeFilter)
            TextFieldMenuItem(title: String(localized: "路径包含"), placeholder: "/Downloads", text: $pathFilter)
            Divider()
            Button(action: {
                sapCodeFilter = ""
                pathFilter = ""
            }) {
                Label(String(localized: "重置进阶过滤"), systemImage: "arrow.counterclockwise")
            }
            .disabled(sapCodeFilter.isEmpty && pathFilter.isEmpty)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
                Text(String(localized: "进阶"))
                    .font(.system(size: 11, weight: .medium))
                if !sapCodeFilter.isEmpty || !pathFilter.isEmpty {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundColor(.primary.opacity(0.8))
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct TextFieldMenuItem: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }
}

private struct DMFilterChip: View {
    let chip: DownloadManagerView.StatusFilterChip
    let count: Int
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: chip.icon)
                    .font(.system(size: 10))
                Text(chip.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary.opacity(0.75))
            }
            .foregroundColor(isActive ? chip.tint : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? chip.tint.opacity(0.14) : Color.secondary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? chip.tint.opacity(0.35) : Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct DownloadManagerEmptyView: View {
    let hasRawTasks: Bool
    let onClearFilters: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: hasRawTasks ? "line.3.horizontal.decrease.circle" : "tray")
                    .font(.system(size: 34))
                    .foregroundColor(.secondary.opacity(0.85))
            }

            VStack(spacing: 6) {
                Text(hasRawTasks ? String(localized: "没有匹配的任务") : String(localized: "暂无下载任务"))
                    .font(.system(size: 15, weight: .semibold))
                Text(hasRawTasks
                     ? String(localized: "尝试调整筛选条件或清空筛选")
                     : String(localized: "从产品列表选择一个产品以开始下载"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if hasRawTasks {
                Button(action: onClearFilters) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                        Text(String(localized: "清空筛选"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview {
    DownloadManagerView()
}
