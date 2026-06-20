import Foundation
import Compression

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
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourceFile))
        let patchData = try Data(contentsOf: URL(fileURLWithPath: patchFile))

        let result = try bsPatchBuffer(
            oldData: sourceData,
            patchData: patchData
        )

        try result.write(to: URL(fileURLWithPath: outputFile))
    }

    func bsPatchBuffer(oldData: Data, patchData: Data) throws -> Data {
        guard patchData.count >= 32 else {
            throw PatchError.invalidHeader
        }

        let magicValue = patchData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
        guard magicValue == HDBSPatch.magic else {
            throw PatchError.invalidMagic
        }

        let ctrlLen = offtin(patchData, offset: 8)
        let diffLen = offtin(patchData, offset: 16)
        let newSize = offtin(patchData, offset: 24)

        guard ctrlLen >= 0, diffLen >= 0, newSize >= 0 else {
            throw PatchError.invalidHeader
        }

        guard Int(ctrlLen) + Int(diffLen) + 32 < patchData.count else {
            throw PatchError.invalidHeader
        }

        let ctrlBlockStart = 32
        let diffBlockStart = ctrlBlockStart + Int(ctrlLen)
        let extraBlockStart = diffBlockStart + Int(diffLen)

        let ctrlBlock = try decompressBlock(patchData, offset: ctrlBlockStart, size: Int(ctrlLen))
        let diffBlock = try decompressBlock(patchData, offset: diffBlockStart, size: Int(diffLen))
        let extraBlock = try decompressBlock(patchData, offset: extraBlockStart, size: patchData.count - extraBlockStart)

        var newData = Data(count: Int(newSize))
        var oldPos: Int = 0
        var newPos: Int = 0
        var ctrlPos: Int = 0
        var diffPos: Int = 0
        var extraPos: Int = 0

        while newPos < Int(newSize) {
            guard ctrlPos + 24 <= ctrlBlock.count else { break }

            let addLen = offtin(ctrlBlock, offset: ctrlPos)
            let copyLen = offtin(ctrlBlock, offset: ctrlPos + 8)
            let seekAdj = offtin(ctrlBlock, offset: ctrlPos + 16)
            ctrlPos += 24

            guard newPos + Int(addLen) <= Int(newSize) else {
                throw PatchError.patchFailed("addLen overflow at newPos=\(newPos)")
            }
            guard diffPos + Int(addLen) <= diffBlock.count else {
                throw PatchError.patchFailed("diffBlock underflow")
            }

            for i in 0..<Int(addLen) {
                var diffByte = diffBlock[diffPos + i]
                if oldPos + i >= 0 && oldPos + i < oldData.count {
                    diffByte = diffByte &+ oldData[oldPos + i]
                }
                newData[newPos + i] = diffByte
            }

            newPos += Int(addLen)
            diffPos += Int(addLen)
            oldPos += Int(addLen)

            guard newPos + Int(copyLen) <= Int(newSize) else {
                throw PatchError.patchFailed("copyLen overflow at newPos=\(newPos)")
            }
            guard extraPos + Int(copyLen) <= extraBlock.count else {
                throw PatchError.patchFailed("extraBlock underflow")
            }

            newData.replaceSubrange(newPos..<newPos+Int(copyLen), with: extraBlock[extraPos..<extraPos+Int(copyLen)])
            newPos += Int(copyLen)
            extraPos += Int(copyLen)
            oldPos += Int(seekAdj)
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
