import Foundation

public struct ConversationSegmenter: Sendable {
    public var maximumGap: TimeInterval
    public init(maximumGap: TimeInterval = 90) { self.maximumGap = maximumGap }

    public func segment(_ utterances: [LifeLogUtterance]) -> [(LifeLogConversation, [LifeLogUtterance])] {
        let ordered = utterances.sorted { $0.startedAt < $1.startedAt }
        guard var first = ordered.first else { return [] }
        var groups: [[LifeLogUtterance]] = [[first]]
        for utterance in ordered.dropFirst() {
            let gap = utterance.startedAt.timeIntervalSince(first.endedAt)
            if gap > maximumGap {
                groups.append([utterance])
            } else {
                groups[groups.count - 1].append(utterance)
            }
            first = utterance
        }
        return groups.map { group in
            let conversation = LifeLogConversation(id: "conversation-\(group[0].id)", startedAt: group[0].startedAt,
                                                   endedAt: group[group.count - 1].endedAt,
                                                   calendarEventID: group[0].calendarEventID)
            return (conversation, group.map { item in var item = item; item.conversationID = conversation.id; return item })
        }
    }
}
