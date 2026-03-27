//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import Foundation

actor CancelTracker {
    private var cancelledIds: Set<UUID> = []
    private var pausedIds: Set<UUID> = []

    // 兼容旧的 URLSession 下载路径 APRO不支持分包是什么b逻辑
    var downloadTasks: [UUID: URLSessionDownloadTask] = [:]
    private var sessions: [UUID: URLSession] = [:]

    func registerTask(_ id: UUID, task: URLSessionDownloadTask, session: URLSession, packageIdentifier: String = "", hasReceivedFirstData: AsyncFlag? = nil) {
        downloadTasks[id] = task
        sessions[id] = session
    }

    func cancel(_ id: UUID) {
        cancelledIds.insert(id)
        pausedIds.remove(id)
        if let task = downloadTasks[id] {
            task.cancel()
            downloadTasks.removeValue(forKey: id)
        }
        if let session = sessions[id] {
            session.invalidateAndCancel()
            sessions.removeValue(forKey: id)
        }
    }

    func pause(_ id: UUID) {
        if !cancelledIds.contains(id) {
            pausedIds.insert(id)
        }
    }

    func resume(_ id: UUID) {
        pausedIds.remove(id)
    }

    func isCancelled(_ id: UUID) -> Bool {
        cancelledIds.contains(id)
    }

    func isPaused(_ id: UUID) -> Bool {
        pausedIds.contains(id)
    }

    func reset(_ id: UUID) {
        cancelledIds.remove(id)
        pausedIds.remove(id)
    }
}
