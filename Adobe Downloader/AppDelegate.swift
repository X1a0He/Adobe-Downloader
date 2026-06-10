import Cocoa
import SwiftUI

struct BlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.isEmphasized = true
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shouldTerminateImmediately = false

    private var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if HDPIMHeadlessInstallRunner.isActive {
            return
        }

        if let window = NSApp.windows.first {
            window.minSize = NSSize(width: 800, height: 765)
        }
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.characters?.lowercased() == "q" {
                if let mainWindow = NSApp.mainWindow,
                   mainWindow.sheets.isEmpty && !mainWindow.isSheet {
                    _ = self?.applicationShouldTerminate(NSApp)
                    return nil
                }
            }
            return event
        }

        PrivilegedHelperAdapter.shared.executeCommand("id -u") { _ in }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.shouldTerminateImmediately || HDPIMHeadlessInstallRunner.isActive {
            return .terminateNow
        }

        let hasActiveDownloads = globalNetworkManager.downloadTasks.contains { task in
            if case .downloading = task.totalStatus { return true }
            return false
        }
        
        if hasActiveDownloads {
            Task {
                for task in globalNetworkManager.downloadTasks {
                    if case .downloading = task.totalStatus {
                        await globalNewDownloadUtils.pauseDownloadTask(
                            taskId: task.id,
                            reason: .other(String(localized: "程序即将退出"))
                        )
                        await globalNetworkManager.saveTask(task)
                    }
                }

                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "确认退出")
                    alert.informativeText = String(localized:"有正在进行的下载任务，确定要退出吗？\n所有下载任务的进度已保存，下次启动可以继续下载")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized:"退出"))
                    alert.addButton(withTitle: String(localized:"取消"))

                    let response = alert.runModal()
                    if response == .alertSecondButtonReturn {
                        Task {
                            for task in globalNetworkManager.downloadTasks {
                                if case .paused = task.totalStatus {
                                    await globalNewDownloadUtils.resumeDownloadTask(taskId: task.id)
                                }
                            }
                        }
                    } else {
                        NSApplication.shared.terminate(0)
                    }
                }
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
        return .terminateCancel
    }
    
    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
} 
