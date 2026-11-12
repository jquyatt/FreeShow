/// Resolves the launch index once. After binding, only the same eligible display may be used.
struct FullscreenDisplayTarget {
    struct Display {
        let id: UInt32
        let identity: String?
        let eligible: Bool
    }

    let requestedIndex: Int?
    private(set) var identity: String?

    init(requestedIndex: Int?, identity: String? = nil) {
        self.requestedIndex = requestedIndex
        self.identity = identity
    }

    mutating func resolve(_ displays: [Display]) -> UInt32? {
        let candidate: Display?
        if let identity {
            candidate = displays.first { $0.identity == identity }
        } else if let requestedIndex {
            candidate = displays.indices.contains(requestedIndex) ? displays[requestedIndex] : nil
        } else {
            candidate = displays.first { $0.eligible && $0.identity != nil }
        }
        guard let candidate, candidate.eligible, let key = candidate.identity,
              displays.filter({ $0.identity == key }).count == 1 else { return nil }
        identity = key
        return candidate.id
    }
}
