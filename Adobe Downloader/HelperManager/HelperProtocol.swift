import Foundation

@objc(HelperXPCProtocol)
protocol HelperXPCProtocol {
    func executeOperation(
        _ operation: Data,
        withReply reply: @escaping (Data) -> Void
    )

    func executeInstallation(
        _ operation: Data,
        withReply reply: @escaping (Data) -> Void
    )

    func getInstallationProgress(
        withReply reply: @escaping (Data) -> Void
    )

    func cancelCurrentOperation(
        withReply reply: @escaping (Bool) -> Void
    )

    func getHelperVersion(
        withReply reply: @escaping (String) -> Void
    )
}

extension HelperXPCProtocol {
    func execute(
        _ operation: HelperOperation,
        completion: @escaping (Result<HelperOperationResult, HelperError>) -> Void
    ) {
        guard let data = try? JSONEncoder().encode(operation) else {
            completion(.failure(.unsupportedOperation))
            return
        }

        executeOperation(data) { resultData in
            guard let result = try? JSONDecoder().decode(HelperOperationResult.self, from: resultData) else {
                completion(.failure(.operationFailed("无法解析返回结果")))
                return
            }

            if result.success {
                completion(.success(result))
            } else {
                completion(.failure(.operationFailed(result.output)))
            }
        }
    }
}
