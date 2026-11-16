import Foundation
import Combine

@MainActor
final class Ynison: ObservableObject {
    static let shared = Ynison()
    typealias Playback = YnisonProtocol.Playback
    typealias State = YnisonProtocol.State

    enum Connection: Equatable { case idle, connecting, connected, offline, failed }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "ynisonEnabled")
    @Published private(set) var connection = Connection.idle
    @Published private(set) var state = State()
    @Published private(set) var working = false
    @Published var errorText: String?
    private(set) var receivedAt = Date()

    let deviceID: String = {
        let key = "ynisonDeviceID"
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Origin": "https://music.yandex.ru"]
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: YnisonSocketDelegate(), delegateQueue: nil)
    }()
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var redirect: URLSessionWebSocketTask?
    private var applying: Task<Void, Never>?
    private var token: String?
    private var sent: (playback: Playback, at: Date)?
    private var epoch = 0

    private init() {}

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        UserDefaults.standard.set(value, forKey: "ynisonEnabled")
        updateConnection()
    }

    func updateConnection() {
        let current = TokenStore.token
        guard enabled, !Demo.on, let current else {
            disconnect()
            return
        }
        guard !Connectivity.shared.offline else {
            if connection != .offline || runner != nil { disconnect(); connection = .offline }
            return
        }
        if runner != nil, current == token { return }
        disconnect()
        token = current
        connection = .connecting
        let turn = epoch
        runner = Task { [weak self] in await self?.run(token: current, turn: turn) }
    }

    func retry() {
        disconnect()
        updateConnection()
    }

    func disconnect() {
        epoch += 1
        runner?.cancel()
        applying?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        redirect?.cancel(with: .goingAway, reason: nil)
        runner = nil
        applying = nil
        socket = nil
        redirect = nil
        sent = nil
        token = nil
        if connection != .idle { connection = .idle }
        if state != State() { state = State() }
        if working { working = false }
        errorText = nil
    }

    private func run(token: String, turn: Int) async {
        let delays = [2, 5, 15, 60, 300]
        var attempt = 0
        while !Task.isCancelled, turn == epoch {
            do {
                try await connect(token: token, turn: turn)
            } catch {
                guard !Task.isCancelled, turn == epoch else { return }
                if connection == .connected { attempt = 0 }
                connection = .failed
                applying?.cancel()
                sent = nil
                let delay = (error as? HubError)?.retryAfter ?? delays[min(attempt, delays.count - 1)]
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    private func open(host: String, path: String, token: String, extra: [String: Any] = [:]) throws -> URLSessionWebSocketTask {
        let url = try YnisonProtocol.socketURL(host: host, path: path)
        let protocols = try YnisonProtocol.protocols(token: token, device: deviceID, extra: extra)
        let task = session.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        return task
    }

    private func connect(token: String, turn: Int) async throws {
        let router = try open(host: YnisonProtocol.redirectHost, path: YnisonProtocol.redirectPath, token: token)
        redirect = router
        let address: JSON
        do {
            defer { router.cancel(with: .normalClosure, reason: nil) }
            address = try await firstMessage(from: router)
        }
        try Task.checkCancellation()
        guard turn == epoch else { throw CancellationError() }
        redirect = nil
        guard let host = address["host"].string, let ticket = address["redirect_ticket"].raw,
              let sessionID = address["session_id"].idText else { throw TuneError("Ynison не прислал параметры подключения") }
        let hub = try open(host: host, path: YnisonProtocol.hubPath, token: token,
                           extra: ["Ynison-Redirect-Ticket": ticket, "Ynison-Session-Id": sessionID])
        socket = hub
        defer {
            hub.cancel(with: .goingAway, reason: nil)
            if socket === hub { socket = nil }
        }
        let local = Player.shared.ynisonPlayback()
        try await send(["update_full_state": [
            "player_state": YnisonProtocol.player(local, device: deviceID),
            "device": YnisonProtocol.device(deviceID), "is_currently_active": false,
            "sync_state_from_eov_optional": NSNull()
        ]], on: hub)
        sent = (local, .now)
        var value = try await firstMessage(from: hub)
        let monitor = Task { [weak self, weak hub] in
            guard let hub else { return }
            await self?.monitor(hub, turn: turn)
        }
        defer { monitor.cancel() }
        while !Task.isCancelled, turn == epoch {
            if let incoming = YnisonProtocol.state(value) {
                if connection != .connected { connection = .connected }
                receive(incoming, turn: turn)
            }
            value = try await Self.receive(from: hub)
        }
    }

    private func firstMessage(from socket: URLSessionWebSocketTask) async throws -> JSON {
        let timeout = Task {
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                socket.cancel(with: .goingAway, reason: nil)
            } catch {}
        }
        defer { timeout.cancel() }
        return try await Self.receive(from: socket)
    }

    private static func receive(from socket: URLSessionWebSocketTask) async throws -> JSON {
        let data: Data
        switch try await socket.receive() {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: throw TuneError("Неизвестный ответ Ynison")
        }
        let value = JSON.parse(data)
        if let error = value["error"].dict {
            let delay = JSON(error)["details"]["ynison-go-away-for-seconds"].idText.flatMap(Int.init)
            throw HubError(retryAfter: delay.map { min(max($0, 1), 3_600) })
        }
        return value
    }

    private func send(_ fields: [String: Any], on socket: URLSessionWebSocketTask, intercept: Bool = false) async throws {
        try await socket.send(.string(YnisonProtocol.message(fields, intercept: intercept)))
    }

    private func monitor(_ socket: URLSessionWebSocketTask, turn: Int) async {
        var ticks = 0
        while !Task.isCancelled, turn == epoch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, turn == epoch else { return }
            ticks += 1
            if ticks % 25 == 0 {
                socket.sendPing { error in
                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                }
            }
            do {
                try await pushLocal(on: socket)
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func pushLocal(on socket: URLSessionWebSocketTask) async throws {
        guard connection == .connected, !working, applying == nil, let sent else { return }
        let playback = Player.shared.ynisonPlayback()
        let same = playback.sameQueue(as: sent.playback)
        let expected = sent.playback.predicted(after: Date().timeIntervalSince(sent.at))
        let moved = abs(playback.position - expected) > 3
        guard !same || playback.paused != sent.playback.paused || playback.speed != sent.playback.speed || moved else { return }
        self.sent = (playback, .now)
        let here = state.active == deviceID
        let startedHere = !playback.paused && (sent.playback.paused || !same)
        guard here || startedHere else { return }
        if !same || !here {
            try await send(["update_player_state": ["player_state": YnisonProtocol.player(playback, device: deviceID)]],
                           on: socket, intercept: !here)
        } else {
            try await send(["update_playing_status": ["playing_status": YnisonProtocol.status(playback, device: deviceID)]], on: socket)
        }
    }

    private func receive(_ incoming: State, turn: Int) {
        let previous = state
        guard previous != incoming else { return }
        receivedAt = .now
        state = incoming
        let player = Player.shared
        if incoming.active != deviceID {
            applying?.cancel()
            applying = nil
            if incoming.active != nil, incoming.active != previous.active, player.isPlaying, !working {
                player.pause()
                sent = (player.ynisonPlayback(), .now)
            }
            return
        }
        guard !working else { return }
        let activatedHere = previous.active != deviceID
        let queueChanged = incoming.queueBy != deviceID && (incoming.queueVersion != previous.queueVersion
            || activatedHere || !incoming.playback.sameQueue(as: previous.playback))
        let fallbackStatusChanged = incoming.statusVersion == nil
            && (incoming.playback.paused != previous.playback.paused || incoming.playback.position != previous.playback.position)
        let statusChanged = incoming.statusBy != deviceID
            && (incoming.statusVersion != previous.statusVersion || activatedHere || fallbackStatusChanged)
        guard queueChanged || statusChanged, incoming.playback.current != nil else { return }
        applying?.cancel()
        applying = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.applying = nil } }
            do {
                try await apply(incoming.playback, at: receivedAt) {
                    guard self.epoch == turn, self.state.active == self.deviceID else { return false }
                    return self.state.queueVersion == incoming.queueVersion && self.state.statusVersion == incoming.statusVersion
                }
                sent = (player.ynisonPlayback(), .now)
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }

    func transfer(to id: String) async {
        guard connection == .connected, let socket, !working, id != state.active else { return }
        guard id == deviceID || state.devices.contains(where: { $0.id == id }) else { return }
        working = true
        let turn = epoch
        let wasPlaying = Player.shared.isPlaying
        defer { if turn == epoch { working = false } }
        do {
            if id == deviceID {
                let incoming = state
                if incoming.playback.current != nil, incoming.active != nil {
                    try await apply(incoming.playback, at: receivedAt, play: true) {
                        self.epoch == turn && self.socket === socket && self.state.active == incoming.active
                            && self.state.queueVersion == incoming.queueVersion
                    }
                } else if Player.shared.current != nil {
                    Player.shared.resume()
                } else {
                    throw TuneError("На устройствах пока ничего не играет")
                }
                let local = Player.shared.ynisonPlayback()
                sent = (local, .now)
                try await send(["update_player_state": ["player_state": YnisonProtocol.player(local, device: deviceID)]],
                               on: socket, intercept: true)
            } else {
                if state.active == nil || state.active == deviceID {
                    let local = Player.shared.ynisonPlayback()
                    guard local.current != nil else { throw TuneError("Сначала включите музыку") }
                    try await send(["update_player_state": ["player_state": YnisonProtocol.player(local, device: deviceID)]], on: socket)
                }
                try await send(["update_active_device": ["device_id_optional": id]], on: socket)
                if epoch == turn, Player.shared.isPlaying {
                    Player.shared.pause()
                    sent = (Player.shared.ynisonPlayback(), .now)
                }
            }
        } catch {
            if epoch == turn, !(error is CancellationError) {
                if id == deviceID, !wasPlaying, state.active != deviceID, Player.shared.isPlaying {
                    Player.shared.pause()
                    sent = (Player.shared.ynisonPlayback(), .now)
                }
                errorText = error.localizedDescription
            }
        }
    }

    func controlRemote(paused: Bool? = nil, offset: Int? = nil) async {
        guard let active = state.active, active != deviceID, let socket, !working, connection == .connected else { return }
        var playback = state.playback
        guard let index = playback.index else { return }
        playback.position = playback.predicted(after: Date().timeIntervalSince(receivedAt))
        working = true
        let turn = epoch
        defer { if turn == epoch { working = false } }
        do {
            if let offset, playback.songs.indices.contains(index + offset) {
                playback.index = index + offset
                playback.position = 0
                playback.duration = 0
                try await send(["update_player_state": ["player_state": YnisonProtocol.player(playback, device: deviceID)]], on: socket)
            } else if let paused {
                playback.paused = paused
                try await send(["update_playing_status": ["playing_status": YnisonProtocol.status(playback, device: deviceID)]], on: socket)
            }
        } catch {
            if epoch == turn, !(error is CancellationError) { errorText = error.localizedDescription }
        }
    }

    private func apply(_ playback: Playback, at time: Date, play: Bool = false, stillCurrent: () -> Bool) async throws {
        guard let originalIndex = playback.index, playback.current != nil else {
            throw TuneError("Устройство не прислало текущий трек")
        }
        let player = Player.shared
        let same = playback.songs.map(\.id) == player.queue.map(\.id)
        let tracks: [Track]
        let target: Int?
        if same {
            tracks = player.queue
            target = originalIndex
        } else {
            var loaded: [Track] = []
            for chunk in playback.songs.map(\.id).filter({ !$0.isEmpty }).chunked(100) {
                loaded += try await API.shared.tracks(ids: chunk)
                try Task.checkCancellation()
                guard stillCurrent() else { throw CancellationError() }
            }
            let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let available = playback.songs.enumerated().compactMap { offset, song in
                byID[song.id].map { (sourceIndex: offset, track: $0) }
            }
            tracks = available.map(\.track)
            target = available.firstIndex { $0.sourceIndex == originalIndex }
        }
        guard let target, tracks.indices.contains(target) else { throw TuneError("Этот трек недоступен на iPhone") }
        try Task.checkCancellation()
        guard stillCurrent() else { throw CancellationError() }
        let position = playback.predicted(after: Date().timeIntervalSince(time))
        player.applyYnison(tracks: tracks, index: target, position: position, playing: play || !playback.paused,
                           entity: playback.entityType, entityID: playback.entityID)
    }

    private struct HubError: Error { let retryAfter: Int? }
}

private final class YnisonSocketDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
