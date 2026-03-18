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

    func generate(packageName: String) -> String {
        let commandsXML = reverseCommands
            .map { "    \($0)" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Package>
          <PackageName>\(packageName)</PackageName>
          <Commands>
        \(commandsXML)
          </Commands>
        </Package>
        """
    }

    func writeAndHash(to directory: URL, packageName: String) throws -> (path: URL, sha1: String, sha256: String) {
        let xml = generate(packageName: packageName)
        let xmlData = Data(xml.utf8)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filePath = directory.appendingPathComponent("UninstallPIMX.xml")
        try xmlData.write(to: filePath)

        let sha1 = Insecure.SHA1.hash(data: xmlData)
            .map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: xmlData)
            .map { String(format: "%02x", $0) }.joined()

        return (path: filePath, sha1: sha1, sha256: sha256)
    }

    var hasCommands: Bool {
        !reverseCommands.isEmpty
    }

    func reset() {
        reverseCommands.removeAll()
    }
}
