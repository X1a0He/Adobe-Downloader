import Foundation

extension HDPIMProcessorFamily {

    static func current() -> HDPIMProcessorFamily {
        let arch = ArchitectureDetector.getCurrentArchitecture()
        switch arch {
        case .arm64:
            return .arm64Bit
        case .intel:
            return .bit64
        case .unknown:
            return .bit64
        }
    }

    func isCompatibleWithCurrentArchitecture() -> Bool {
        let currentArch = ArchitectureDetector.getCurrentArchitecture()

        switch self {
        case .arm64Bit:
            return currentArch == .arm64
        case .bit64, .bit32:
            return currentArch == .intel || (currentArch == .arm64 && ArchitectureDetector.isRosetta2Available())
        }
    }

    static func selectOptimalPlatform(from platforms: [String]) -> String {
        let selected = ArchitectureDetector.selectPlatform(availablePlatforms: platforms)
        return selected.rawValue
    }
}

extension Platform {

    func toProcessorFamily() -> HDPIMProcessorFamily {
        switch self {
        case .macarm64:
            return .arm64Bit
        case .macuniversal, .osx1064:
            return .bit64
        }
    }
}
