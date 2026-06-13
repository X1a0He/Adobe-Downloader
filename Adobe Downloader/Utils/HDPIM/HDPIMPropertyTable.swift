//
//  HDPIMPropertyTable.swift
//  Adobe Downloader
//

import Foundation

class HDPIMPropertyTable {

    private var properties: [String: String] = [:]

    func setProperty(_ key: String, _ value: String) {
        properties[key.lowercased()] = value
    }

    func getProperty(_ key: String) -> String? {
        properties[key.lowercased()]
    }

    func cloned() -> HDPIMPropertyTable {
        let table = HDPIMPropertyTable()
        table.properties = properties
        return table
    }

    func removeProperty(_ key: String) {
        properties.removeValue(forKey: key.lowercased())
    }

    func merge(_ dict: [String: String]) {
        for (key, value) in dict {
            properties[key.lowercased()] = value
        }
    }

    func mergeFromRequestInfo(_ info: [String: String]) {
        merge(info)
    }

    func setInstallDir(_ path: String) {
        properties["installdir"] = path
    }

    func setTargetDir(_ path: String) {
        properties["targetdir"] = path
    }

    func setMediaFolder(_ path: String) {
        properties["mediafolder"] = path
    }

    func setStagingFolder(_ path: String) {
        properties["stagingfolder"] = path
    }

    func setSourceFolder(_ path: String) {
        properties["sourcefolder"] = path
    }

    func setProductInstallDir(_ path: String) {
        properties["installdir"] = path
    }

    func setupSystemDirectories() {
        let home = HDPIMRuntimeEnvironment.userHomeDirectory()

        properties["ffcenvironment"] = "PROD"
        properties["prefmigration"] = "true"
        properties["adobecommon"] = "/Library/Application Support/Adobe"
        properties["adobeprogramfiles"] = "/Applications"
        properties["programfiles"] = "/Applications"
        properties["common"] = "/Library/Application Support"
        properties["sharedapplicationdata"] = "/Library/Application Support"
        properties["shareddocuments"] = "/Users/Shared"
        properties["utilities"] = "/Applications/Utilities"
        properties["fontsfolder"] = "/Library/Fonts"
        properties["library"] = "/Library"
        properties["librarypreferences"] = "/Library/Preferences"
        properties["internetplugins"] = "/Library/Internet Plug-Ins"
        properties["scriptingadditions"] = "/Library/ScriptingAdditions"
        properties["colorsyncprofiles"] = "/Library/ColorSync/Profiles"
        properties["userpreferences"] = "\(home)/Library/Preferences"
        properties["usercommon"] = "\(home)/Library/Application Support"
        properties["userdocuments"] = "\(home)/Documents"
        properties["userhome"] = home
        properties["userdesktop"] = "\(home)/Desktop"
        properties["_oobehome"] = "/Library/Application Support/Adobe"
        properties["userinternetplugins"] = "\(home)/Library/Internet Plug-Ins"
        properties["userfavorites"] = "\(home)/Library/Favorites"
        properties["userpictures"] = "\(home)/Pictures"
        properties["usertemplates"] = "\(home)/Templates"
        properties["shareddesktop"] = "/Users/Shared/Desktop"
    }

    func expandPath(_ rawPath: String) -> String {
        var result = rawPath
        for _ in 0..<32 {
            guard let openBracket = result.range(of: "[") else { break }
            guard let closeBracket = result[openBracket.upperBound...].range(of: "]") else { break }

            let key = String(result[openBracket.upperBound..<closeBracket.lowerBound])
            let fullPlaceholder = "[\(key)]"

            if let value = properties[key.lowercased()] {
                result = result.replacingOccurrences(of: fullPlaceholder, with: value)
            } else {
                print("⚠️ [HDPIM] 未知占位符: [\(key)]，替换为空字符串")
                result = result.replacingOccurrences(of: fullPlaceholder, with: "")
            }
        }
        return result
    }

    private func expandPathInternal(_ rawPath: String) -> String {
        var result = rawPath
        for _ in 0..<32 {
            guard let openBracket = result.range(of: "[") else { break }
            guard let closeBracket = result[openBracket.upperBound...].range(of: "]") else { break }

            let key = String(result[openBracket.upperBound..<closeBracket.lowerBound])
            let fullPlaceholder = "[\(key)]"

            if let value = properties[key.lowercased()] {
                result = result.replacingOccurrences(of: fullPlaceholder, with: value)
            } else {
                print("⚠️ [HDPIM] 未知占位符: [\(key)]，替换为空字符串")
                result = result.replacingOccurrences(of: fullPlaceholder, with: "")
            }
        }
        return result
    }

    func expandString(_ template: String) -> String {
        expandPath(template)
    }

    var allProperties: [String: String] {
        properties.filter { key, _ in
            !key.contains("proxyusername") &&
            !key.contains("proxypassword")
        }
    }
}
