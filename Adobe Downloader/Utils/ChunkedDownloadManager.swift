//
//  Adobe Downloader
//
//  Created by X1a0He on 2025/07/13.
//

import Foundation
import CryptoKit

struct DownloadChunk {
    let index: Int
    let startOffset: Int64
    let endOffset: Int64
    let size: Int64
    var downloadedSize: Int64 = 0
    var isCompleted: Bool = false
    var isPaused: Bool = false
    let expectedHash: String?
    
    var progress: Double {
        return size > 0 ? Double(downloadedSize) / Double(size) : 0.0
    }
    
    init(index: Int, startOffset: Int64, endOffset: Int64, size: Int64, expectedHash: String? = nil) {
        self.index = index
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.size = size
        self.expectedHash = expectedHash
    }
}

struct ChunkedDownloadState: Codable {
    let packageIdentifier: String
    let totalSize: Int64
    let chunkSize: Int64
    let chunks: [ChunkInfo]
    let totalDownloadedSize: Int64
    let isCompleted: Bool
    let destinationURL: String
    let validationInfo: ValidationInfo?
    
    struct ChunkInfo: Codable {
        let index: Int
        let startOffset: Int64
        let endOffset: Int64
        let size: Int64
        let downloadedSize: Int64
        let isCompleted: Bool
        let isPaused: Bool
        let expectedHash: String?
    }
}

extension ValidationInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case segmentSize, version, algorithm, segmentCount, lastSegmentSize, packageHashKey, segments
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segmentSize, forKey: .segmentSize)
        try container.encode(version, forKey: .version)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(segmentCount, forKey: .segmentCount)
        try container.encode(lastSegmentSize, forKey: .lastSegmentSize)
        try container.encode(packageHashKey, forKey: .packageHashKey)
        try container.encode(segments, forKey: .segments)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentSize = try container.decode(Int64.self, forKey: .segmentSize)
        version = try container.decode(String.self, forKey: .version)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        segmentCount = try container.decode(Int.self, forKey: .segmentCount)
        lastSegmentSize = try container.decode(Int64.self, forKey: .lastSegmentSize)
        packageHashKey = try container.decode(String.self, forKey: .packageHashKey)
        segments = try container.decode([SegmentInfo].self, forKey: .segments)
    }
}

extension ValidationInfo.SegmentInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case segmentNumber, hash
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segmentNumber, forKey: .segmentNumber)
        try container.encode(hash, forKey: .hash)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segmentNumber = try container.decode(Int.self, forKey: .segmentNumber)
        hash = try container.decode(String.self, forKey: .hash)
    }
}

class ChunkedDownloadManager: @unchecked Sendable {
    static let shared = ChunkedDownloadManager()

    private var chunkSize: Int64 {
        return Int64(StorageData.shared.chunkSizeMB) * 1024 * 1024
    }

    private let fileManager = FileManager.default
    private var stateDirectory: URL

    private var maxConcurrentChunks: Int {
        return StorageData.shared.maxConcurrentDownloads
    }

    private var activeTasks: [String: Task<Void, Error>] = [:]

    private let taskQueue = DispatchQueue(label: "com.x1a0he.macOS.Adobe-Downloader.chunkDownloadTasks", attributes: .concurrent)

    private let deadConnectionDetector = DeadConnectionDetector()
    
    private func setActiveTask(packageIdentifier: String, task: Task<Void, Error>) async {
        await withCheckedContinuation { continuation in
            taskQueue.async(flags: .barrier) { [weak self] in
                self?.activeTasks[packageIdentifier] = task
                continuation.resume()
            }
        }
    }
    
    private func removeActiveTask(packageIdentifier: String) async {
        await withCheckedContinuation { continuation in
            taskQueue.async(flags: .barrier) { [weak self] in
                self?.activeTasks.removeValue(forKey: packageIdentifier)
                continuation.resume()
            }
        }
    }
    
    private init() {
        let containerURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        stateDirectory = containerURL.appendingPathComponent("Adobe Downloader/chunkStates", isDirectory: true)
        try? fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    func checkRangeSupport(url: URL, headers: [String: String] = [:]) async throws -> (supportsRange: Bool, totalSize: Int64, etag: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode, "HEAD request failed")
        }
        
        let acceptsRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        let contentLength = Int64(httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")

        return (acceptsRanges, contentLength, etag)
    }

    func createChunkedDownload(packageIdentifier: String, totalSize: Int64, destinationURL: URL, validationInfo: ValidationInfo? = nil) -> [DownloadChunk] {
        if let validationInfo = validationInfo {
            var chunks: [DownloadChunk] = []
            
            for segment in validationInfo.segments {
                let segmentIndex = segment.segmentNumber - 1
                let startOffset = Int64(segmentIndex) * validationInfo.segmentSize
                let isLastSegment = segment.segmentNumber == validationInfo.segmentCount
                let segmentSize = isLastSegment ? validationInfo.lastSegmentSize : validationInfo.segmentSize
                let endOffset = startOffset + segmentSize - 1
                
                chunks.append(DownloadChunk(
                    index: segmentIndex,
                    startOffset: startOffset,
                    endOffset: endOffset,
                    size: segmentSize,
                    expectedHash: segment.hash
                ))
            }
            
            return chunks.sorted { $0.index < $1.index }
        } else {
            let standardChunkSize: Int64 = 2 * 1024 * 1024
            let numChunks = Int(ceil(Double(totalSize) / Double(standardChunkSize)))
            var chunks: [DownloadChunk] = []
            
            for i in 0..<numChunks {
                let startOffset = Int64(i) * standardChunkSize
                let isLastChunk = (i == numChunks - 1)
                let chunkSize = isLastChunk ? (totalSize - startOffset) : standardChunkSize
                let endOffset = startOffset + chunkSize - 1
                
                chunks.append(DownloadChunk(
                    index: i,
                    startOffset: startOffset,
                    endOffset: endOffset,
                    size: chunkSize
                ))
            }

            return chunks
        }
    }

    private func validateChunkHash(data: Data, expectedHash: String, algorithm: String = "md5") -> Bool {
        let hashString: String
        switch algorithm.lowercased() {
        case "sha256", "sha-256":
            let hash = SHA256.hash(data: data)
            hashString = hash.map { String(format: "%02hhx", $0) }.joined()
        case "sha1", "sha-1":
            let hash = Insecure.SHA1.hash(data: data)
            hashString = hash.map { String(format: "%02hhx", $0) }.joined()
        default: // md5
            let hash = Insecure.MD5.hash(data: data)
            hashString = hash.map { String(format: "%02hhx", $0) }.joined()
        }
        return hashString.lowercased() == expectedHash.lowercased()
    }
    
    private func validateCompleteChunkFromFile(destinationURL: URL, chunk: DownloadChunk, algorithm: String = "md5") -> Bool {
        guard let expectedHash = chunk.expectedHash else {
            return true
        }

        do {
            let fileHandle = try FileHandle(forReadingFrom: destinationURL)
            defer { fileHandle.closeFile() }

            fileHandle.seek(toFileOffset: UInt64(chunk.startOffset))
            let chunkData = fileHandle.readData(ofLength: Int(chunk.size))

            return validateChunkHash(data: chunkData, expectedHash: expectedHash, algorithm: algorithm)
        } catch {
            return false
        }
    }
    
    private func writeDataToFile(data: Data, destinationURL: URL, offset: Int64, totalSize: Int64? = nil) async throws {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    guard let self = self else {
                        continuation.resume(throwing: NSError(domain: "ChunkedDownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Manager deallocated"]))
                        return
                    }
                    let directory = destinationURL.deletingLastPathComponent()
                    if !self.fileManager.fileExists(atPath: directory.path) {
                        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    }

                    let fileHandle: FileHandle
                    if !self.fileManager.fileExists(atPath: destinationURL.path) {
                        let success = self.fileManager.createFile(atPath: destinationURL.path, contents: nil)
                        if !success {
                            throw NetworkError.filePermissionDenied(destinationURL.path)
                        }
                        fileHandle = try FileHandle(forWritingTo: destinationURL)
                    } else {
                        fileHandle = try FileHandle(forWritingTo: destinationURL)
                    }
                    
                    defer { fileHandle.closeFile() }

                    fileHandle.seek(toFileOffset: UInt64(offset))
                    fileHandle.write(data)

                    fileHandle.synchronizeFile()
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func downloadChunkToFile(
        chunk: DownloadChunk,
        url: URL,
        destinationURL: URL,
        headers: [String: String] = [:],
        progressHandler: ((Int64, Int64) -> Void)? = nil,
        cancellationHandler: (() async -> Bool)? = nil
    ) async throws -> DownloadChunk {
        
        var modifiedChunk = chunk

        if let cancellationHandler = cancellationHandler {
            if await cancellationHandler() {
                modifiedChunk.isPaused = true
                throw NetworkError.cancelled
            }
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            if chunk.expectedHash != nil {
                if validateCompleteChunkFromFile(destinationURL: destinationURL, chunk: chunk) {
                    modifiedChunk.downloadedSize = chunk.size
                    modifiedChunk.isCompleted = true
                    return modifiedChunk
                }
                modifiedChunk.downloadedSize = 0
            } else {
                let existingSize = (try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                if existingSize > chunk.endOffset {
                    if let fileHandle = try? FileHandle(forReadingFrom: destinationURL) {
                        defer { fileHandle.closeFile() }
                        fileHandle.seek(toFileOffset: UInt64(chunk.startOffset))
                        let data = fileHandle.readData(ofLength: Int(chunk.size))

                        if !data.allSatisfy({ $0 == 0 }) {
                            modifiedChunk.downloadedSize = chunk.size
                            modifiedChunk.isCompleted = true
                            return modifiedChunk
                        }
                    }
                }
            }
        }

        if modifiedChunk.downloadedSize >= chunk.size {
            modifiedChunk.isCompleted = true
            return modifiedChunk
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        
        let actualStartOffset = chunk.startOffset + modifiedChunk.downloadedSize
        request.setValue("bytes=\(actualStartOffset)-\(chunk.endOffset)", forHTTPHeaderField: "Range")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }


        return try await withTaskCancellationHandler(operation: {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            try Task.checkCancellation()
            if let cancellationHandler = cancellationHandler {
                if await cancellationHandler() {
                    modifiedChunk.isPaused = true
                    throw NetworkError.cancelled
                }
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }
            
            if httpResponse.statusCode == 206 || httpResponse.statusCode == 200 {
                let isFullResponse = httpResponse.statusCode == 200 &&
                    (chunk.startOffset > 0 || Int64(data.count) > chunk.size * 2)

                if isFullResponse {
                    try await writeDataToFile(data: data, destinationURL: destinationURL, offset: 0, totalSize: Int64(data.count))
                    modifiedChunk.downloadedSize = chunk.size
                    modifiedChunk.isCompleted = true
                } else {
                    try await writeDataToFile(data: data, destinationURL: destinationURL, offset: actualStartOffset, totalSize: nil)

                    modifiedChunk.downloadedSize += Int64(data.count)
                }
                
                progressHandler?(modifiedChunk.downloadedSize, chunk.size)
                
            } else {
                throw NetworkError.httpError(httpResponse.statusCode, "分片下载失败")
            }
            
            return modifiedChunk
        }, onCancel: {})
    }

    func pauseDownload(packageIdentifier: String) {
        Task {
            await withCheckedContinuation { [weak self] continuation in
                self?.taskQueue.async(flags: .barrier) { [weak self] in
                    if let task = self?.activeTasks[packageIdentifier] {
                        task.cancel()
                        self?.activeTasks.removeValue(forKey: packageIdentifier)
                    }
                    continuation.resume()
                }
            }
        }
    }

    func cancelDownload(packageIdentifier: String) {
        Task {
            await withCheckedContinuation { [weak self] continuation in
                self?.taskQueue.async(flags: .barrier) { [weak self] in
                    if let task = self?.activeTasks[packageIdentifier] {
                        task.cancel()
                        self?.activeTasks.removeValue(forKey: packageIdentifier)
                    }
                    continuation.resume()
                }
            }
        }
        
        clearChunkedDownloadState(packageIdentifier: packageIdentifier)
    }

    func saveChunkedDownloadState(packageIdentifier: String, chunks: [DownloadChunk], totalSize: Int64, destinationURL: URL, validationInfo: ValidationInfo? = nil) {
        let chunkInfos = chunks.map { chunk in
            ChunkedDownloadState.ChunkInfo(
                index: chunk.index,
                startOffset: chunk.startOffset,
                endOffset: chunk.endOffset,
                size: chunk.size,
                downloadedSize: chunk.downloadedSize,
                isCompleted: chunk.isCompleted,
                isPaused: chunk.isPaused,
                expectedHash: chunk.expectedHash
            )
        }
        
        let state = ChunkedDownloadState(
            packageIdentifier: packageIdentifier,
            totalSize: totalSize,
            chunkSize: validationInfo?.segmentSize ?? self.chunkSize,
            chunks: chunkInfos,
            totalDownloadedSize: chunks.reduce(0) { $0 + $1.downloadedSize },
            isCompleted: chunks.allSatisfy { $0.isCompleted },
            destinationURL: destinationURL.path,
            validationInfo: validationInfo
        )
        
        let fileName = "\(packageIdentifier.replacingOccurrences(of: "/", with: "_")).chunkstate"
        let fileURL = stateDirectory.appendingPathComponent(fileName)
        
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL)
        } catch {
        }
    }
    
    func loadChunkedDownloadState(packageIdentifier: String) -> ChunkedDownloadState? {
        let fileName = "\(packageIdentifier.replacingOccurrences(of: "/", with: "_")).chunkstate"
        let fileURL = stateDirectory.appendingPathComponent(fileName)
        
        do {
            let data = try Data(contentsOf: fileURL)
            let state = try JSONDecoder().decode(ChunkedDownloadState.self, from: data)
            return state
        } catch {
            return nil
        }
    }
    
    func restoreChunksFromState(_ state: ChunkedDownloadState) -> [DownloadChunk] {
        return state.chunks.map { chunkInfo in
            DownloadChunk(
                index: chunkInfo.index,
                startOffset: chunkInfo.startOffset,
                endOffset: chunkInfo.endOffset,
                size: chunkInfo.size,
                expectedHash: chunkInfo.expectedHash
            )
        }.map { chunk in
            var restoredChunk = chunk
            if let chunkInfo = state.chunks.first(where: { $0.index == chunk.index }) {
                restoredChunk.downloadedSize = chunkInfo.downloadedSize
                restoredChunk.isCompleted = chunkInfo.isCompleted
                restoredChunk.isPaused = chunkInfo.isPaused
            }
            return restoredChunk
        }
    }
    
    func clearChunkedDownloadState(packageIdentifier: String) {
        let fileName = "\(packageIdentifier.replacingOccurrences(of: "/", with: "_")).chunkstate"
        let fileURL = stateDirectory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: fileURL)
    }

    private func fetchValidationInfo(from validationURL: String) async throws -> ValidationInfo? {
        let fullURL: String
        if validationURL.hasPrefix("http://") || validationURL.hasPrefix("https://") {
            fullURL = validationURL
        } else {
            let cleanCdn = globalCdn.hasSuffix("/") ? String(globalCdn.dropLast()) : globalCdn
            let cleanPath = validationURL.hasPrefix("/") ? validationURL : "/\(validationURL)"
            fullURL = cleanCdn + cleanPath
        }

        guard let url = URL(string: fullURL) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        guard let xmlString = String(data: data, encoding: .utf8) else {
            return nil
        }

        return ValidationInfo.parse(from: xmlString)
    }

    func downloadFileWithChunks(
        packageIdentifier: String,
        url: URL,
        destinationURL: URL,
        headers: [String: String] = [:],
        validationURL: String? = nil,
        progressHandler: ((Double, Int64, Int64, Double) -> Void)? = nil,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)? = nil,
        cancellationHandler: (() async -> Bool)? = nil
    ) async throws {
        let downloadTask = Task<Void, Error> {
            let (supportsRange, totalSize, _) = try await checkRangeSupport(url: url, headers: headers)
            
            guard totalSize > 0 else {
                throw NetworkError.invalidData("无法获取文件大小")
            }

            try await ensureFilePreallocated(destinationURL: destinationURL, totalSize: totalSize)

            var validationInfo: ValidationInfo? = nil
            if let validationURL = validationURL {
                do {
                    validationInfo = try await fetchValidationInfo(from: validationURL)
                } catch {
                    print("获取ValidationInfo失败: \(error), 降级到自定义分片")
                }
            }

            var chunks: [DownloadChunk]
            if let savedState = loadChunkedDownloadState(packageIdentifier: packageIdentifier) {
                let currentChunkSize = validationInfo?.segmentSize ?? self.chunkSize
                if savedState.totalSize == totalSize,
                   savedState.destinationURL == destinationURL.path,
                   savedState.packageIdentifier == packageIdentifier,
                   savedState.chunkSize == currentChunkSize {
                    chunks = restoreChunksFromState(savedState).map { chunk in
                        var restoredChunk = chunk
                        restoredChunk.isPaused = false
                        return restoredChunk
                    }
                } else {
                    clearChunkedDownloadState(packageIdentifier: packageIdentifier)

                    if supportsRange && (validationInfo != nil || totalSize > chunkSize) {
                        chunks = createChunkedDownload(
                            packageIdentifier: packageIdentifier,
                            totalSize: totalSize,
                            destinationURL: destinationURL,
                            validationInfo: validationInfo
                        )
                    } else {
                        chunks = [DownloadChunk(
                            index: 0,
                            startOffset: 0,
                            endOffset: totalSize - 1,
                            size: totalSize
                        )]
                    }
                }
            } else {
                if supportsRange && (validationInfo != nil || totalSize > chunkSize) {
                    chunks = createChunkedDownload(
                        packageIdentifier: packageIdentifier,
                        totalSize: totalSize,
                        destinationURL: destinationURL,
                        validationInfo: validationInfo
                    )
                } else {
                    chunks = [DownloadChunk(
                        index: 0,
                        startOffset: 0,
                        endOffset: totalSize - 1,
                        size: totalSize
                    )]
                }
            }

            let incompleteChunks = chunks.filter { chunk in
                if chunk.isPaused {
                    return false
                }

                if chunk.isCompleted {
                    return false
                }

                if chunk.downloadedSize >= chunk.size {
                    return false
                }

                if chunk.expectedHash != nil &&
                   fileManager.fileExists(atPath: destinationURL.path) {
                    if validateCompleteChunkFromFile(destinationURL: destinationURL, chunk: chunk) {
                        return false
                    }
                }
                
                return true
            }
            
            if incompleteChunks.isEmpty {
                clearChunkedDownloadState(packageIdentifier: packageIdentifier)
                return
            }

            try await downloadChunksSequentially(
                chunks: incompleteChunks,
                url: url,
                destinationURL: destinationURL,
                headers: headers,
                progressHandler: progressHandler,
                rangeAvailabilityHandler: rangeAvailabilityHandler,
                cancellationHandler: cancellationHandler,
                packageIdentifier: packageIdentifier,
                totalSize: totalSize,
                validationInfo: validationInfo
            )

            if let validationInfo = validationInfo {
                do {
                    try await validateCompleteFile(destinationURL: destinationURL, validationInfo: validationInfo, totalSize: totalSize)
                } catch {
                }
            }

            clearChunkedDownloadState(packageIdentifier: packageIdentifier)
        }

        await setActiveTask(packageIdentifier: packageIdentifier, task: downloadTask)
        
        defer {
            Task {
                await removeActiveTask(packageIdentifier: packageIdentifier)
            }
        }

        try await downloadTask.value
    }

    private func downloadChunksSequentially(
        chunks: [DownloadChunk],
        url: URL,
        destinationURL: URL,
        headers: [String: String],
        progressHandler: ((Double, Int64, Int64, Double) -> Void)?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)?,
        cancellationHandler: (() async -> Bool)?,
        packageIdentifier: String,
        totalSize: Int64,
        validationInfo: ValidationInfo?
    ) async throws {
        let sortedChunks = chunks.sorted { $0.index < $1.index }
        
        actor SpeedTracker {
            private var lastProgressTime = Date()
            private var lastDownloadedSize: Int64 = 0
            
            func updateSpeed(currentDownloaded: Int64) -> Double {
                let now = Date()
                let timeDiff = now.timeIntervalSince(lastProgressTime)
                
                if timeDiff >= 0.5 {
                    let sizeDiff = currentDownloaded - lastDownloadedSize
                    let speed = timeDiff > 0 ? Double(sizeDiff) / timeDiff : 0
                    
                    lastProgressTime = now
                    lastDownloadedSize = currentDownloaded
                    
                    return speed
                }
                return 0
            }
            
            func initialize(initialSize: Int64) {
                lastDownloadedSize = initialSize
                lastProgressTime = Date()
            }
        }

        actor ChunkStateManager {
            private var chunks: [DownloadChunk]
            
            init(chunks: [DownloadChunk]) {
                self.chunks = chunks
            }
            
            func updateChunkProgress(index: Int, downloadedSize: Int64, isCompleted: Bool = false) {
                if let chunkIndex = chunks.firstIndex(where: { $0.index == index }) {
                    chunks[chunkIndex].downloadedSize = downloadedSize
                    if isCompleted {
                        chunks[chunkIndex].isCompleted = true
                    }
                }
            }
            
            func updateChunk(_ updatedChunk: DownloadChunk) {
                if let index = chunks.firstIndex(where: { $0.index == updatedChunk.index }) {
                    chunks[index] = updatedChunk
                }
            }
            
            func getAllChunks() -> [DownloadChunk] {
                return chunks
            }
            
            func getTotalDownloadedSize() -> Int64 {
                return chunks.reduce(Int64(0)) { $0 + $1.downloadedSize }
            }
        }
        
        let speedTracker = SpeedTracker()
        await speedTracker.initialize(initialSize: chunks.reduce(Int64(0)) { $0 + $1.downloadedSize })
        
        let chunkStateManager = ChunkStateManager(chunks: chunks)
        
        let initialChunks = await chunkStateManager.getAllChunks()
        saveChunkedDownloadState(packageIdentifier: packageIdentifier, chunks: initialChunks, totalSize: totalSize, destinationURL: destinationURL, validationInfo: validationInfo)

        for chunk in sortedChunks {
            if let cancellationHandler = cancellationHandler {
                if await cancellationHandler() {
                    throw NetworkError.cancelled
                }
            }
            
            let completedChunk = try await downloadChunkToFile(
                chunk: chunk,
                url: url,
                destinationURL: destinationURL,
                headers: headers,
                progressHandler: { downloaded, total in
                    Task {
                        await chunkStateManager.updateChunkProgress(
                            index: chunk.index,
                            downloadedSize: downloaded,
                            isCompleted: downloaded >= total
                        )
                        
                        let currentTotalDownloaded = await chunkStateManager.getTotalDownloadedSize()
                        let progress = Double(currentTotalDownloaded) / Double(totalSize)
                        
                        let speed = await speedTracker.updateSpeed(currentDownloaded: currentTotalDownloaded)
                        if speed > 0 {
                            progressHandler?(progress, currentTotalDownloaded, totalSize, speed)
                        }
                    }
                },
                cancellationHandler: cancellationHandler
            )
            
            await chunkStateManager.updateChunk(completedChunk)
            
            let currentChunks = await chunkStateManager.getAllChunks()
            saveChunkedDownloadState(packageIdentifier: packageIdentifier, chunks: currentChunks, totalSize: totalSize, destinationURL: destinationURL, validationInfo: validationInfo)
            let upperBound = contiguousUpperBound(for: currentChunks)
            rangeAvailabilityHandler?(upperBound, upperBound >= totalSize - 1)
        }
    }

    private func contiguousUpperBound(for chunks: [DownloadChunk]) -> Int64 {
        let sortedChunks = chunks.sorted { $0.startOffset < $1.startOffset }
        var upperBound: Int64 = -1

        for chunk in sortedChunks {
            guard chunk.isCompleted, chunk.startOffset <= upperBound + 1 else {
                break
            }
            upperBound = max(upperBound, chunk.endOffset)
        }

        return upperBound
    }
    
    private func validateCompleteFile(destinationURL: URL, validationInfo: ValidationInfo, totalSize: Int64) async throws {
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            if let fileSize = fileAttributes[.size] as? Int64, fileSize != totalSize {
                throw NetworkError.invalidData("文件大小不匹配: 期望\(totalSize), 实际\(fileSize)")
            }
        } catch {
            throw NetworkError.invalidData("无法获取文件大小: \(error.localizedDescription)")
        }

        let fileHandle = try FileHandle(forReadingFrom: destinationURL)
        defer { fileHandle.closeFile() }
        
        for segment in validationInfo.segments {
            let segmentIndex = segment.segmentNumber - 1
            let startOffset = Int64(segmentIndex) * validationInfo.segmentSize
            let isLastSegment = segment.segmentNumber == validationInfo.segmentCount
            let segmentSize = isLastSegment ? validationInfo.lastSegmentSize : validationInfo.segmentSize
            
            fileHandle.seek(toFileOffset: UInt64(startOffset))
            let segmentData = fileHandle.readData(ofLength: Int(segmentSize))
            
            if segmentData.count != Int(segmentSize) {
                throw NetworkError.invalidData("分片\(segment.segmentNumber)大小不正确: 期望\(segmentSize), 实际\(segmentData.count)")
            }
            
            if !validateChunkHash(data: segmentData, expectedHash: segment.hash) {
                throw NetworkError.invalidData("分片\(segment.segmentNumber)哈希校验失败")
            }
        }
    }
    
    private func ensureFilePreallocated(destinationURL: URL, totalSize: Int64) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let directory = destinationURL.deletingLastPathComponent()
                    if !self.fileManager.fileExists(atPath: directory.path) {
                        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    }

                    if self.fileManager.fileExists(atPath: destinationURL.path) {
                        if let attributes = try? self.fileManager.attributesOfItem(atPath: destinationURL.path),
                           let existingSize = attributes[.size] as? Int64 {
                            if existingSize == totalSize {
                                continuation.resume()
                                return
                            } else if existingSize > totalSize {
                                try? self.fileManager.removeItem(at: destinationURL)
                            }
                        }
                    }

                    let success = self.fileManager.createFile(atPath: destinationURL.path, contents: nil)
                    if !success {
                        throw NetworkError.filePermissionDenied(destinationURL.path)
                    }
                    
                    let fileHandle = try FileHandle(forWritingTo: destinationURL)
                    defer { fileHandle.closeFile() }

                    if ftruncate(fileHandle.fileDescriptor, off_t(totalSize)) != 0 {
                        fileHandle.seek(toFileOffset: UInt64(totalSize - 1))
                        fileHandle.write(Data([0]))
                    }
                    
                    fileHandle.synchronizeFile()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
