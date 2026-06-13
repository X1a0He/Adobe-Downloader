import Foundation
import AppKit

final class HDPIMConflictingProcessDetector {

    static func detectConflictingProcesses(
        conflictingProcesses: [ConflictingProcessInfo]
    ) -> [RunningConflictingProcess] {
        let runningApps = NSWorkspace.shared.runningApplications
        var conflicts: [RunningConflictingProcess] = []

        for processInfo in conflictingProcesses {
            guard let regex = try? NSRegularExpression(pattern: processInfo.regularExpression) else {
                continue
            }

            for app in runningApps {
                guard let bundleURL = app.bundleURL,
                      let executableURL = app.executableURL else {
                    continue
                }

                let executableName = executableURL.lastPathComponent
                let range = NSRange(executableName.startIndex..., in: executableName)

                if regex.firstMatch(in: executableName, range: range) != nil {
                    conflicts.append(RunningConflictingProcess(
                        processInfo: processInfo,
                        pid: app.processIdentifier,
                        bundlePath: bundleURL.path,
                        executablePath: executableURL.path,
                        canForceKill: processInfo.forceKillAllowed == "true"
                    ))
                }
            }
        }

        return conflicts
    }

    static func terminateProcesses(_ processes: [RunningConflictingProcess]) -> [RunningConflictingProcess] {
        var remainingProcesses: [RunningConflictingProcess] = []

        for process in processes {
            if let app = NSRunningApplication(processIdentifier: process.pid) {
                if process.canForceKill {
                    app.forceTerminate()
                } else {
                    app.terminate()
                }

                usleep(100_000)

                if app.isTerminated == false {
                    remainingProcesses.append(process)
                }
            }
        }

        return remainingProcesses
    }
}

struct RunningConflictingProcess {
    let processInfo: ConflictingProcessInfo
    let pid: pid_t
    let bundlePath: String
    let executablePath: String
    let canForceKill: Bool
}
