import Foundation

struct StoryViewersResponse: Decodable {
    let total: Int
    let nextCursor: String?
    let viewers: [StoryViewer]
}

struct StoryViewer: Decodable, Identifiable {
    let id: String
    let viewedAt: Date
    let user: ViewerUser
    let responses: [ViewerResponse]
}

struct ViewerUser: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let image: String?
}

struct ViewerResponse: Decodable, Hashable {
    let overlayIndex: Int
    let kind: ResponseKind
    let optionIndex: Int?
    let optionLabel: String?
    let selectedIndex: Int?
    let selectedLabel: String?
    let isCorrect: Bool?
    let text: String?

    enum ResponseKind: String, Decodable, Hashable {
        case poll
        case quiz
        case question
    }
}

extension Date {
    func relativeShort() -> String {
        let diff = max(Int(Date().timeIntervalSince(self)), 0)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(diff / 60)m" }
        if diff < 86400 { return "\(diff / 3600)h" }
        return "\(diff / 86400)d"
    }
}
