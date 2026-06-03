//
//  HDPIMActionFactory.swift
//  Adobe Downloader
//
//  Based on IDA analysis of ActionFactory::create
//

import Foundation

protocol HDPIMAction {
    func initialize(from xmlString: String) -> Bool
    func execute() -> Bool
}

class HDPIMExtractAction: HDPIMAction {
    private var sourcePath: String = ""
    private var targetPath: String = ""

    func initialize(from xmlString: String) -> Bool {
        guard let sourceRange = xmlString.range(of: "(?<=<source>).*?(?=</source>)", options: .regularExpression),
              let targetRange = xmlString.range(of: "(?<=<target>).*?(?=</target>)", options: .regularExpression) else {
            return false
        }

        sourcePath = String(xmlString[sourceRange])
        targetPath = String(xmlString[targetRange])
        return !sourcePath.isEmpty && !targetPath.isEmpty
    }

    func execute() -> Bool {
        return false
    }
}

class HDPIMActionFactory {
    static func create(from xmlString: String) -> HDPIMAction? {
        guard let nameRange = xmlString.range(of: "(?<=<name>).*?(?=</name>)", options: .regularExpression) else {
            return nil
        }

        let actionName = String(xmlString[nameRange])

        guard actionName == "extract" else {
            return nil
        }

        let action = HDPIMExtractAction()
        guard action.initialize(from: xmlString) else {
            return nil
        }

        return action
    }
}
