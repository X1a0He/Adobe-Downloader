import Darwin
import Foundation

final class HDPIMPCDCompletion {
    private typealias OpenSession = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>, Int32) -> Int32
    private typealias GetDomainDataKeys = @convention(c) (
        UnsafeMutableRawPointer,
        Int32,
        UnsafePointer<CChar>,
        UnsafeMutablePointer<UnsafeMutablePointer<UnsafePointer<CChar>?>?>
    ) -> Int32
    private typealias RemoveDomainData = @convention(c) (
        UnsafeMutableRawPointer, Int32, UnsafePointer<CChar>, UnsafePointer<CChar>
    ) -> Int32
    private typealias SessionOperation = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private static let libraryPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/HDPIM.dylib"
    private let library: UnsafeMutableRawPointer
    private let openSession: OpenSession
    private let getDomainDataKeys: GetDomainDataKeys
    private let removeDomainData: RemoveDomainData
    private let commitSession: SessionOperation
    private let rollbackSession: SessionOperation
    private let closeSession: SessionOperation
    private var activeSession: UnsafeMutableRawPointer?
    private var unresolvedSessionError: String?

    init() throws {
        guard let library = dlopen(Self.libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "未知动态库错误"
            throw HDPIMPCDCompletionError("无法加载 HDPIM 的产品登记清理接口：\(detail)")
        }

        do {
            openSession = try Self.resolve("pcdOpenSessionNoCreate", from: library, as: OpenSession.self)
            getDomainDataKeys = try Self.resolve("pcdGetDomainDataKeys", from: library, as: GetDomainDataKeys.self)
            removeDomainData = try Self.resolve("pcdRemoveDomainData", from: library, as: RemoveDomainData.self)
            commitSession = try Self.resolve("pcdSessionCommit", from: library, as: SessionOperation.self)
            rollbackSession = try Self.resolve("pcdSessionRollback", from: library, as: SessionOperation.self)
            closeSession = try Self.resolve("pcdCloseSession", from: library, as: SessionOperation.self)
            self.library = library
        } catch {
            dlclose(library)
            throw error
        }
    }

    deinit {
        if activeSession == nil {
            dlclose(library)
        }
    }

    func removeProduct(appID: String, leid: String) throws {
        guard activeSession == nil else {
            throw HDPIMPCDCompletionError(unresolvedSessionError ?? "PCD session 尚未安全关闭，不能继续清理产品登记")
        }

        let subdomains = (appID == leid ? [appID] : [appID, leid]).filter { !$0.isEmpty }
        guard !subdomains.isEmpty else { return }
        guard subdomains.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw HDPIMPCDCompletionError("产品 AMT 身份包含空字符，已停止清理 PCD 登记")
        }

        var openedSession: UnsafeMutableRawPointer?
        let openStatus = openSession(&openedSession, 0)
        activeSession = openedSession
        guard openStatus == 0 else {
            if openStatus == 8, openedSession == nil { return }
            let detail = "打开现有 PCD session 失败（状态 \(openStatus)）"
            if openedSession != nil {
                // 打开失败的非空句柄可能尚未初始化，不能调用事务或关闭接口。
                let failure = "\(detail)；返回了状态未明的 session，已保留连接及动态库，等待当前卸载进程退出释放"
                unresolvedSessionError = failure
                throw HDPIMPCDCompletionError(failure)
            }
            throw HDPIMPCDCompletionError(detail)
        }
        guard let session = openedSession else {
            throw HDPIMPCDCompletionError("PCD 接口报告打开成功，但没有返回 session")
        }

        do {
            let entries = try subdomains.map { subdomain in
                (subdomain: subdomain, keys: try copyKeys(session: session, subdomain: subdomain))
            }
            for entry in entries {
                for key in entry.keys {
                    let status = entry.subdomain.withCString { subdomainPointer in
                        key.withCString { keyPointer in
                            removeDomainData(session, 1, subdomainPointer, keyPointer)
                        }
                    }
                    try Self.requireSuccess(status, operation: "移除本产品的 PCD 登记键")
                }
            }
            try Self.requireSuccess(commitSession(session), operation: "提交本产品的 PCD 登记清理")
        } catch {
            let originalFailure = error.localizedDescription
            let rollbackStatus = rollbackSession(session)
            guard rollbackStatus == 0 else {
                // close 会再次提交；回滚失败时必须连同动态库保留到进程退出。
                let failure = "\(originalFailure)；PCD 回滚失败（状态 \(rollbackStatus)），已保留连接及动态库，等待当前卸载进程退出释放"
                unresolvedSessionError = failure
                throw HDPIMPCDCompletionError(failure)
            }
            let closeStatus = closeSession(session)
            if closeStatus == 0 {
                activeSession = nil
                throw HDPIMPCDCompletionError("\(originalFailure)；PCD 变更已回滚")
            }
            let failure = "\(originalFailure)；PCD 变更已回滚，但关闭 session 失败（状态 \(closeStatus)），已停止后续登记清理"
            unresolvedSessionError = failure
            throw HDPIMPCDCompletionError(failure)
        }

        let closeStatus = closeSession(session)
        guard closeStatus == 0 else {
            let failure = "本产品的 PCD 登记清理已提交，但关闭 session 失败（状态 \(closeStatus)），已停止后续登记清理"
            unresolvedSessionError = failure
            throw HDPIMPCDCompletionError(failure)
        }
        activeSession = nil
    }

    private func copyKeys(session: UnsafeMutableRawPointer, subdomain: String) throws -> [String] {
        var keyList: UnsafeMutablePointer<UnsafePointer<CChar>?>?
        let status = subdomain.withCString { pointer in
            getDomainDataKeys(session, 1, pointer, &keyList)
        }
        guard status == 0 || status == 8 else {
            throw HDPIMPCDCompletionError("枚举本产品的 PCD 登记键失败（状态 \(status)）")
        }
        guard let keyList else {
            throw HDPIMPCDCompletionError("PCD 接口没有返回有效的登记键列表")
        }
        if status == 8 {
            guard keyList.pointee == nil else {
                throw HDPIMPCDCompletionError("PCD 接口报告空结果，但返回了非空登记键列表")
            }
            return []
        }

        // 原数组和字符串属于 session；复制后执行删除，不释放原生内存。
        var keys: [String] = []
        var index = 0
        while let keyPointer = keyList[index] {
            guard let key = String(validatingUTF8: keyPointer) else {
                throw HDPIMPCDCompletionError("PCD 登记键不是有效的 UTF-8，已停止清理")
            }
            keys.append(key)
            index += 1
        }
        return keys
    }

    private static func requireSuccess(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            throw HDPIMPCDCompletionError("\(operation)失败（状态 \(status)）")
        }
    }

    private static func resolve<T>(_ name: String, from library: UnsafeMutableRawPointer, as type: T.Type) throws -> T {
        guard let symbol = dlsym(library, name) else {
            throw HDPIMPCDCompletionError("当前 HDPIM 缺少产品登记清理接口 \(name)")
        }
        return unsafeBitCast(symbol, to: type)
    }
}

private struct HDPIMPCDCompletionError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
