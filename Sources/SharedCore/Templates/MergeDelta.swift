import Foundation

public enum MergeDelta: Sendable, Equatable {
    case began(templateId: UUID, templateName: String, routeDescription: String)
    case token(String)
    case sectionStarted(String)
    case completed(finalText: String)
    case failed(TraceError)

    public static func == (lhs: MergeDelta, rhs: MergeDelta) -> Bool {
        switch (lhs, rhs) {
        case (.began(let a, let an, let ar), .began(let b, let bn, let br)):
            return a == b && an == bn && ar == br
        case (.token(let a), .token(let b)): return a == b
        case (.sectionStarted(let a), .sectionStarted(let b)): return a == b
        case (.completed(let a), .completed(let b)): return a == b
        case (.failed(let a), .failed(let b)):
            return a.localizedDescription == b.localizedDescription
        default: return false
        }
    }
}
