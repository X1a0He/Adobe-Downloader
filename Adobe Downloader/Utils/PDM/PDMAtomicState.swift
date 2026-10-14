//
//  PDMAtomicState.swift
//  Adobe Downloader
//

import Foundation

final class PDMAtomicState {
    private let lock = NSLock()
    private var _state: PDMDownloadState

    init(_ initial: PDMDownloadState = .idle) {
        _state = initial
    }

    var current: PDMDownloadState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    func set(_ newState: PDMDownloadState) {
        lock.lock()
        defer { lock.unlock() }
        _state = newState
    }

    @discardableResult
    func requestStop(_ newState: PDMDownloadState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard newState == .paused || newState == .cancelled,
              _state != .completed, _state != .error, _state != .cancelled else { return false }
        _state = newState
        return true
    }

    @discardableResult
    func compareAndSet(expected: PDMDownloadState, new newState: PDMDownloadState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _state == expected {
            _state = newState
            return true
        }
        return false
    }
}
