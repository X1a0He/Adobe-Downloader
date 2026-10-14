import Foundation
import Compression
import Darwin

final class HDBSPatch {

    static let magic: UInt64 = 0x3034464649445342 // "BSDIF40\0"

    enum PatchError: Error, LocalizedError {
        case invalidMagic
        case invalidHeader
        case decompressFailed(String)
        case patchFailed(String)
        case readFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidMagic: return "Not a valid bsdiff v4.0 patch file"
            case .invalidHeader: return "Invalid patch header"
            case .decompressFailed(let s): return "Decompress failed: \(s)"
            case .patchFailed(let s): return "Patch failed: \(s)"
            case .readFailed(let s): return "Read failed: \(s)"
            case .writeFailed(let s): return "Write failed: \(s)"
            }
        }
    }

    func applyPatch(sourceFile: String, outputFile: String, patchFile: String) throws {
        try HDPIMOperationContext.checkCancellation()
        let patchData = try Data(contentsOf: URL(fileURLWithPath: patchFile))
        if let blocks = try bzip2Blocks(patchData) {
            try applyStreamedPatch(sourceFile: sourceFile, outputFile: outputFile, blocks: blocks)
            return
        }
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourceFile))

        let result = try bsPatchBuffer(
            oldData: sourceData,
            patchData: patchData
        )

        try HDPIMOperationContext.checkCancellation()
        try result.write(to: URL(fileURLWithPath: outputFile))
    }

    private func bzip2Blocks(_ data: Data) throws -> (control: Data, difference: Data, extra: Data, outputSize: Int)? {
        guard data.count >= 32, data.prefix(8) == Data("BSDIFF40".utf8),
              let controlSize = Int(exactly: offtin(data, offset: 8)), controlSize >= 0,
              let differenceSize = Int(exactly: offtin(data, offset: 16)), differenceSize >= 0,
              let outputSize = Int(exactly: offtin(data, offset: 24)), outputSize >= 0,
              controlSize <= data.count - 32,
              differenceSize <= data.count - 32 - controlSize else {
            throw PatchError.invalidHeader
        }
        let differenceStart = 32 + controlSize
        let extraStart = differenceStart + differenceSize
        let control = data.subdata(in: 32..<differenceStart)
        let difference = data.subdata(in: differenceStart..<extraStart)
        let extra = data.subdata(in: extraStart..<data.count)
        guard [control, difference, extra].allSatisfy({ $0.prefix(3) == Data("BZh".utf8) }) else {
            return nil
        }
        return (control, difference, extra, outputSize)
    }

    private func applyStreamedPatch(sourceFile: String, outputFile: String,
                                    blocks: (control: Data, difference: Data, extra: Data, outputSize: Int)) throws {
        let control = try HDPIMBZ2StreamReader(data: blocks.control)
        let difference = try HDPIMBZ2StreamReader(data: blocks.difference)
        let extra = try HDPIMBZ2StreamReader(data: blocks.extra)
        let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourceFile))
        defer { try? source.close() }
        guard let oldSize = Int(exactly: try source.seekToEnd()) else { throw PatchError.invalidHeader }
        let staging = outputFile + ".patch-" + UUID().uuidString
        let fd = open(staging, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw PatchError.writeFailed("\(staging)：\(String(cString: strerror(errno)))") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var published = false
        defer {
            try? output.close()
            if !published {
                do { try FileManager.default.removeItem(atPath: staging) }
                catch { NSLog("[HDBSPatch] 补丁中间文件回收失败：%@：%@", staging, error.localizedDescription) }
            }
        }
        var oldPosition = 0
        var newPosition = 0
        while newPosition < blocks.outputSize {
            try HDPIMOperationContext.checkCancellation()
            let tuple = try readExactly(control, count: 24)
            guard let addCount = Int(exactly: offtin(tuple, offset: 0)), addCount >= 0,
                  let copyCount = Int(exactly: offtin(tuple, offset: 8)), copyCount >= 0,
                  let adjustment = Int(exactly: offtin(tuple, offset: 16)),
                  addCount <= blocks.outputSize - newPosition,
                  copyCount <= blocks.outputSize - newPosition - addCount else {
                throw PatchError.patchFailed("invalid control triple or output overrun")
            }
            let (afterAdd, addOverflow) = oldPosition.addingReportingOverflow(addCount)
            let (afterSeek, seekOverflow) = afterAdd.addingReportingOverflow(adjustment)
            guard !addOverflow, !seekOverflow else { throw PatchError.patchFailed("old position overflow") }
            for offset in stride(from: 0, to: addCount, by: 64 * 1024) {
                try autoreleasepool {
                    try HDPIMOperationContext.checkCancellation()
                    let count = min(64 * 1024, addCount - offset)
                    var chunk = try readExactly(difference, count: count)
                    let oldStart = oldPosition + offset
                    let lower = max(0, oldStart)
                    let upper = min(oldSize, oldStart + count)
                    if upper > lower {
                        try source.seek(toOffset: UInt64(lower))
                        let bytes = try source.read(upToCount: upper - lower) ?? Data()
                        guard bytes.count == upper - lower else { throw PatchError.readFailed(sourceFile) }
                        chunk.withUnsafeMutableBytes { (outputBytes: UnsafeMutableRawBufferPointer) in
                            bytes.withUnsafeBytes { (oldBytes: UnsafeRawBufferPointer) in
                                for index in 0..<bytes.count {
                                    let destination = lower - oldStart + index
                                    outputBytes[destination] = outputBytes[destination] &+ oldBytes[index]
                                }
                            }
                        }
                    }
                    try output.write(contentsOf: chunk)
                }
            }
            for offset in stride(from: 0, to: copyCount, by: 64 * 1024) {
                try autoreleasepool {
                    try HDPIMOperationContext.checkCancellation()
                    try output.write(contentsOf: readExactly(extra, count: min(64 * 1024, copyCount - offset)))
                }
            }
            oldPosition = afterSeek
            newPosition += addCount + copyCount
        }

        for reader in [control, difference, extra] {
            while true {
                try HDPIMOperationContext.checkCancellation()
                let ended = try autoreleasepool { try reader.read(upToLength: 64 * 1024).isEmpty }
                if ended { break }
            }
        }
        try HDPIMOperationContext.checkCancellation()
        try output.close()
        if FileManager.default.fileExists(atPath: outputFile),
           copyfile(outputFile, staging, nil, copyfile_flags_t(COPYFILE_METADATA)) != 0 {
            throw PatchError.writeFailed("复制补丁目标元数据失败：\(String(cString: strerror(errno)))")
        }
        guard rename(staging, outputFile) == 0 else {
            throw PatchError.writeFailed("\(outputFile)：\(String(cString: strerror(errno)))")
        }
        published = true
    }

    private func readExactly(_ reader: HDPIMBZ2StreamReader, count: Int) throws -> Data {
        let data = try reader.read(upToLength: UInt(count))
        guard data.count == count else { throw PatchError.patchFailed("compressed block ended before expected bytes") }
        return data
    }

    func bsPatchBuffer(oldData: Data, patchData: Data) throws -> Data {
        guard patchData.count >= 32 else {
            throw PatchError.invalidHeader
        }

        let magicValue = patchData.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard magicValue == HDBSPatch.magic else {
            throw PatchError.invalidMagic
        }

        let ctrlLen = offtin(patchData, offset: 8)
        let diffLen = offtin(patchData, offset: 16)
        let newSize = offtin(patchData, offset: 24)

        guard let controlSize = Int(exactly: ctrlLen), let differenceSize = Int(exactly: diffLen),
              let outputSize = Int(exactly: newSize), controlSize >= 0, differenceSize >= 0, outputSize >= 0 else {
            throw PatchError.invalidHeader
        }

        guard controlSize <= patchData.count - 32,
              differenceSize <= patchData.count - 32 - controlSize else {
            throw PatchError.invalidHeader
        }

        let ctrlBlockStart = 32
        let diffBlockStart = ctrlBlockStart + controlSize
        let extraBlockStart = diffBlockStart + differenceSize

        let ctrlBlock = try decompressBlock(patchData, offset: ctrlBlockStart, size: controlSize)
        let diffBlock = try decompressBlock(patchData, offset: diffBlockStart, size: differenceSize)
        let extraBlock = try decompressBlock(patchData, offset: extraBlockStart, size: patchData.count - extraBlockStart)

        var newData = Data(count: outputSize)
        var oldPos: Int = 0
        var newPos: Int = 0
        var ctrlPos: Int = 0
        var diffPos: Int = 0
        var extraPos: Int = 0

        while newPos < outputSize {
            try HDPIMOperationContext.checkCancellation()
            guard ctrlPos <= ctrlBlock.count, ctrlBlock.count - ctrlPos >= 24 else {
                throw PatchError.patchFailed("control block ended before output was complete")
            }

            let addLen = offtin(ctrlBlock, offset: ctrlPos)
            let copyLen = offtin(ctrlBlock, offset: ctrlPos + 8)
            let seekAdj = offtin(ctrlBlock, offset: ctrlPos + 16)
            ctrlPos += 24
            guard addLen >= 0, copyLen >= 0,
                  let addCount = Int(exactly: addLen), let copyCount = Int(exactly: copyLen),
                  let seekCount = Int(exactly: seekAdj) else {
                throw PatchError.patchFailed("invalid control triple")
            }

            guard addCount <= outputSize - newPos else {
                throw PatchError.patchFailed("addLen overflow at newPos=\(newPos)")
            }
            guard diffPos <= diffBlock.count, addCount <= diffBlock.count - diffPos else {
                throw PatchError.patchFailed("diffBlock underflow")
            }

            let (nextOldPos, addOverflow) = oldPos.addingReportingOverflow(addCount)
            guard !addOverflow else { throw PatchError.patchFailed("old position overflow") }
            for offset in stride(from: 0, to: addCount, by: 1024 * 1024) {
                try HDPIMOperationContext.checkCancellation()
                let end = offset + min(1024 * 1024, addCount - offset)
                for i in offset..<end {
                    var diffByte = diffBlock[diffPos + i]
                    if oldPos + i >= 0 && oldPos + i < oldData.count {
                        diffByte = diffByte &+ oldData[oldPos + i]
                    }
                    newData[newPos + i] = diffByte
                }
            }

            newPos += addCount
            diffPos += addCount
            oldPos = nextOldPos

            guard copyCount <= outputSize - newPos else {
                throw PatchError.patchFailed("copyLen overflow at newPos=\(newPos)")
            }
            guard extraPos <= extraBlock.count, copyCount <= extraBlock.count - extraPos else {
                throw PatchError.patchFailed("extraBlock underflow")
            }

            newData.replaceSubrange(newPos..<newPos+copyCount, with: extraBlock[extraPos..<extraPos+copyCount])
            newPos += copyCount
            extraPos += copyCount
            let (seekPosition, seekOverflow) = oldPos.addingReportingOverflow(seekCount)
            guard !seekOverflow else { throw PatchError.patchFailed("seek position overflow") }
            oldPos = seekPosition
        }

        return newData
    }

    private func offtin(_ data: Data, offset: Int) -> Int64 {
        data.withUnsafeBytes { buf in
            var value: Int64 = 0
            for i in 0..<8 {
                value |= Int64(buf[offset + i]) << (8 * i)
            }
            let sign = value & (1 << 63)
            if sign != 0 {
                value = -(value & ~(1 << 63))
            }
            return value
        }
    }

    private func offtin(_ data: [UInt8], offset: Int) -> Int64 {
        var value: Int64 = 0
        for i in 0..<8 {
            value |= Int64(data[offset + i]) << (8 * i)
        }
        let sign = value & (1 << 63)
        if sign != 0 {
            value = -(value & ~(1 << 63))
        }
        return value
    }

    private func decompressBlock(_ data: Data, offset: Int, size: Int) throws -> [UInt8] {
        guard size > 0 else { return [] }

        let compressedData = data.subdata(in: offset..<offset+size)

        if compressedData.count >= 3,
           compressedData[compressedData.startIndex] == 0x42,
           compressedData[compressedData.startIndex + 1] == 0x5A,
           compressedData[compressedData.startIndex + 2] == 0x68 {
            if let result = HDPIMBZ2Decompress(compressedData, nil) {
                return [UInt8](result)
            }
            throw PatchError.decompressFailed("bzip2 decode failed at offset \(offset)")
        }

        if let result = try? decompressLZMA(Array(compressedData)) {
            return result
        }

        throw PatchError.decompressFailed("Unknown compression at offset \(offset)")
    }

    private func decompressLZMA(_ input: [UInt8]) throws -> [UInt8] {
        var dynamicSize = input.count * 10
        while dynamicSize < 256 * 1024 * 1024 {
            var buf = [UInt8](repeating: 0, count: dynamicSize)
            let r = input.withUnsafeBufferPointer { inBuf in
                buf.withUnsafeMutableBufferPointer { outBuf in
                    compression_decode_buffer(
                        outBuf.baseAddress!, dynamicSize,
                        inBuf.baseAddress!, input.count,
                        nil,
                        COMPRESSION_LZMA
                    )
                }
            }
            if r > 0 && r < dynamicSize {
                return Array(buf[0..<r])
            }
            dynamicSize *= 2
        }
        throw PatchError.decompressFailed("LZMA decompression failed")
    }
}
