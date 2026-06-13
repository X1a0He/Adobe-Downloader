import Foundation

extension HelperManager {

    func installPackage(
        at packagePath: String,
        target: String = "/"
    ) async throws {
        let client = try getClient()
        let operation = HelperOperation.installPackage(
            packagePath: packagePath,
            targetPath: target
        )

        try await withCheckedThrowingContinuation { continuation in
            client.execute(operation) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func uninstallPath(_ path: String) async throws {
        let client = try getClient()
        let operation = HelperOperation.uninstallPath(path: path)

        try await withCheckedThrowingContinuation { continuation in
            client.execute(operation) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func executeHDPIMInstall(
        productDir: String,
        userHome: String,
        executablePath: String? = nil,
        progress: @escaping (String) -> Void
    ) async throws {
        let client = try getClient()
        let operation = HelperOperation.hdpimInstall(
            productDir: productDir,
            userHome: userHome,
            executablePath: executablePath
        )

        try await client.executeInstallation(operation, progress: progress)
    }

    func executeHDPIMUninstall(
        request: HDPIMUninstallHelperRequest,
        userHome: String,
        executablePath: String? = nil,
        progress: @escaping (String) -> Void
    ) async throws {
        let client = try getClient()
        let operation = HelperOperation.hdpimUninstall(
            request: request,
            userHome: userHome,
            executablePath: executablePath
        )

        try await client.executeInstallation(operation, progress: progress)
    }

    func cancelCurrentOperation() async throws {
        let client = try getClient()
        let operation = HelperOperation.cancelOperation

        try await withCheckedThrowingContinuation { continuation in
            client.execute(operation) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func executeShell(_ command: String) async throws -> String {
        let client = try getClient()
        let operation = HelperOperation.executeShell(command: command)

        return try await withCheckedThrowingContinuation { continuation in
            client.execute(operation) { result in
                switch result {
                case .success(let result):
                    continuation.resume(returning: result.output)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func copyFile(from source: String, to destination: String) async throws {
        let client = try getClient()
        let operation = HelperOperation.copyFile(
            source: source,
            destination: destination
        )

        try await withCheckedThrowingContinuation { continuation in
            client.execute(operation) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setPermissions(path: String, mode: Int) async throws {
        let client = try getClient()
        let operation = HelperOperation.setPermissions(path: path, mode: mode)

        try await withCheckedThrowingContinuation { continuation in
            client.execute(operation) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func triggerTCCPrompt() async throws {
        let client = try getClient()
        let operation = HelperOperation.triggerTCCPrompt

        try await withCheckedThrowingContinuation { continuation in
            client.execute(operation) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
