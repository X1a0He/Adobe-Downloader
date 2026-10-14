//
//  UninstallPIMXGenerator.swift
//  Adobe Downloader
//

import Foundation
import CryptoKit

class UninstallPIMXGenerator {

    private var reverseCommands: [String] = []

    func addReverseCommand(_ xml: String) {
        reverseCommands.append(xml)
    }

    func addReverseCommands(_ xmlFragments: [String]) {
        reverseCommands.append(contentsOf: xmlFragments)
    }

    func generate() -> String {
        let commandsXML: String
        if reverseCommands.isEmpty {
            commandsXML = "<Commands></Commands>"
        } else {
            commandsXML = "<Commands>" + reverseCommands.joined(separator: "\n        ") + "</Commands>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Package>
            \(commandsXML)
        </Package>
        """
    }

    func writeAndHash(
        to directory: URL,
        fileName: String = "UninstallPIMX.xml"
    ) throws -> (path: URL, sha1: String, sha256: String) {
        let xml = generate()
        let xmlData = Data(xml.utf8)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filePath = directory.appendingPathComponent(fileName)
        try xmlData.write(to: filePath, options: .atomic)
        let publishedData = try Data(contentsOf: filePath)
        guard publishedData == xmlData else {
            throw HDPIMMaterialError.invalid("材料写入后回读不一致：\(filePath.path)")
        }

        let sha1 = Insecure.SHA1.hash(data: publishedData)
            .map { String(format: "%02X", $0) }.joined()
        let sha256 = SHA256.hash(data: publishedData)
            .map { String(format: "%02X", $0) }.joined()

        return (path: filePath, sha1: sha1, sha256: sha256)
    }

    var hasCommands: Bool {
        !reverseCommands.isEmpty
    }

    func reset() {
        reverseCommands.removeAll()
    }
}
