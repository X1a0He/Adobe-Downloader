//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import Foundation
import SwiftUI
import AppKit


struct AppStatics {
    static let supportedLanguages: [(code: String, name: String)] = [
        ("en_US", "English (US)"),
        ("zh_CN", "简体中文"),
        ("zh_TW", "繁體中文"),
        ("nl_NL", "Nederlands"),
        ("fr_CA", "Français (Canada)"),
        ("es_MX", "Español (Mexico)"),
        ("da_DK", "Dansk"),
        ("de_DE", "Deutsch"),
        ("pl_PL", "Polski"),
        ("es_ES", "Español"),
        ("en_AE", "English (UAE)"),
        ("fr_MA", "Français (Maroc)"),
        ("uk_UA", "Українська"),
        ("en_GB", "English (UK)"),
        ("it_IT", "Italiano"),
        ("ja_JP", "日本語"),
        ("sv_SE", "Svenska"),
        ("fr_FR", "Français"),
        ("tr_TR", "Türkçe"),
        ("ko_KR", "한국어"),
        ("nb_NO", "Norsk"),
        ("en_IL", "English (Israel)"),
        ("pt_BR", "Português (Brasil)"),
        ("fi_FI", "Suomi"),
        ("hu_HU", "Magyar"),
        ("cs_CZ", "Čeština"),
        ("ru_RU", "Русский"),
        ("ALL", "ALL")
    ]
    
    static let cpuArchitecture: String = {
        #if arch(arm64)
            return "Apple Silicon"
        #elseif arch(x86_64)
            return "Intel"
        #else
            return "Unknown Architecture"
        #endif
    }()
    
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
            return true
        #elseif arch(x86_64)
            return false
        #else
            return false
        #endif
    }()

    static let architectureSymbol: String = {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x64"
        #else
            return "Unknown Architecture"
        #endif
    }()
    
    /// 比较两个版本号
    /// - Parameters:
    ///   - version1: 第一个版本号
    ///   - version2: 第二个版本号
    /// - Returns: 负值表示version1<version2，0表示相等，正值表示version1>version2
    static func compareVersions(_ version1: String, _ version2: String) -> Int {
        let components1 = version1.split(separator: ".").map { Int($0) ?? 0 }
        let components2 = version2.split(separator: ".").map { Int($0) ?? 0 }
        
        let maxLength = max(components1.count, components2.count)
        let paddedComponents1 = components1 + Array(repeating: 0, count: maxLength - components1.count)
        let paddedComponents2 = components2 + Array(repeating: 0, count: maxLength - components2.count)
        
        for i in 0..<maxLength {
            if paddedComponents1[i] != paddedComponents2[i] {
                return paddedComponents1[i] - paddedComponents2[i]
            }
        }
        return 0
    }
}
