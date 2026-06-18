//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import Foundation

actor CancelTracker {
    private var cancelledIds: Set<UUID> = []
    private var pausedIds: Set<UUID> = []

    func cancel(_ id: UUID) {
        cancelledIds.insert(id)
        pausedIds.remove(id)
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
