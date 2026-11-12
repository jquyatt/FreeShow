import CoreGraphics
import Foundation

/// A native producer shared by all retained scenes using one source.
@MainActor
public protocol LiveFrameSource: AnyObject {
    func start() async throws
    func frame() -> CGImage?
    func stop() async
}

@MainActor
public final class LiveSourceManager {
    private struct Entry {
        let source: any LiveFrameSource
        let ready: Task<Void, Error>
        var scenes: Set<String>
    }
    private var entries: [String: Entry] = [:]
    private var sceneKeys: [String: String] = [:]
    private var acquisitions: [String: UUID] = [:]
    private let factory: (FlywireLiveSourceRef) throws -> any LiveFrameSource

    public init(factory: @escaping (FlywireLiveSourceRef) throws -> any LiveFrameSource) {
        self.factory = factory
    }

    public func acquire(_ reference: FlywireLiveSourceRef, sceneId: String) async throws {
        try reference.validate()
        let key = reference.captureKey
        if sceneKeys[sceneId] != key { release(sceneId: sceneId) }
        if entries[key] == nil {
            let source = try factory(reference)
            entries[key] = Entry(source: source, ready: Task { try await source.start() }, scenes: [])
        }
        entries[key]!.scenes.insert(sceneId)
        sceneKeys[sceneId] = key
        let acquisition = UUID()
        acquisitions[sceneId] = acquisition
        let ready = entries[key]!.ready
        do {
            try await ready.value
            try Task.checkCancellation()
            guard acquisitions[sceneId] == acquisition else { throw CancellationError() }
        } catch {
            if acquisitions[sceneId] == acquisition { release(sceneId: sceneId) }
            throw error
        }
    }

    public func frame(sceneId: String) -> CGImage? {
        guard let key = sceneKeys[sceneId] else { return nil }
        return entries[key]?.source.frame()
    }

    public func release(sceneId: String) {
        acquisitions.removeValue(forKey: sceneId)
        guard let key = sceneKeys.removeValue(forKey: sceneId), var entry = entries[key] else { return }
        entry.scenes.remove(sceneId)
        if entry.scenes.isEmpty {
            entries.removeValue(forKey: key)
            entry.ready.cancel()
            Task {
                _ = await entry.ready.result
                await entry.source.stop()
            }
        } else {
            entries[key] = entry
        }
    }

    public func shutdown() {
        for sceneId in Array(sceneKeys.keys) { release(sceneId: sceneId) }
    }
}
