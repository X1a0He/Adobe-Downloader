import Foundation

enum HDPIMNativeLZMA2Error: Error, LocalizedError {
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let message):
            return message
        }
    }
}

enum HDPIMNativeLZMA2 {
    static func decompress(data: Data) throws -> Data {
        var nsError: NSError?
        guard let output = HDPIMLZMA2Decompress(data, &nsError) else {
            throw HDPIMNativeLZMA2Error.decodeFailed(nsError?.localizedDescription ?? "原生 LZMA2 解码失败")
        }
        return output
    }
}

final class HDPIMNativeLZMA2StreamDecoder {
    private let decoder: HDPIMLZMA2StreamDecoder

    init(dictionaryByte: UInt8) throws {
        self.decoder = try HDPIMLZMA2StreamDecoder(dictionaryByte: dictionaryByte)
    }

    func process(chunk: Data, finish: Bool) throws -> Data {
        try decoder.processChunk(chunk, finish: finish)
    }
}
