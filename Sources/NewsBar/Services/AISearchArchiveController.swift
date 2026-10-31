import Foundation
import Observation

@MainActor
@Observable
final class AISearchArchiveController {
    static let shared = AISearchArchiveController()

    private(set) var entries: [AISearchArchiveEntry] = []
    private(set) var isReady = false
    private(set) var storageError: String?

    @ObservationIgnored private let store: AISearchArchiveStore

    init(store: AISearchArchiveStore = AISearchArchiveStore()) {
        self.store = store
    }

    func prepare() async {
        guard !isReady else { return }
        await store.prepare()
        entries = await store.all()
        storageError = await store.loadError
        isReady = true
    }

    func record(_ entry: AISearchArchiveEntry) async {
        await prepare()
        do {
            try await store.record(entry)
            entries = await store.all()
            storageError = await store.loadError
        } catch {
            entries = await store.all()
            storageError = error.localizedDescription
        }
    }

    func remove(id: UUID) async {
        await prepare()
        do {
            try await store.remove(id: id)
            entries = await store.all()
            storageError = await store.loadError
        } catch {
            storageError = error.localizedDescription
        }
    }

    func clear() async {
        do {
            try await store.clear()
            entries = []
            storageError = nil
            isReady = true
        } catch {
            entries = await store.all()
            storageError = error.localizedDescription
        }
    }
}
