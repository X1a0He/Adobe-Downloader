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

    enum SortOrder: Hashable {
        case addTime, name, status

        var label: String {
            switch self {
            case .addTime: return String(localized: "按添加时间")
            case .name:    return String(localized: "按名称")
            case .status:  return String(localized: "按状态")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            taskList
        }
        .background(.ultraThinMaterial)
        .frame(width: 750, height: 600)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "下载管理"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                sortMenu

                HStack(spacing: 6) {
                    Button(action: pauseAll) {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: .orange))
                    .help(String(localized: "全部暂停"))

                    Button(action: resumeAll) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: .blue))
                    .help(String(localized: "全部继续"))

                    Button(action: { showClearConfirmation = true }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: .red))
                    .help(String(localized: "清除已完成"))

                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: .secondary))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.5)
        }
        .background(.thinMaterial)
        .alert(String(localized: "确认删除"), isPresented: $showClearConfirmation) {
            Button(String(localized: "取消"), role: .cancel) { }
            Button(String(localized: "确认"), role: .destructive) { clearFinishedTasks() }
        } message: {
            if StorageData.shared.deleteCompletedTasksWithFiles {
                Text("确定要删除所有已完成和失败的下载任务吗？\n\n• 已完成的任务：将删除任务记录和本地文件\n• 失败的任务：将删除任务记录和本地文件")
            } else {
                Text("确定要删除所有已完成和失败的下载任务吗？\n\n• 已完成的任务：仅删除任务记录，保留本地文件\n• 失败的任务：将删除任务记录和本地文件")
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach([SortOrder.addTime, .name, .status], id: \.self) { order in
                Button(action: { sortOrder = order }) {
                    HStack {
                        Text(order.label)
                        if sortOrder == order {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10))
                Text(sortOrder.label)
                    .font(.system(size: 12, weight: .medium))
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

    private var taskList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(sortedTasks) { task in
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
        switch sortOrder {
        case .addTime: return networkManager.downloadTasks
        case .name:    return networkManager.downloadTasks.sorted { $0.displayName < $1.displayName }
        case .status:  return networkManager.downloadTasks.sorted { $0.status.sortOrder < $1.status.sortOrder }
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
            shouldRemoveFiles = true
        } else if case .completed = task.status {
            shouldRemoveFiles = StorageData.shared.deleteCompletedTasksWithFiles
        } else {
            shouldRemoveFiles = true
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

#Preview {
    DownloadManagerView()
}
