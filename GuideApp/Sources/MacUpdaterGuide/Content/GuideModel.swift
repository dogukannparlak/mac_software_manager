import Foundation

/// One block of formatted copy inside a topic.
enum GuideBlock: Hashable, Sendable {
    case paragraph(Localized)
    case bullets([Localized])
    case steps([Localized])
    /// A neutral aside, rendered like a Note box.
    case note(Localized)
    /// Something the reader could get wrong, rendered with a warning tint.
    case caution(Localized)
}

struct GuideSection: Identifiable, Hashable, Sendable {
    let id: String
    let heading: Localized?
    let blocks: [GuideBlock]

    init(id: String, heading: Localized? = nil, blocks: [GuideBlock]) {
        self.id = id
        self.heading = heading
        self.blocks = blocks
    }
}

struct GuideTopic: Identifiable, Hashable, Sendable {
    let id: String
    /// SF Symbol shown in the sidebar and in the topic header.
    let symbol: String
    let title: Localized
    let summary: Localized
    let sections: [GuideSection]
}
