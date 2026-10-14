//
//  HDPIMPropertyTable.swift
//  Adobe Downloader
//

import Foundation

class HDPIMPropertyTable {

    private var properties: [String: String] = [:]
    private static let propertyPattern = try! NSRegularExpression(pattern: #"\[([^\[\]]+)\]"#)

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
        let expanded = expandPathInternal(rawPath).replacingOccurrences(of: "\\", with: "/")
        return (expanded as NSString).standardizingPath
    }

    /// 只在读取材料模板时检查变量；文件枚举得到的名称不再按模板解释。
    func expandPathForInstallation(_ rawPath: String) throws -> String {
        let expanded = expandPathInternal(rawPath).replacingOccurrences(of: "\\", with: "/")
        for match in Self.propertyPattern.matches(in: expanded, range: NSRange(expanded.startIndex..., in: expanded)) {
            guard let range = Range(match.range, in: expanded),
                  let keyRange = Range(match.range(at: 1), in: expanded) else { continue }
            let key = String(expanded[keyRange])
            let startsComponent = range.lowerBound == expanded.startIndex || expanded[expanded.index(before: range.lowerBound)] == "/"
            let endsComponent = range.upperBound == expanded.endIndex || expanded[range.upperBound] == "/"
            // 独立的 [目录变量] 或仍未展开的已登记属性必须报错；镜头文件名中的 ED[IF] 等保留字面值。
            if properties[key.lowercased()] != nil || (startsComponent && endsComponent) {
                throw HDPIMMaterialError.invalid("安装路径包含未解析的占位符：[\(key)]：\(rawPath)")
            }
        }
        return (expanded as NSString).standardizingPath
    }

    private func expandPathInternal(_ rawPath: String) -> String {
        var result = rawPath
        for _ in 0..<32 {
            let matches = Self.propertyPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
            var expanded = result
            for match in matches.reversed() {
                guard let keyRange = Range(match.range(at: 1), in: result),
                      let range = Range(match.range, in: expanded),
                      let value = properties[String(result[keyRange]).lowercased()] else { continue }
                expanded.replaceSubrange(range, with: value)
            }
            guard expanded != result else { break }
            result = expanded
        }
        return result
    }

    func expandString(_ template: String) -> String {
        expandPathInternal(template)
    }

    var allProperties: [String: String] {
        properties.filter { key, _ in
            !key.contains("proxyusername") &&
            !key.contains("proxypassword")
        }
    }
}
