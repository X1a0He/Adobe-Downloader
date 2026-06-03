import Foundation

enum Architecture {
    case arm64
    case intel
    case unknown
}

enum Platform: String {
    case macarm64 = "macarm64"
    case macuniversal = "macuniversal"
    case osx1064 = "osx10-64"
}

class ArchitectureDetector {

    static func getCurrentArchitecture() -> Architecture {
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size

        let result = sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0)

        if result == 0 {
            return ret == 1 ? .intel : .arm64
        }

        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .intel
        #else
        return .unknown
        #endif
    }

    static func isRosetta2Available() -> Bool {
        let arm64Code: cpu_type_t = 0x1000007
        return CFBundleIsArchitectureLoadable(arm64Code)
    }

    static func selectPlatform(availablePlatforms: [String]) -> Platform {
        let arch = getCurrentArchitecture()

        if arch == .arm64 {
            if availablePlatforms.contains(Platform.macarm64.rawValue) {
                return .macarm64
            }
            if availablePlatforms.contains(Platform.macuniversal.rawValue) {
                return .macuniversal
            }
        }

        if arch == .intel || (arch == .arm64 && isRosetta2Available()) {
            if availablePlatforms.contains(Platform.macuniversal.rawValue) {
                return .macuniversal
            }
            if availablePlatforms.contains(Platform.osx1064.rawValue) {
                return .osx1064
            }
        }

        return .osx1064
    }
}
