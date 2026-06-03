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
