import CarPlay
import UIKit

@MainActor
final class TuneCarPlayScene: UIResponder, CPTemplateApplicationSceneDelegate {
    private weak var controller: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        showRoot()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController) {
        if controller === interfaceController { controller = nil }
    }

    private func showRoot() {
        let items = [
            item("Сейчас играет", icon: "play.circle") { scene in
                scene.showNowPlaying()
            },
            item("Моя волна", icon: "waveform") { scene in
                Player.shared.playWave()
                scene.showNowPlaying()
            },
            item("Мне нравится", icon: "heart") { scene in
                let tracks = await scene.likedTracks()
                scene.showTracks(tracks, title: "Мне нравится")
            },
            item("Скачанное", icon: "arrow.down.circle") { scene in
                scene.showTracks(Downloads.shared.tracks, title: "Скачанное")
            },
            item("Плейлисты", icon: "music.note.list") { scene in
                scene.showPlaylists()
            }
        ]
        controller?.setRootTemplate(CPListTemplate(title: "Tune", sections: [CPListSection(items: items)]),
                                    animated: false, completion: nil)
    }

    private func showNowPlaying() {
        controller?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func showPlaylists() {
        let session = Session.shared
        let lists = session.playlists + session.likedPlaylists
        guard !lists.isEmpty else {
            showMessage("Плейлисты", text: session.token == nil ? "Войдите в Tune на iPhone" : "Нет сохранённых плейлистов")
            return
        }
        let items = lists.prefix(CPListTemplate.maximumItemCount).map { playlist in
            item(playlist.title, icon: "music.note.list") { scene in
                let tracks = (try? await API.shared.playlistTracks(playlist)) ?? []
                scene.showTracks(tracks, title: playlist.title,
                                 context: PlayContext(kind: "playlist", item: playlist.id, name: playlist.title))
            }
        }
        controller?.pushTemplate(CPListTemplate(title: "Плейлисты", sections: [CPListSection(items: items)]),
                                 animated: true, completion: nil)
    }

    private func likedTracks() async -> [Track] {
        let session = Session.shared
        let catalog = session.catalogLikedTracksList()
        let local = session.localLikedTracks
        let prefix = catalog + local
        let known = Set(prefix.map(\.id))
        let cached: [Track] = (await Task.detached(priority: .userInitiated) {
            Storage.load("likes-tracks.json") ?? []
        }.value).filter { Settings.catalog || !TuneCatalogID.isSyntheticTrack($0.id) }
        if !cached.isEmpty { return prefix + cached.filter { !known.contains($0.id) } }
        let ids = session.likedIds.filter { !known.contains($0) }
        let fetched = (try? await API.shared.tracks(ids: Array(ids.prefix(CPListTemplate.maximumItemCount)))) ?? []
        return prefix + fetched
    }

    private func showTracks(_ list: [Track], title: String, context: PlayContext? = nil) {
        let tracks = list.filter {
            Connectivity.shared.offline
                ? Downloads.shared.has($0.id)
                : (!$0.unavailable || $0.uncensored || $0.isCatalog || Uncensor.shared.hasAudio($0.id) || Downloads.shared.has($0.id))
        }
        guard !tracks.isEmpty else {
            showMessage(title, text: Session.shared.token == nil ? "Войдите в Tune на iPhone" : "Нет доступных треков")
            return
        }
        let items = tracks.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, track in
            item(track.fullTitle, detail: track.artists) { scene in
                Player.shared.play(tracks, at: index, context: context ?? .various(title))
                scene.showNowPlaying()
            }
        }
        controller?.pushTemplate(CPListTemplate(title: title, sections: [CPListSection(items: items)]),
                                 animated: true, completion: nil)
    }

    private func showMessage(_ title: String, text: String) {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: [CPListItem(text: text, detailText: nil)])])
        controller?.pushTemplate(template, animated: true, completion: nil)
    }

    private func item(_ text: String, detail: String? = nil, icon: String? = nil,
                      action: @escaping @MainActor (TuneCarPlayScene) async -> Void) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: icon.flatMap { UIImage(systemName: $0) })
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                defer { completion() }
                guard let self, self.controller != nil else { return }
                await action(self)
            }
        }
        return item
    }
}
