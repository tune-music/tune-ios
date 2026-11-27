import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Фоновая синхронизация медиатеки Каталога Tune (`tune-sync:v1`) через скрытые приватные плейлисты Яндекса.
actor TuneSyncService {
    static let shared = TuneSyncService()

    private var pushTask: Task<Void, Never>?
    private var pendingPushUID: String?
    private var skipDebounce = false

    private init() {}

    nonisolated static func installHooks() {
        CatalogLibraryStore.shared.onMutation = { uid in
            Task { await TuneSyncService.shared.schedulePush(uid: uid) }
        }
    }

    func handleFetchedPlaylists(_ raw: [Playlist], uid: String) async {
        guard !Demo.on, !uid.isEmpty else { return }
        _ = CatalogLibraryStore.shared.ensureMigrated(uid: uid)

        let shards = raw.filter {
            TuneSyncCodec.isSyncPlaylist(title: $0.title, description: $0.description)
        }
        switch TuneSyncCodec.parseRemoteShards(shards, uid: uid) {
        case .empty:
            let snap = CatalogLibraryStore.shared.snapshot(uid: uid)
            if snap.hasActiveData {
                enqueuePush(uid: uid, immediate: true)
            }
        case .incomplete(let reason):
            Log.shared.add("Tune Sync: \(reason)")
        case .ready(let remoteLibs, let duplicatesDetected, let needsCleanup):
            let res = CatalogLibraryStore.shared.applyRemoteMerge(uid: uid, mergeWith: remoteLibs)
            if res.changedLocal {
                await MainActor.run {
                    Session.shared.applySyncedCatalogLibrary(uid: uid)
                }
            }
            let now = TuneSyncCodec.nowSeconds()
            let payload = TuneSyncCodec.encode(res.merged, uid: uid, now: now)
            let staleShards = Self.shardsNeedUpdate(shards, payload: payload)
            if (res.needsPush || duplicatesDetected || needsCleanup || staleShards)
                && (res.merged.hasActiveData || !shards.isEmpty) {
                enqueuePush(uid: uid, immediate: true)
            }
        }
    }

    func schedulePush(uid: String) {
        guard !Demo.on, !uid.isEmpty else { return }
        enqueuePush(uid: uid, immediate: false)
    }

    private func enqueuePush(uid: String, immediate: Bool) {
        pendingPushUID = uid
        if immediate { skipDebounce = true }
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            await self?.runPushLoop()
        }
    }

    private func runPushLoop() async {
        defer { pushTask = nil }
        while let uid = pendingPushUID {
            let immediate = skipDebounce
            skipDebounce = false
            pendingPushUID = nil
            if !immediate {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let newerUID = pendingPushUID {
                    pendingPushUID = nil
                    await performPush(uid: newerUID)
                    continue
                }
            }
            await performPush(uid: uid)
        }
    }

    private func performPush(uid: String) async {
        guard !Demo.on, await Connectivity.shared.online, TokenStore.token != nil else { return }
        let isSameAccount = await MainActor.run { Session.shared.profile?.uid == uid }
        guard isSameAccount else { return }

        _ = CatalogLibraryStore.shared.ensureMigrated(uid: uid)

        let raw: [Playlist]
        do {
            raw = try await API.shared.rawUserPlaylists(uid: uid)
        } catch {
            if !(error is CancellationError) {
                Log.shared.add("Tune Sync: не удалось прочитать плейлисты (\(error.localizedDescription))")
            }
            return
        }

        let stillSameAccount = await MainActor.run { Session.shared.profile?.uid == uid }
        guard stillSameAccount else { return }

        let existingShards = raw.filter {
            TuneSyncCodec.isSyncPlaylist(title: $0.title, description: $0.description)
        }.sorted {
            let a = Int64($0.kind) ?? Int64.max
            let b = Int64($1.kind) ?? Int64.max
            return a != b ? a < b : $0.kind < $1.kind
        }

        if case .ready(let remoteLibs, _, _) = TuneSyncCodec.parseRemoteShards(existingShards, uid: uid) {
            let res = CatalogLibraryStore.shared.applyRemoteMerge(uid: uid, mergeWith: remoteLibs)
            if res.changedLocal {
                await MainActor.run {
                    Session.shared.applySyncedCatalogLibrary(uid: uid)
                }
            }
        }

        let latest = CatalogLibraryStore.shared.snapshot(uid: uid)
        guard latest.hasActiveData || !existingShards.isEmpty else { return }

        let payload = TuneSyncCodec.encode(latest, uid: uid)
        let targetShards = TuneSyncCodec.buildShards(payload: payload)

        var byIndex: [Int: [Playlist]] = [:]
        var unindexed: [Playlist] = []
        for shard in existingShards {
            if let desc = shard.description, let env = TuneSyncCodec.extractEnvelope(desc) {
                byIndex[env.part - 1, default: []].append(shard)
            } else if let idx = TuneSyncCodec.shardIndexFromTitle(shard.title) {
                byIndex[idx, default: []].append(shard)
            } else {
                unindexed.append(shard)
            }
        }

        var keepers: [Int: Playlist] = [:]
        var surplus: [Playlist] = unindexed
        for (idx, group) in byIndex {
            if idx < targetShards.count, let first = group.first {
                keepers[idx] = first
                surplus.append(contentsOf: group.dropFirst())
            } else {
                surplus.append(contentsOf: group)
            }
        }
        surplus.sort {
            let a = Int64($0.kind) ?? Int64.max
            let b = Int64($1.kind) ?? Int64.max
            return a != b ? a < b : $0.kind < $1.kind
        }

        let coverJPEG = Self.syncCoverJPEG()

        do {
            for spec in targetShards {
                let shard: Playlist
                let newlyCreated: Bool
                if let kept = keepers[spec.index] {
                    shard = kept
                    newlyCreated = false
                } else if !surplus.isEmpty {
                    shard = surplus.removeFirst()
                    newlyCreated = false
                } else {
                    shard = try await API.shared.createPlaylist(uid: uid, title: spec.title)
                    newlyCreated = true
                }

                if shard.title != spec.title {
                    try await API.shared.renamePlaylist(uid: uid, kind: shard.kind, title: spec.title)
                }

                if newlyCreated || Self.needsSyncCover(shard), let coverJPEG {
                    do {
                        _ = try await API.shared.uploadPlaylistCover(shard, jpeg: coverJPEG)
                    } catch {
                        Log.shared.add("Tune Sync: ошибка загрузки обложки (\(error.localizedDescription))")
                    }
                }

                if newlyCreated || shard.description != spec.description {
                    try await API.shared.setPlaylistDescription(uid: uid, kind: shard.kind, description: spec.description)
                }
            }

            for extra in surplus {
                do {
                    try await API.shared.deleteSyncShardPlaylist(uid: uid, kind: extra.kind)
                } catch {
                    Log.shared.add("Tune Sync: не удалось удалить лишний плейлист \(extra.kind) (\(error.localizedDescription))")
                }
            }
        } catch {
            if !(error is CancellationError) {
                Log.shared.add("Tune Sync: ошибка сохранения (\(error.localizedDescription))")
            }
        }
    }

    private static func needsSyncCover(_ playlist: Playlist) -> Bool {
        playlist.customCover != true
    }

    private static func shardsNeedUpdate(_ shards: [Playlist], payload: String) -> Bool {
        let targets = TuneSyncCodec.buildShards(payload: payload)
        guard shards.count == targets.count else { return true }
        var byIndex: [Int: Playlist] = [:]
        for shard in shards {
            if let desc = shard.description, let env = TuneSyncCodec.extractEnvelope(desc) {
                if byIndex[env.part - 1] != nil { return true }
                byIndex[env.part - 1] = shard
            } else {
                return true
            }
        }
        for spec in targets {
            guard let existing = byIndex[spec.index],
                  existing.title == spec.title,
                  existing.description == spec.description,
                  !needsSyncCover(existing) else {
                return true
            }
        }
        return false
    }

    private static func syncCoverJPEG() -> Data? {
        #if canImport(UIKit)
        return UIImage(named: "TuneSyncCover")?.jpegData(compressionQuality: 0.92)
        #else
        return nil
        #endif
    }
}
