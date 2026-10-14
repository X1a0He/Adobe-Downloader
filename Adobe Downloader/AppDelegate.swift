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
    private var isPreparingTermination = false
    
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
                    NSApp.terminate(nil)
                    return nil
                }
            }
            return event
        }

        PrivilegedHelperAdapter.shared.executeCommand("id -u") { _ in }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !HDPIMHeadlessInstallRunner.isActive else { return }
        PrivilegedHelperAdapter.shared.checkInstall()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.shouldTerminateImmediately || HDPIMHeadlessInstallRunner.isActive {
            return .terminateNow
        }

        if isPreparingTermination { return .terminateLater }
        let activeTasks = globalNetworkManager.downloadTasks.filter { $0.status.isActive }
        guard !activeTasks.isEmpty else { return .terminateNow }
        isPreparingTermination = true

        Task { @MainActor in
            for task in activeTasks {
                await globalNewDownloadUtils.pauseDownloadTask(
                    taskId: task.id, reason: .other(AppLocalized("程序即将退出"))
                )
                await globalNetworkManager.saveTask(task)
            }
            let alert = NSAlert()
            alert.messageText = AppLocalized("确认退出")
            alert.informativeText = AppLocalized("有正在进行的下载任务，确定要退出吗？\n所有下载任务的进度已保存，下次启动可以继续下载")
            alert.alertStyle = .warning
            alert.addButton(withTitle: AppLocalized("退出"))
            alert.addButton(withTitle: AppLocalized("取消"))
            let shouldExit = alert.runModal() != .alertSecondButtonReturn
            isPreparingTermination = false
            sender.reply(toApplicationShouldTerminate: shouldExit)
            if !shouldExit {
                for task in activeTasks {
                    if case .paused = task.status {
                        Task { await globalNewDownloadUtils.resumeDownloadTask(taskId: task.id) }
                    }
                }
            }
        }
        return .terminateLater
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
} 
