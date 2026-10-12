import Combine
import Foundation

/// Counts the completed index changes of one store on the main actor. Every
/// consumer of the history (list, search counts, statistics, recent menu)
/// creates it before its first read, so a change between that read and the
/// subscription cannot be missed. Other stores' changes are not counted, and
/// the subscription ends with the owner.
@MainActor
final class DictationHistoryChanges: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var subscription: AnyCancellable?

    init(store: DictationHistoryStore) {
        subscription = NotificationCenter.default
            .publisher(for: .dictationHistoryDidChange, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revision &+= 1 }
    }
}
