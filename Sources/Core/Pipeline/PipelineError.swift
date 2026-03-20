import Foundation

enum PipelineError: LocalizedError, Sendable {
    case missingFolderSelection
    case invalidDestination(String)
    case invalidBatchSource(String)
    case promotionConflict(URL)
    case materializationFailed(String)
    case verificationFailed([String])
    case copyFailed(String)
    case zipFailed(String)
    case finderRecoveryFailed(String)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFolderSelection:
            return "Source and destination folders must be selected."
        case .invalidDestination(let message):
            return message
        case .invalidBatchSource(let message):
            return message
        case .promotionConflict(let url):
            return "The destination target already exists: \(url.path)"
        case .materializationFailed(let path):
            return "Item could not be materialized locally: \(path)"
        case .verificationFailed(let mismatches):
            return mismatches.joined(separator: "\n")
        case .copyFailed(let path):
            return "Copy failed for \(path)"
        case .zipFailed(let message):
            return message
        case .finderRecoveryFailed(let message):
            return message
        case .persistenceFailed(let message):
            return message
        }
    }
}
