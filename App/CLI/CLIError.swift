import Foundation

enum CLIError: Error, CustomStringConvertible {
    case fileNotFound(String)

    var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File or directory not found: \(path)"
        }
    }
}
