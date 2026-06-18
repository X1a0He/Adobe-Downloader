import Foundation

enum HDPIMUserOwnershipFixer {
    static func restoreUserOwnership(logHandler: ((String) -> Void)?) {
        guard getuid() == 0 else {
            return
        }

        let home = HDPIMRuntimeEnvironment.userHomeDirectory()
        guard let ids = loginUserIDs(home: home) else {
            logHandler?("[HDPIM 权限] 无法确定登录用户，跳过用户区属主修正")
            return
        }

        let targets = [
            "\(home)/Library/Preferences",
            "\(home)/Library/Caches",
            "\(home)/Library/Application Support"
        ]

        for directory in targets where FileManager.default.fileExists(atPath: directory) {
            chownRootOwnedItems(in: directory, uid: ids.uid, gid: ids.gid)
        }

        logHandler?("[HDPIM 权限] 已将用户区 root 属主文件归还登录用户 (uid=\(ids.uid))")
    }

    private static func loginUserIDs(home: String) -> (uid: uid_t, gid: gid_t)? {
        let userName = URL(fileURLWithPath: home).lastPathComponent
        if !userName.isEmpty, let record = getpwnam(userName), record.pointee.pw_uid != 0 {
            return (record.pointee.pw_uid, record.pointee.pw_gid)
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: home),
           let owner = attributes[.ownerAccountID] as? NSNumber,
           let group = attributes[.groupOwnerAccountID] as? NSNumber,
           owner.uint32Value != 0 {
            return (owner.uint32Value, group.uint32Value)
        }

        return nil
    }

    private static func chownRootOwnedItems(in directory: String, uid: uid_t, gid: gid_t) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [
            directory,
            "-uid", "0",
            "-exec", "/usr/sbin/chown", "-h", "\(uid):\(gid)", "{}", "+"
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
        }
    }
}
