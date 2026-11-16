import AppKit
import Combine
import Foundation
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case mixer
    case fx
    case snapshots
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixer: return "Микшер"
        case .fx: return "FX"
        case .snapshots: return "Снапшоты"
        case .settings: return "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .mixer: return "slider.vertical.3"
        case .fx: return "waveform.path.ecg"
        case .snapshots: return "square.stack.3d.up"
        case .settings: return "gearshape"
        }
    }
}

enum SyncState: Equatable {
    case idle
    case connecting
    case syncing
    case synced(Date)
    case failed(String)
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
final class MixerModel: ObservableObject {
    // MARK: - Mixer state

    @Published var channels: [ChannelState]
    @Published var buses: [BusState]
    @Published var fx: [FXSlotState]

    @Published var snapshotNames: [String?] = Array(repeating: nil, count: 15)
    @Published var currentSnapshot: Int?
    @Published var fxMuted = false
    @Published var tapBPM: Double?

    // MARK: - Connection / sync state

    @Published private(set) var bleConnected = false
    private var cancellables = Set<AnyCancellable>()

    /// BLE is the only transport now; the UI is locked when it is unavailable.
    var isMixerConnected: Bool {
        if ProcessInfo.processInfo.environment["FLOW8_UI_UNLOCKED"] != nil { return true }
        return bleConnected
    }
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var lastSyncDate: Date?
    @Published var autoSync: Bool {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") }
    }
    @Published var isLoggingEnabled: Bool {
        didSet { UserDefaults.standard.set(isLoggingEnabled, forKey: "appLog") }
    }

    @Published private(set) var log: [LogEntry] = []
    @Published var tab: MainTab = .mixer

    @Published var hiddenChannels: Set<Int> = [] {
        didSet { UserDefaults.standard.set(Array(hiddenChannels), forKey: "hiddenChannels") }
    }
    @Published var hiddenBuses: Set<Int> = [] {
        didSet { UserDefaults.standard.set(Array(hiddenBuses), forKey: "hiddenBuses") }
    }

    /// When off, the FX 1 / FX 2 strips disappear from the mixer.
    @Published var showsFXChannels: Bool {
        didSet { UserDefaults.standard.set(showsFXChannels, forKey: "showsFXChannels") }
    }

    /// When enabled, Mon 1 and Mon 2 are treated as one stereo pair.
    @Published var appLanguage: String = UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
        didSet { UserDefaults.standard.set(appLanguage, forKey: "appLanguage") }
    }

    var appLocale: Locale {
        appLanguage == "system" ? Locale.current : Locale(identifier: appLanguage)
    }

    @Published var monStereoLinked: Bool = false {
        didSet { UserDefaults.standard.set(monStereoLinked, forKey: "monStereoLinked") }
    }

    @Published private(set) var mainMeterL: Double = 0
    @Published private(set) var mainMeterR: Double = 0
    @Published private(set) var inputMeters: [Double] = Array(repeating: 0, count: 7)
    @Published private(set) var busMeters: [Double] = Array(repeating: 0, count: 5)

    /// Send parameter changes over Bluetooth when connected.
    @Published var bleControl: Bool {
        didSet { UserDefaults.standard.set(bleControl, forKey: "bleControl") }
    }
    /// Re-read the mixer state periodically so hardware changes show up.
    @Published var continuousSync: Bool {
        didSet {
            UserDefaults.standard.set(continuousSync, forKey: "continuousSync")
            updateSyncTimer()
        }
    }
    /// Seconds between automatic state polls. Smaller = more responsive, more traffic.
    @Published var syncInterval: Double {
        didSet {
            UserDefaults.standard.set(syncInterval, forKey: "syncInterval")
            updateSyncTimer()
        }
    }
    private var syncTimer: Timer?
    private var syncInFlight = false
    /// While the user drags a control, incoming dumps must not overwrite local values.
    private var suppressSyncUntil = Date.distantPast

    private var recentWrites: [(Data, Date)] = []
    private var pushQueue: [[UInt8]] = []
    private var pushScheduled = false
    private var didPushState = false

    /// Sends the locally cached state to the mixer after connecting — the same
    /// behaviour as the official app, which restores its scene over BLE.
    private func pushStateToMixer(attempt: Int = 0) {
        guard !didPushState,
              ProcessInfo.processInfo.environment["FLOW8_NO_PUSH"] == nil else { return }
        guard canSend else {
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.pushStateToMixer(attempt: attempt + 1)
                }
            }
            return
        }
        didPushState = true
        var packets: [[UInt8]] = []
        let eqFreq: [(UInt8, UInt8, UInt8)] = [
            (0x00, 0x64, 0x00), (0x01, 0xF4, 0x06), (0x07, 0xD0, 0x06), (0x2E, 0xE0, 0x00)
        ]
        let geq: [(UInt8, UInt8)] = [
            (0x00, 0x3F), (0x00, 0x7D), (0x00, 0xFA), (0x01, 0xF4), (0x03, 0xE8),
            (0x07, 0xD0), (0x0F, 0xA0), (0x1F, 0x40), (0x3E, 0x80)
        ]
        for ch in channels {
            let c = UInt8(ch.id)
            packets.append([0x06, 0x01, c, 0x0F, BLETables.ble(.level, ch.level)])
            for (i, target) in [UInt8(0x0A), 0x0B, 0x0C, 0x0D].enumerated() {
                packets.append([0x06, 0x01, c, target, BLETables.ble(.level, ch.sends[i])])
            }
            packets.append([0x00, 0x01, c, BLETables.ble(.pan, ch.pan)])
            if ch.hasGain { packets.append([0x02, 0x01, c, BLETables.ble(.gain, ch.gain)]) }
            if ch.hasLowCut {
                let hz = BLETables.ble(.lowcut, ch.lowCut)
                packets.append([0x04, 0x01, c, 0x00, hz >> 8, hz & 0xFF])
            }
            for band in 0..<4 {
                let f = eqFreq[band]
                packets.append([0x09, 0x01, c, UInt8(band), f.0, f.1, f.2, BLETables.ble(.eq, ch.eq[band])])
            }
            if ch.hasCompressor {
                let percent = Int((Double(ch.comp) / 100.0 * 127.0).rounded())
                packets.append([0x13, 0x01, c, BLETables.ble(.comp, min(127, max(0, percent)))])
            }
            if ch.hasPhantom { packets.append([0x15, 0x01, c, ch.phantom ? 1 : 0]) }
            packets.append([0x08, 0x01, c, ch.mute ? 1 : 0])
            packets.append([0x01, 0x01, c, ch.solo ? 1 : 0])
        }
        for bus in buses {
            let b = Self.bleBusId(bus.id)
            packets.append([0x06, 0x01, b, b, BLETables.ble(.level, bus.level)])
            if bus.kind.hasBalance {
                packets.append([0x00, 0x01, 0x0F, UInt8(min(254, max(0, bus.balance * 2 - 2)))])
            }
            if bus.kind.hasLimiter {
                packets.append([0x14, 0x01, b, BLETables.ble(.limiter, bus.limiter)])
            }
            if bus.kind.hasEQ {
                for band in 0..<9 {
                    let f = geq[band]
                    packets.append([0x03, 0x01, b, UInt8(band), f.0, f.1, 0x08, BLETables.ble(.eq, bus.eq[band])])
                }
            }
        }
        for slot in 0..<min(2, fx.count) {
            let address: UInt8 = slot == 0 ? 0x0C : 0x0D
            packets.append([0x31, 0x01, address, UInt8(max(0, fx[slot].preset - 1))])
            let p1 = UInt8((Double(fx[slot].param1) / 100.0 * 127.0).rounded())
            packets.append([0x11, 0x01, address, p1, fx[slot].param2 ? 1 : 0, 0x00, 0x01])
        }
        packets.append([0x08, 0x01, 0x0C, fxMuted ? 1 : 0])
        packets.append([0x08, 0x01, 0x0D, fxMuted ? 1 : 0])
        pushQueue = packets
        schedulePush()
        appendLog("Сцена отправлена в микшер (\(packets.count) команд)")
    }

    private func schedulePush() {
        guard !pushScheduled, !pushQueue.isEmpty else { return }
        pushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            guard let self else { return }
            self.pushScheduled = false
            guard !self.pushQueue.isEmpty else { return }
            self.ble.sendRaw(self.pushQueue.removeFirst())
            self.schedulePush()
        }
    }

    private func markInteraction() {
        suppressSyncUntil = Date().addingTimeInterval(1.2)
    }

    private var syncTimeout: DispatchWorkItem?
    private var verifyStage = 0
    private var verifyBaseline: DumpSnapshot?

    let ble = BLELink.shared

    // MARK: - Init

    private struct PersistedState: Codable {
        var channels: [ChannelState]
        var buses: [BusState]
        var fx: [FXSlotState]
        var snapshotNames: [String?]
        var currentSnapshot: Int?
    }

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("FLOW8", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private var stateSaveWork: DispatchWorkItem?

    private func scheduleStateSave() {
        stateSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveStateNow()
        }
        stateSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveStateNow() {
        let blob = PersistedState(channels: channels, buses: buses, fx: fx,
                                  snapshotNames: snapshotNames, currentSnapshot: currentSnapshot)
        do {
            let data = try JSONEncoder().encode(blob)
            try data.write(to: Self.stateURL, options: .atomic)
            try? "ok \(Self.stateURL.path)\n".write(toFile: "/tmp/flow8-save.log", atomically: true, encoding: .utf8)
        } catch {
            try? "err \(error) \(Self.stateURL.path)\n".write(toFile: "/tmp/flow8-save.log", atomically: true, encoding: .utf8)
        }
    }

    private func loadPersistedState() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let blob = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        channels = blob.channels
        buses = blob.buses
        fx = blob.fx
        snapshotNames = blob.snapshotNames
        if let snapshot = blob.currentSnapshot { currentSnapshot = snapshot }
    }

    init() {
        channels = Self.defaultChannels()
        buses = Self.defaultBuses()
        fx = [FXSlotState(id: 0), FXSlotState(id: 1)]

        autoSync = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true
        bleControl = UserDefaults.standard.object(forKey: "bleControl") as? Bool ?? true
        continuousSync = UserDefaults.standard.object(forKey: "continuousSync") as? Bool ?? true
        syncInterval = UserDefaults.standard.object(forKey: "syncInterval") as? Double ?? 0.25
        hiddenChannels = Set(UserDefaults.standard.array(forKey: "hiddenChannels") as? [Int] ?? [])
        hiddenBuses = Set(UserDefaults.standard.array(forKey: "hiddenBuses") as? [Int] ?? [])
        showsFXChannels = UserDefaults.standard.object(forKey: "showsFXChannels") as? Bool ?? true
        monStereoLinked = UserDefaults.standard.object(forKey: "monStereoLinked") as? Bool ?? false
        isLoggingEnabled = UserDefaults.standard.bool(forKey: "appLog")
        loadChannelNames()

        setupBLE()
        loadPersistedState()
        saveStateNow()

        if ProcessInfo.processInfo.environment["FLOW8_FAKE_METERS"] != nil {
            let values: [Double] = [0.78, 0.52, 0.9, 0.34, 0.62, 0.44, 0.7]
            for index in values.indices { inputMeters[index] = values[index] }
            mainMeterL = 0.86
            mainMeterR = 0.66
        }

        if autoSync {
            connectBluetooth()
        }
        updateSyncTimer()
    }

    private static func defaultChannels() -> [ChannelState] {
        let names = ["Ch 1", "Ch 2", "Ch 3", "Ch 4", "Ch 5/6", "Ch 7/8", "USB / BT"]
        let kinds: [InputKind] = [.xlr, .xlr, .combo, .combo, .line, .line, .usbBT]
        return (0..<7).map { index in
            ChannelState(
                id: index,
                name: names[index],
                kind: kinds[index],
                isStereo: index >= 4
            )
        }
    }

    private static func defaultBuses() -> [BusState] {
        [7, 8, 9, 10, 11].map { id in
            BusState(id: id, kind: BusKind(rawValue: id) ?? .main)
        }
    }

    // MARK: - BLE / sync

    private func setupBLE() {
        ble.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.bleConnected = (state == .connected)
                if ProcessInfo.processInfo.environment["FLOW8_PRINT_STATE"] != nil {
                    print("BLESTATE \(state) connected=\(state == .connected)")
                }
            }
            .store(in: &cancellables)
        ble.onReady = { [weak self] in
            Task { @MainActor in
                self?.appendLog("Bluetooth: сессия установлена")
                if self?.syncState == .connecting {
                    self?.syncState = .syncing
                }
                if ProcessInfo.processInfo.environment["FLOW8_PUSH_STATE"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard let self, self.ble.isConnected else { return }
                        self.pushStateToMixer()
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB8"] != nil {
                    let seq: [(Double, [UInt8])] = [
                        (2.0,[0x03,0x01,0x0F,0x01,0x00,0x7D,0x08,0x7F]),
                        (3.5,[0x03,0x01,0x0F,0x08,0x3E,0x80,0x08,0x7F]),
                        (5.0,[0x03,0x01,0x0A,0x00,0x00,0x3F,0x08,0x7F]),
                        (6.5,[0x03,0x01,0x0B,0x00,0x00,0x3F,0x08,0x7F])
                    ]
                    for (delay, packet) in seq {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.ble.sendRaw(packet)
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB7"] != nil {
                    let seq: [(Double, [UInt8])] = [
                        (2.0,[0x03,0x01,0x0F,0x01,0x00,0x7D,0x08,0xFE]),
                        (4.0,[0x03,0x01,0x0F,0x08,0x3E,0x80,0x08,0xFE]),
                        (6.0,[0x03,0x01,0x0A,0x00,0x00,0x3F,0x08,0xFE]),
                        (8.0,[0x03,0x01,0x0B,0x00,0x00,0x3F,0x08,0xFE])
                    ]
                    for (delay, packet) in seq {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.ble.sendRaw(packet)
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB6"] != nil {
                    var packets: [[UInt8]] = []
                    for ch in UInt8(0)...6 {
                        packets.append([0x00,0x01,ch,0x7F])
                        for band in UInt8(0)...3 { packets.append([0x09,0x01,ch,band,0x00,0x64,0x00,0x7F]) }
                    }
                    packets.append([0x00,0x01,0x0F,0x7E])
                    for fx in [UInt8(0x0C),0x0D] {
                        packets.append([0x31,0x01,fx,0x00])
                        packets.append([0x11,0x01,fx,0x40,0x00,0x00,0x01])
                    }
                    for (i,pkt) in packets.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.03) { [weak self] in
                            self?.ble.sendRaw(pkt)
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB5"] != nil {
                    var packets: [[UInt8]] = []
                    for ch in UInt8(0)...6 { packets.append([0x06,ch,0x0F,0x92]) }
                    packets.append([0x06,0x0F,0x0F,0x92])
                    for b in [UInt8(0x0A),0x0B,0x0C,0x0D] { packets.append([0x06,b,b,0x92]) }
                    packets.append([0x00,0x01,0x0F,0x7E])
                    packets.append([0x14,0x01,0x0F,0x78])
                    for ch in UInt8(0)...6 {
                        packets.append([0x08,0x01,ch,0x00])
                        packets.append([0x01,0x01,ch,0x00])
                    }
                    for (i,pkt) in packets.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.03) { [weak self] in
                            let full: [UInt8] = [pkt[0], 0x01] + pkt.dropFirst()
                            self?.ble.sendRaw(full)
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB4"] != nil {
                    let seq: [(Double, [UInt8])] = [
                        (3, [0x00,0x01,0x06,0x00]),
                        (5, [0x09,0x01,0x06,0x01,0x01,0xF4,0x06,0xFC]),
                        (7, [0x08,0x01,0x06,0x01]),
                        (9, [0x01,0x01,0x06,0x01]),
                        (11,[0x06,0x01,0x06,0x0A,0x40])
                    ]
                    for (delay, packet) in seq {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.ble.sendRaw(packet)
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB3"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        self?.ble.sendRaw([0x09,0x01,0x06,0x00,0x00,0x64,0x00,0xFC])
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB2"] != nil {
                    let seq: [(Double, [UInt8])] = [
                        (3, [0x00,0x01,0x00,0x00]),
                        (5, [0x02,0x01,0x00,0x50]),
                        (7, [0x04,0x01,0x00,0x00,0x00,0x14]),
                        (9, [0x09,0x01,0x00,0x00,0x00,0x64,0x00,0xFE]),
                        (11,[0x13,0x01,0x00,0xFF]),
                        (13,[0x08,0x01,0x00,0x01]),
                        (15,[0x01,0x01,0x00,0x01]),
                        (17,[0x06,0x01,0x00,0x0A,0x40]),
                        (19,[0x06,0x01,0x0F,0x0F,0x40]),
                        (21,[0x00,0x01,0x0F,0xC0]),
                        (23,[0x14,0x01,0x0F,0x78]),
                        (25,[0x11,0x01,0x0C,0x40,0x01,0x00,0x01]),
                        (27,[0x31,0x01,0x0C,0x03]),
                        (29,[0x06,0x01,0x0A,0x0A,0x40]),
                        (31,[0x03,0x01,0x0F,0x00,0x00,0x3F,0x08,0xFE])
                    ]
                    for (delay, packet) in seq {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.ble.sendRaw(packet)
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_CALIB"] != nil {
                    for (i, ch) in [0, 1, 2].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0 + Double(i) * 3.0) { [weak self] in
                            self?.ble.sendMasterCommand(channel: UInt8(ch), destination: 0x0F, value: 0x20)
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["FLOW8_BLE_PROBE"] != nil {
                    self?.runBLEProbe()
                }
                if ProcessInfo.processInfo.environment["FLOW8_BLE_QUERY"] != nil {
                    self?.runBLEQuery()
                }
                if ProcessInfo.processInfo.environment["FLOW8_BLE_QUERYSCAN"] != nil {
                    self?.runQueryScan()
                }
                if ProcessInfo.processInfo.environment["FLOW8_BLE_SCAN"] != nil {
                    self?.runBLEScan()
                }
                if ProcessInfo.processInfo.environment["FLOW8_BLE_CTX"] != nil {
                    self?.runContextBruteForce()
                }
            }
        }
        ble.onSnapshotNames = { [weak self] names in
            Task { @MainActor in
                guard let self else { return }
                var padded = names
                while padded.count < 15 { padded.append(nil) }
                self.snapshotNames = Array(padded.prefix(15))
            }
        }
        ble.onDumpRequested = { [weak self] in
            Task { @MainActor in self?.scheduleSyncTimeout() }
        }
        ble.onMetering = { [weak self] data in
            Task { @MainActor in self?.updateMetering(data) }
        }
        ble.onWrite = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                self.recentWrites.append((data, now))
                self.recentWrites.removeAll { now.timeIntervalSince($0.1) > 3 }
            }
        }
        ble.onParameter = { [weak self] type, data in
            Task { @MainActor in self?.applyBLEParameter(type: type, data: data) }
        }
        ble.onDump = { [weak self] data in
            Task { @MainActor in self?.applyBLEDump(data) }
        }
    }

    private func runQueryScan() {
        for id in 0...255 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(id) * 0.05) { [weak self] in
                self?.ble.queryParameter(UInt8(id))
            }
        }
    }

    func connectBluetooth() {
        guard syncState != .connecting, syncState != .syncing else { return }
        syncState = .connecting
        ble.connect()
        scheduleSyncTimeout()
    }

    func syncNow(silent: Bool = false) {
        if silent && syncInFlight { return }
        if !silent {
            appendLog("Запрос состояния микшера")
        }
        if ble.isConnected {
            if !silent { syncState = .syncing }
            syncInFlight = true
            ble.requestBLEState()
            scheduleSyncTimeout()
        } else {
            if !silent { syncState = .connecting }
            ble.connect()
            scheduleSyncTimeout()
        }
    }

    private func scheduleSyncTimeout() {
        syncTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncInFlight = false
                if case .syncing = self.syncState {
                    // No USB SysEx dump: in BLE-only mode live notifications are
                    // the sync channel, so this is not an error.
                    self.syncState = .failed("нет ответа от микшера")
                } else if case .connecting = self.syncState {
                    self.syncState = .failed("Bluetooth не отвечает")
                }
            }
        }
        syncTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
    }

    private var dumpCounter = 0

    private func handleSysEx(_ data: Data) {
        if ProcessInfo.processInfo.environment["FLOW8_SAVE_DUMP"] != nil {
            let path = "/tmp/flow8-dump-\(dumpCounter).bin"
            dumpCounter += 1
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if ProcessInfo.processInfo.environment["FLOW8_SYNC_RATE"] != nil {
            print("SYSEX \(data.count)")
        }
        guard let snapshot = SysExParser.parse(data) else {
            appendLog("Не удалось разобрать SysEx-дамп")
            return
        }
        apply(snapshot)
        if ProcessInfo.processInfo.environment["FLOW8_PRINT_STATE"] != nil {
            print("STATE bus=\(snapshot.busLevels) lim=\(snapshot.busLimiters) bal=\(snapshot.busBalances) fx=\(snapshot.fx.map { "p1=\($0.param1) p2=\($0.param2)" }) levels=\(snapshot.levels)")
        }
        let env = ProcessInfo.processInfo.environment
        if env["FLOW8_BLE_RAW"] != nil {
            runRawTest(snapshot)
        } else if env["FLOW8_METER_TEST"] != nil {
            runMeterTest(snapshot)
        } else if env["FLOW8_BLE_BUS_TEST"] != nil {
            runBusTest(snapshot)
        } else if env["FLOW8_BLE_MAP"] != nil {
            runMap(snapshot)
        } else if env["FLOW8_BLE_VERIFY"] != nil || env["FLOW8_BLE_CH_TEST"] != nil {
            runVerify(snapshot)
        }
        if ProcessInfo.processInfo.environment["FLOW8_PRINT_STATE"] != nil {
            print("STATE bus=\(snapshot.busLevels) lim=\(snapshot.busLimiters) bal=\(snapshot.busBalances) fx=\(snapshot.fx.map { "p1=\($0.param1) p2=\($0.param2)" }) levels=\(snapshot.levels)")
        }
        if ProcessInfo.processInfo.environment["FLOW8_SYNC_RATE"] != nil {
            print("SYNC \(Date().timeIntervalSince1970)")
        }
        if ProcessInfo.processInfo.environment["FLOW8_PRINT_STATE"] != nil {
            print("BLEDUMP levels=\(channels.map(\.level)) lowcut=\(channels.map(\.lowCut)) buses=\(buses.map { "\($0.id):\($0.level)" }) fx=\(fx.map { "p1=\($0.param1) p2=\($0.param2) pr=\($0.preset)" })")
        }
        syncInFlight = false
        syncTimeout?.cancel()
        syncState = .synced(Date())
        if continuousSync {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                guard self.continuousSync, self.ble.isConnected, !self.syncInFlight else { return }
                guard Date() >= self.suppressSyncUntil else { return }
                self.syncNow(silent: true)
            }
        }
        lastSyncDate = Date()
        appendLog("Состояние синхронизировано (\(data.count) байт)")
    }

    private func runVerify(_ snapshot: DumpSnapshot) {
        if let raw = ProcessInfo.processInfo.environment["FLOW8_BLE_CH_TEST"], let _ = Int(raw) {
            runChannelTest(snapshot)
            return
        }
        switch verifyStage {
        case 0:
            verifyBaseline = snapshot
            verifyStage = 1
            print("VERIFY baseline levelCC=\(snapshot.levels[0]) gains=\(snapshot.gains[0]) eq=\(snapshot.eqs[0])")
            BLELink.shared.sendParameter(channel: 1, param: 0x0F, value: 0xFF)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.syncNow() }
        case 1:
            verifyStage = 2
            print("VERIFY after BLE 0xFF levelCC=\(snapshot.levels[0])")
            BLELink.shared.sendParameter(channel: 1, param: 0x0F, value: 0x00)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.syncNow() }
        case 2:
            verifyStage = 3
            print("VERIFY after BLE 0x00 levelCC=\(snapshot.levels[0])")
            if let baseline = verifyBaseline {
                setLevel(channel: 0, value: baseline.levels[0])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        default:
            break
        }
    }

    private var chTestIndex = 0
    private var chTestBaseline: DumpSnapshot?

    private func runChannelTest(_ snapshot: DumpSnapshot) {
        if chTestBaseline == nil {
            chTestBaseline = snapshot
            print("CHTEST baseline levels=\(snapshot.levels)")
            sendChannelProbe()
            return
        }
        print("CHTEST after ch\(chTestIndex) levels=\(snapshot.levels)")
        restoreLevelsFromBaseline()
        chTestIndex += 1
        if chTestIndex < 3 {
            sendChannelProbe()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    private func sendChannelProbe() {
        let channel = chTestIndex
        print("CHTEST probe channel byte \(channel) as ch\(channel + 1)")
        BLELink.shared.sendParameter(channel: UInt8(channel), param: 0x0F, value: 0xFF)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.syncNow() }
    }

    private func restoreLevelsFromBaseline() {
        guard let baseline = chTestBaseline else { return }
        for index in channels.indices where index < baseline.levels.count {
            setLevel(channel: index, value: baseline.levels[index])
        }
    }

    // MARK: - BLE parameter mapping (calibration)

    private var mapChannel: UInt8 = 6
    private var mapIDs: [UInt8] = []
    private var mapIndex = 0
    private var mapBaseline: DumpSnapshot?
    private var mapResults: [[String: Any]] = []
    private var mapWaiting = false
    private var mapTimeout: DispatchWorkItem?
    private var mapProbeValue: UInt8 = 0

    private func runMap(_ snapshot: DumpSnapshot) {
        if mapIDs.isEmpty {
            let env = ProcessInfo.processInfo.environment
            mapChannel = UInt8(env["FLOW8_BLE_MAP"] ?? "6") ?? 6
            mapProbeValue = UInt8(env["FLOW8_BLE_MAP_VALUE"] ?? "0") ?? 0
            let from = UInt8(env["FLOW8_BLE_MAP_FROM"] ?? "1") ?? 1
            let to = UInt8(env["FLOW8_BLE_MAP_TO"] ?? "48") ?? 48
            mapIDs = Array(from...max(from, to))
            print("MAP channel=\(mapChannel) ids=\(from)...\(to) value=\(mapProbeValue)")
        }

        if mapBaseline == nil {
            mapBaseline = snapshot
            print("MAP baseline levels=\(snapshot.levels) gains=\(snapshot.gains)")
            nextMapProbe()
            return
        }

        guard mapWaiting, let baseline = mapBaseline else { return }
        mapWaiting = false
        mapTimeout?.cancel()

        let id = mapIDs[mapIndex - 1]
        let changes = diffFields(baseline, snapshot)
        mapResults.append(["param": Int(id), "changes": changes])
        print("MAP param \(id): \(changes.isEmpty ? "no change" : changes.joined(separator: " | "))")

        restoreAll(from: baseline)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.nextMapProbe()
        }
    }

    private func nextMapProbe() {
        guard mapIndex < mapIDs.count else {
            finishMap()
            return
        }
        let id = mapIDs[mapIndex]
        mapIndex += 1
        BLELink.shared.sendParameter(channel: mapChannel, param: id, value: mapProbeValue)
        mapWaiting = true

        let timeout = DispatchWorkItem {
            guard self.mapWaiting else { return }
            self.mapWaiting = false
            print("MAP param \(id): timeout")
            if let baseline = self.mapBaseline {
                self.restoreAll(from: baseline)
            }
            self.nextMapProbe()
        }
        mapTimeout?.cancel()
        mapTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: timeout)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.syncNow()
        }
    }

    private func finishMap() {
        print("MAP done")
        let payload: [String: Any] = [
            "channel": Int(mapChannel),
            "value": Int(mapProbeValue),
            "results": mapResults
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/flow8-map.json"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    private func diffFields(_ a: DumpSnapshot, _ b: DumpSnapshot) -> [String] {
        var out: [String] = []
        for i in 0..<min(a.levels.count, b.levels.count) {
            if a.levels[i] != b.levels[i] { out.append("level\(i + 1):\(a.levels[i])->\(b.levels[i])") }
            if i < a.gains.count, i < b.gains.count, a.gains[i] != b.gains[i] { out.append("gain\(i + 1):\(a.gains[i])->\(b.gains[i])") }
            if i < a.pans.count, i < b.pans.count, a.pans[i] != b.pans[i] { out.append("pan\(i + 1):\(a.pans[i])->\(b.pans[i])") }
            if i < a.comps.count, i < b.comps.count, a.comps[i] != b.comps[i] { out.append("comp\(i + 1):\(a.comps[i])->\(b.comps[i])") }
            if i < a.lowCuts.count, i < b.lowCuts.count, a.lowCuts[i] != b.lowCuts[i] { out.append("lowcut\(i + 1):\(a.lowCuts[i])->\(b.lowCuts[i])") }
            if i < a.mutes.count, i < b.mutes.count, a.mutes[i] != b.mutes[i] { out.append("mute\(i + 1):\(a.mutes[i])->\(b.mutes[i])") }
            if i < a.solos.count, i < b.solos.count, a.solos[i] != b.solos[i] { out.append("solo\(i + 1):\(a.solos[i])->\(b.solos[i])") }
            if i < a.phantoms.count, i < b.phantoms.count, a.phantoms[i] != b.phantoms[i] { out.append("phantom\(i + 1):\(a.phantoms[i])->\(b.phantoms[i])") }
            if i < a.eqs.count, i < b.eqs.count {
                for band in 0..<min(a.eqs[i].count, b.eqs[i].count) where a.eqs[i][band] != b.eqs[i][band] {
                    out.append("eq\(i + 1).\(band):\(a.eqs[i][band])->\(b.eqs[i][band])")
                }
            }
            if i < a.sends.count, i < b.sends.count {
                for send in 0..<min(a.sends[i].count, b.sends[i].count) where a.sends[i][send] != b.sends[i][send] {
                    out.append("send\(i + 1).\(send):\(a.sends[i][send])->\(b.sends[i][send])")
                }
            }
        }
        for i in 0..<min(a.busLevels.count, b.busLevels.count) where a.busLevels[i] != b.busLevels[i] {
            out.append("busLevel\(i):\(a.busLevels[i])->\(b.busLevels[i])")
        }
        for i in 0..<min(a.busBalances.count, b.busBalances.count) where a.busBalances[i] != b.busBalances[i] {
            out.append("busBal\(i):\(a.busBalances[i])->\(b.busBalances[i])")
        }
        for i in 0..<min(a.busLimiters.count, b.busLimiters.count) where a.busLimiters[i] != b.busLimiters[i] {
            out.append("busLim\(i):\(a.busLimiters[i])->\(b.busLimiters[i])")
        }
        for i in 0..<min(a.busEQs.count, b.busEQs.count) {
            for band in 0..<min(a.busEQs[i].count, b.busEQs[i].count) where a.busEQs[i][band] != b.busEQs[i][band] {
                out.append("busEQ\(i).\(band):\(a.busEQs[i][band])->\(b.busEQs[i][band])")
            }
        }
        for i in 0..<min(a.fx.count, b.fx.count) {
            if a.fx[i].preset != b.fx[i].preset { out.append("fxpreset\(i):\(a.fx[i].preset)->\(b.fx[i].preset)") }
            if a.fx[i].param1 != b.fx[i].param1 { out.append("fxparam1\(i):\(a.fx[i].param1)->\(b.fx[i].param1)") }
            if a.fx[i].param2 != b.fx[i].param2 { out.append("fxparam2\(i):\(a.fx[i].param2)->\(b.fx[i].param2)") }
        }
        return out
    }

    private func restoreAll(from baseline: DumpSnapshot) {
        for index in channels.indices {
            guard index < baseline.levels.count else { continue }
            setLevel(channel: index, value: baseline.levels[index])
            if index < baseline.gains.count { setGain(channel: index, value: baseline.gains[index]) }
            if index < baseline.pans.count { setPan(channel: index, value: baseline.pans[index]) }
            if index < baseline.comps.count { setCompressor(channel: index, value: baseline.comps[index]) }
            if index < baseline.lowCuts.count { setLowCut(channel: index, value: baseline.lowCuts[index]) }
            if index < baseline.eqs.count {
                for band in 0..<min(4, baseline.eqs[index].count) {
                    setEQ(channel: index, band: band, value: baseline.eqs[index][band])
                }
            }
            if index < baseline.sends.count {
                for send in 0..<min(4, baseline.sends[index].count) {
                    setSend(channel: index, send: send, value: baseline.sends[index][send])
                }
            }
            if index < baseline.mutes.count, channels[index].mute != baseline.mutes[index] {
                toggleMute(channel: index)
            }
            if index < baseline.solos.count, channels[index].solo != baseline.solos[index] {
                toggleSolo(channel: index)
            }
            if index < baseline.phantoms.count, channels[index].phantom != baseline.phantoms[index] {
                togglePhantom(channel: index)
            }
        }
        for index in buses.indices {
            if index < baseline.busLevels.count { setBusLevel(bus: buses[index].id, value: baseline.busLevels[index]) }
            if index < baseline.busBalances.count { setBusBalance(bus: buses[index].id, value: baseline.busBalances[index]) }
            if index < baseline.busLimiters.count { setBusLimiter(bus: buses[index].id, value: baseline.busLimiters[index]) }
            if index < baseline.busEQs.count {
                for band in 0..<min(9, baseline.busEQs[index].count) {
                    setBusEQ(bus: buses[index].id, band: band, value: baseline.busEQs[index][band])
                }
            }
        }
        for index in fx.indices where index < baseline.fx.count {
            setFXParam1(slot: index, value: baseline.fx[index].param1)
            setFXParam2(slot: index, isOn: baseline.fx[index].param2)
        }
    }

    private var busTestStage = 0
    private var busTestBaseline: DumpSnapshot?

    private func runBusTest(_ snapshot: DumpSnapshot) {
        if busTestStage == 0 {
            busTestBaseline = snapshot
            print("BUSTEST baseline buses=\(snapshot.busLevels) levels=\(snapshot.levels)")
            BLELink.shared.sendParameter(channel: 7, param: 0x0F, value: 0xFF)
            busTestStage = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.syncNow() }
        } else {
            print("BUSTEST after CH=7 0xFF buses=\(snapshot.busLevels)")
            if let baseline = busTestBaseline {
                for index in buses.indices where index < baseline.busLevels.count {
                    setBusLevel(bus: buses[index].id, value: baseline.busLevels[index])
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }

    private var meterBaseline: DumpSnapshot?
    private var meterTestStarted = false

    private func runMeterTest(_ snapshot: DumpSnapshot) {
        if !meterTestStarted {
            meterTestStarted = true
            meterBaseline = snapshot
            setLevel(channel: 6, value: 120)
            if channels[6].mute { toggleMute(channel: 6) }
            setBusLevel(bus: 7, value: 110)
            print("METERTEST setup done, levels=\(snapshot.levels) buses=\(snapshot.busLevels)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if let baseline = self.meterBaseline {
                    self.restoreAll(from: baseline)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            }
        }
    }

    private var rawPackets: [[UInt8]] = []
    private var rawIndex = 0
    private var rawBaseline: DumpSnapshot?
    private var rawWaiting = false
    private var rawResults: [[String: Any]] = []
    private var rawTimeout: DispatchWorkItem?

    private func runRawTest(_ snapshot: DumpSnapshot) {
        if rawPackets.isEmpty {
            let text = ProcessInfo.processInfo.environment["FLOW8_BLE_RAW"] ?? ""
            rawPackets = text.split(separator: ",").compactMap { part in
                let cleaned = part.trimmingCharacters(in: .whitespaces)
                guard cleaned.count % 2 == 0 else { return nil }
                var bytes: [UInt8] = []
                var index = cleaned.startIndex
                while index < cleaned.endIndex {
                    let next = cleaned.index(index, offsetBy: 2)
                    guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
                    bytes.append(byte)
                    index = next
                }
                return bytes
            }
            print("RAW packets count", rawPackets.count)
        }
        if rawBaseline == nil {
            rawBaseline = snapshot
            print("RAW baseline mutes=\(snapshot.mutes) gains=\(snapshot.gains) pans=\(snapshot.pans)")
            nextRaw()
            return
        }
        guard rawWaiting, let baseline = rawBaseline else { return }
        rawWaiting = false
        rawTimeout?.cancel()
        let changes = diffFields(baseline, snapshot)
        rawResults.append(["index": rawIndex - 1, "changes": changes])
        print("RAW packet \(rawIndex - 1): \(changes.isEmpty ? "no change" : changes.joined(separator: " | "))")
        if ProcessInfo.processInfo.environment["FLOW8_BLE_NO_RESTORE"] == nil {
            restoreAll(from: baseline)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.nextRaw() }
    }

    private func nextRaw() {
        guard rawIndex < rawPackets.count else {
            print("RAW done")
            if let data = try? JSONSerialization.data(withJSONObject: rawResults, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/flow8-raw.json"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        let packet = rawPackets[rawIndex]
        rawIndex += 1
        rawWaiting = true
        print("RAW send", packet.map { String(format: "%02x", $0) }.joined(separator: " "))
        BLELink.shared.sendRaw(packet)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.rawWaiting else { return }
            self.rawWaiting = false
            print("RAW timeout", self.rawIndex - 1)
            if let baseline = self.rawBaseline { self.restoreAll(from: baseline) }
            self.nextRaw()
        }
        rawTimeout?.cancel()
        rawTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.syncNow() }
    }

    private func apply(_ snapshot: DumpSnapshot) {
        guard Date() >= suppressSyncUntil, !InteractionGate.isActive else { return }

        var newChannels = channels
        var newBuses = buses
        var newFX = fx

        for index in newChannels.indices {
            guard index < snapshot.levels.count else { break }
            newChannels[index].level = snapshot.levels[index]
            if index < snapshot.gains.count { newChannels[index].gain = snapshot.gains[index] }
            if index < snapshot.pans.count { newChannels[index].pan = snapshot.pans[index] }
            if index < snapshot.comps.count { newChannels[index].comp = snapshot.comps[index] }
            if index < snapshot.lowCuts.count { newChannels[index].lowCut = snapshot.lowCuts[index] }
            if index < snapshot.eqs.count { newChannels[index].eq = snapshot.eqs[index] }
            if index < snapshot.sends.count { newChannels[index].sends = snapshot.sends[index] }
            if index < snapshot.mutes.count { newChannels[index].mute = snapshot.mutes[index] }
            if index < snapshot.solos.count { newChannels[index].solo = snapshot.solos[index] }
            if index < snapshot.phantoms.count {
                newChannels[index].phantom = snapshot.phantoms[index] && newChannels[index].hasPhantom
            }
        }
        for index in newBuses.indices {
            if index < snapshot.busLevels.count { newBuses[index].level = snapshot.busLevels[index] }
            if index < snapshot.busBalances.count { newBuses[index].balance = snapshot.busBalances[index] }
            if index < snapshot.busLimiters.count { newBuses[index].limiter = snapshot.busLimiters[index] }
            if index < snapshot.busEQs.count { newBuses[index].eq = snapshot.busEQs[index] }
        }
        for index in newFX.indices where index < snapshot.fx.count {
            newFX[index] = snapshot.fx[index]
        }

        if newChannels != channels { channels = newChannels }
        if newBuses != buses { buses = newBuses }
        if newFX != fx { fx = newFX }
    }

    /// Decodes the multi-part 0x38 BLE state dump using offsets calibrated on
    /// this mixer (faders, pan, gain, low cut, comp, EQ, sends, buses, FX).
    private func applyBLEDump(_ data: Data) {
        guard Date() >= suppressSyncUntil, !InteractionGate.isActive else { return }
        let d = [UInt8](data)
        guard d.count > 0x160 else { return }
        func raw(_ i: Int) -> UInt8? { d.indices.contains(i) ? d[i] : nil }

        for s in 0..<7 {
            guard let ci = channels.firstIndex(where: { $0.id == s }) else { continue }
            let o = s < 6 ? s * 0x1B : 0xA2
            if let flags = raw(o + 1) {
                channels[ci].mute = flags & 0x01 != 0
                channels[ci].solo = flags & 0x40 != 0
                if s < 6 { channels[ci].phantom = flags & 0x08 != 0 && channels[ci].hasPhantom }
            }
            if s < 6 {
                if let v = raw(o + 2) {
                    channels[ci].gain = BLETables.param(.gain, v, near: channels[ci].gain)
                }
                if let v = raw(o + 3) {
                    // The comp table is indexed by percent, so no rescaling.
                    channels[ci].comp = BLETables.param(.comp, v, near: channels[ci].comp)
                }
                if let lo = raw(o + 4), let hi = raw(o + 5) {
                    // The state dump stores low cut little-endian, unlike the
                    // command that takes it big-endian.
                    channels[ci].lowCut = BLETables.param(.lowcut, Int(lo) | (Int(hi) << 8),
                                                         near: channels[ci].lowCut)
                }
            }
            if let v = raw(o + 6) {
                channels[ci].pan = BLETables.param(.pan, v, near: channels[ci].pan)
            }
            for band in 0..<4 {
                if let v = raw(o + 7 + band) {
                    channels[ci].eq[band] = BLETables.param(.eq, v, near: channels[ci].eq[band])
                }
            }
            if let v = raw(0xC2 + s) {
                channels[ci].level = BLETables.param(.level, v, near: channels[ci].level)
            }
            let sends: [(Int, Int)] = [(0xF6, 0), (0x12A, 1), (0x161, 2), (0x172, 3)]
            for (base, idx) in sends where d.indices.contains(base + s) {
                channels[ci].sends[idx] = BLETables.param(.level, d[base + s],
                                                        near: channels[ci].sends[idx])
            }
        }

        if let mi = buses.firstIndex(where: { $0.id == 7 }) {
            if let v = raw(0xBF) { buses[mi].level = BLETables.param(.level, v, near: buses[mi].level) }
            if let v = raw(0xC0) {
                buses[mi].balance = v == 0 ? 0 : min(127, max(0, (Int(v) + 2) / 2))
            }
            if let v = raw(0xC1) {
                buses[mi].limiter = BLETables.param(.limiter, v, near: buses[mi].limiter)
            }
            for band in 0..<9 where d.indices.contains(0xC9 + band) {
                buses[mi].eq[band] = BLETables.param(.eq, d[0xC9 + band], near: buses[mi].eq[band])
            }
        }
        for (busID, base) in [(8, 0xF3), (9, 0x127)] {
            guard let bi = buses.firstIndex(where: { $0.id == busID }) else { continue }
            if let v = raw(base) { buses[bi].level = BLETables.param(.level, v, near: buses[bi].level) }
            if let v = raw(base + 2) {
                buses[bi].limiter = BLETables.param(.limiter, v, near: buses[bi].limiter)
            }
            for band in 0..<9 where d.indices.contains(base + 0x0A + band) {
                buses[bi].eq[band] = BLETables.param(.eq, d[base + 0x0A + band], near: buses[bi].eq[band])
            }
        }
        for (slot, base) in [(0, 0x15D), (1, 0x16E)] {
            guard fx.indices.contains(slot) else { continue }
            if let v = raw(base) {
                let current = Int((Double(fx[slot].param1) / 100.0 * 127.0).rounded())
                let position = BLETables.param(.fxparam, v, near: current)
                fx[slot].param1 = Int((Double(position) / 127.0 * 100.0).rounded())
            }
            if let v = raw(base + 1) { fx[slot].param2 = v != 0 }
            if let v = raw(base + 3) { fx[slot].preset = min(16, max(1, Int(v))) }
        }

        if ProcessInfo.processInfo.environment["FLOW8_PRINT_STATE"] != nil {
            print("LCRAW ch0=\(d[4]),\(d[5]) ch1=\(d[31]),\(d[32])")
            print("BLEDUMP levels=\(channels.map(\.level)) lowcut=\(channels.map(\.lowCut)) buses=\(buses.map { "\($0.id):\($0.level)" }) fx=\(fx.map { "p1=\($0.param1) p2=\($0.param2) pr=\($0.preset)" })")
        }
        syncInFlight = false
        syncTimeout?.cancel()
        syncState = .synced(Date())
        if continuousSync {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                guard self.continuousSync, self.ble.isConnected, !self.syncInFlight else { return }
                guard Date() >= self.suppressSyncUntil, !InteractionGate.isActive else { return }
                self.syncNow(silent: true)
            }
        }
    }

    /// Applies a live parameter notification from the mixer (type, 0x01, id, ...).
    private func applyBLEParameter(type: UInt8, data: Data) {
        guard !InteractionGate.isActive else { return }
        if ProcessInfo.processInfo.environment["FLOW8_PRINT_STATE"] != nil {
            print("BLENOTIF type=\(type) data=\(data.map { String(format: "%02x", $0) }.joined())")
        }
        guard Date() >= suppressSyncUntil else { return }
        let now = Date()
        recentWrites.removeAll { now.timeIntervalSince($0.1) > 3 }
        if recentWrites.contains(where: { $0.0 == data }) { return }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }
        let id = Int(bytes[2])
        func busIndex(_ address: Int) -> Int? {
            switch address {
            case 0x0F: return 7
            case 0x0A: return 8
            case 0x0B: return 9
            case 0x0C: return 10
            case 0x0D: return 11
            default: return nil
            }
        }
        switch type {
        case 0x06:
            guard bytes.count >= 5 else { return }
            let target = Int(bytes[3])
            if id <= 6 {
                if target == 0x0F, let i = channels.firstIndex(where: { $0.id == id }) {
                    channels[i].level = BLETables.param(.level, bytes[4], near: channels[i].level)
                } else if (0x0A...0x0D).contains(target), let send = [0x0A: 0, 0x0B: 1, 0x0C: 2, 0x0D: 3][target],
                          let i = channels.firstIndex(where: { $0.id == id }) {
                    channels[i].sends[send] = BLETables.param(.level, bytes[4], near: channels[i].sends[send])
                }
            } else if let bus = busIndex(id), target == id, let i = buses.firstIndex(where: { $0.id == bus }) {
                buses[i].level = BLETables.param(.level, bytes[4], near: buses[i].level)
            }
        case 0x00:
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                channels[i].pan = BLETables.param(.pan, bytes[3], near: channels[i].pan)
            } else if id == 0x0F, let i = buses.firstIndex(where: { $0.id == 7 }) {
                buses[i].balance = bytes[3] == 0 ? 0 : min(127, max(0, (Int(bytes[3]) + 2) / 2))
            }
        case 0x08:
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                channels[i].mute = bytes[3] != 0
            } else if id == 0x0C || id == 0x0D {
                fxMuted = bytes[3] != 0
            }
        case 0x01:
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                channels[i].solo = bytes[3] != 0
            }
        case 0x02:
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                channels[i].gain = BLETables.param(.gain, bytes[3], near: channels[i].gain)
            }
        case 0x04:
            guard bytes.count >= 6 else { return }
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                let hz = Int(bytes[4]) | (Int(bytes[5]) << 8)
                channels[i].lowCut = BLETables.param(.lowcut, hz, near: channels[i].lowCut)
            }
        case 0x13:
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                channels[i].comp = BLETables.param(.comp, bytes[3], near: channels[i].comp)
            }
        case 0x15:
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                channels[i].phantom = bytes[3] != 0 && channels[i].hasPhantom
            }
        case 0x40:
            // Payload is [0x40, 0x01, lo, hi] followed by the checksum, so the
            // tempo sits in bytes 2 and 3, little-endian.
            guard bytes.count >= 4 else { return }
            let raw = Int(bytes[2]) | (Int(bytes[3]) << 8)
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/flow8-tap.log")) {
                handle.seekToEndOfFile()
                handle.write("tempo raw=\(raw) data=\(hex)\n".data(using: .utf8)!)
                try? handle.close()
            } else {
                try? "tempo raw=\(raw) data=\(hex)\n".write(toFile: "/tmp/flow8-tap.log", atomically: true, encoding: .utf8)
            }
            // The hardware TAP reports its own unit; only accept musical tempos
            // and ignore anything else instead of showing nonsense.
            if (20...400).contains(raw) {
                tapBPM = Double(raw)
            }
        case 0x09:
            guard bytes.count >= 8, bytes[3] < 4 else { return }
            if id <= 6, let i = channels.firstIndex(where: { $0.id == id }) {
                let band = Int(bytes[3])
                channels[i].eq[band] = BLETables.param(.eq, bytes[7], near: channels[i].eq[band])
            }
        case 0x03:
            guard bytes.count >= 8, bytes[3] < 9 else { return }
            if let bus = busIndex(id), let i = buses.firstIndex(where: { $0.id == bus }) {
                let band = Int(bytes[3])
                buses[i].eq[band] = BLETables.param(.eq, bytes[7], near: buses[i].eq[band])
            }
        case 0x14:
            if let bus = busIndex(id), let i = buses.firstIndex(where: { $0.id == bus }) {
                buses[i].limiter = BLETables.param(.limiter, bytes[3], near: buses[i].limiter)
            }
        case 0x11:
            guard bytes.count >= 5 else { return }
            let slot = id == 0x0C ? 0 : (id == 0x0D ? 1 : -1)
            if slot >= 0, fx.indices.contains(slot) {
                let current = Int((Double(fx[slot].param1) / 100.0 * 127.0).rounded())
                let position = BLETables.param(.fxparam, bytes[3], near: current)
                fx[slot].param1 = Int((Double(position) / 127.0 * 100.0).rounded())
                fx[slot].param2 = bytes[4] != 0
            }
        case 0x31:
            let slot = id == 0x0C ? 0 : (id == 0x0D ? 1 : -1)
            if slot >= 0, fx.indices.contains(slot) {
                fx[slot].preset = min(16, Int(bytes[3]) + 1)
            }
        default:
            break
        }
    }

    private var meterRateCount = 0
    private var meterRateStart = Date()
    private var targetInputMeters: [Double] = Array(repeating: 0, count: 7)
    private var targetMainL: Double = 0
    private var targetMainR: Double = 0
    private var meterTimer: Timer?

    private func updateMetering(_ data: Data) {
        if ProcessInfo.processInfo.environment["FLOW8_METER_RAW"] != nil, meterRateCount < 300 {
            let stamp = String(format: "%.2f", Date().timeIntervalSince1970)
            print("METERRAW \(stamp) len=\(data.count) \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        if ProcessInfo.processInfo.environment["FLOW8_METER_RATE"] != nil {
            meterRateCount += 1
            let elapsed = Date().timeIntervalSince(meterRateStart)
            if elapsed >= 2.0 {
                let hz = Double(meterRateCount) / elapsed
                print("METERRATE \(String(format: "%.1f", hz)) Hz")
                meterRateCount = 0
                meterRateStart = Date()
            }
        }
        // Freeze meter-driven re-renders while the user drags a control: otherwise
        // SwiftUI recreates the drag gesture and the knob jumps.
        guard Date() >= suppressSyncUntil, !InteractionGate.isActive else { return }
        // 0x22 metering stream. The official app maps the 12 payload values
        // through this table: [0,1,2,3,4,4,5,5,6,6,-1,-1] — the first ten are
        // input channels (stereo channels appear twice), the last two are main.
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else { return }

        let mapping = [0, 1, 2, 3, 4, 4, 5, 5, 6, 6]
        var levels = [Double](repeating: 0, count: 7)

        // Calibrated on hardware with a 1 kHz reference tone: raw 191 is
        // 0 dBFS and the meter byte follows a logarithmic scale, about 65 dB
        // per decade of raw value. Checked at -15 / -20 / -25 / -30 / -35 /
        // -40 / -50 dBFS, error below ~1.5 dB.
        func meterDB(_ raw: UInt8) -> Double {
            let value = min(Int(raw), 191)
            guard value > 0 else { return -200 }
            return 64.66 * log10(Double(value) / 190.7)
        }

        func normalized(_ raw: UInt8) -> Double {
            // Same taper as the fader, so meters line up with the dB marks.
            return Param.meterHeight(db: meterDB(raw))
        }

        for index in 0..<10 {
            let value = normalized(bytes[2 + index])
            let channel = mapping[index]
            guard channel >= 0, channel < levels.count else { continue }
            levels[channel] = max(levels[channel], value)
        }

        // The mixer streams meters at its own pace (~3 Hz here), so keep the
        // incoming values as targets and let the meters move smoothly between
        // them: fast attack, soft release.
        for channel in levels.indices {
            targetInputMeters[channel] = levels[channel]
        }
        targetMainL = normalized(bytes[12])
        targetMainR = normalized(bytes[13])
        if ProcessInfo.processInfo.environment["FLOW8_METER_DB"] != nil {
            let chans = (0..<7).map { Int(bytes[2 + $0]) }
            let ch6 = meterDB(bytes[10])
            let main = meterDB(bytes[12])
            print(String(format: "METERDB %.3f ch6 raw=%d %.1f dB | main raw=%d %.1f dB | chans=%@", Date().timeIntervalSince1970, bytes[10], ch6, bytes[12], main, String(describing: chans)))
        }
        startMeterAnimation()
    }

    private func startMeterAnimation() {
        if ProcessInfo.processInfo.environment["FLOW8_METER_ANIM"] == "0" {
            inputMeters = targetInputMeters
            mainMeterL = targetMainL
            mainMeterR = targetMainR
            return
        }
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepMeters() }
        }
    }

    /// 30 fps meter ballistics: instantly follows a rising level and falls back
    /// with a short release, so a ~3 Hz BLE stream still looks continuous.
    private func stepMeters() {
        // While a control is being dragged, keep the main thread for the drag
        // itself: meters resume on release.
        guard !InteractionGate.isActive else { return }
        var changed = false

        var newInput = inputMeters
        for index in newInput.indices {
            let target = targetInputMeters[index]
            let current = newInput[index]
            let next = target > current
                ? current + (target - current) * 0.55
                : current + (target - current) * 0.16
            if abs(next - current) > 0.002 {
                newInput[index] = next
                changed = true
            } else if newInput[index] != target {
                newInput[index] = target
                changed = true
            }
        }

        let nextL = targetMainL > mainMeterL
            ? mainMeterL + (targetMainL - mainMeterL) * 0.55
            : mainMeterL + (targetMainL - mainMeterL) * 0.16
        let nextR = targetMainR > mainMeterR
            ? mainMeterR + (targetMainR - mainMeterR) * 0.55
            : mainMeterR + (targetMainR - mainMeterR) * 0.16

        if abs(nextL - mainMeterL) > 0.0005 { mainMeterL = nextL; changed = true }
        if abs(nextR - mainMeterR) > 0.0005 { mainMeterR = nextR; changed = true }
        if changed { inputMeters = newInput }

        let idle = newInput.allSatisfy { $0 < 0.002 }
            && nextL < 0.002 && nextR < 0.002
            && targetInputMeters.allSatisfy { $0 < 0.002 }
            && targetMainL < 0.002 && targetMainR < 0.002
        if idle {
            inputMeters = [Double](repeating: 0, count: inputMeters.count)
            mainMeterL = 0
            mainMeterR = 0
            meterTimer?.invalidate()
            meterTimer = nil
        }
    }

    private func updateSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
        guard continuousSync else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: max(0.15, syncInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.continuousSync else { return }
                guard self.ble.isConnected else { return }
                guard self.syncState != .syncing, self.syncState != .connecting else { return }
                guard !self.syncInFlight else { return }
                guard Date() >= self.suppressSyncUntil else { return }
                self.syncNow(silent: true)
            }
        }
    }

    // MARK: - BLE probe (calibration)

    private func runBLEProbe() {
        BLELink.probeSession = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            BLELink.probeSession = 1
            self.ble.sendParameter(channel: 1, param: 0x0F, value: 0xFF)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.ble.reconnectForProbe()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            BLELink.probeSession = 2
            self.ble.sendParameter(channel: 1, param: 0x0F, value: 0x00)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.ble.reconnectForProbe()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
            NSApp.terminate(nil)
        }
    }

    private func runContextBruteForce() {
        var candidates: [[UInt8]] = []
        for x in 0...7 {
            for y in 0...7 {
                for z in 0...7 {
                    candidates.append([0x21, 0x01, 0x08, 0x40, 0x41, 0x42, 0x43,
                                       0xc4, 0xc5, 0xc6, 0xcf, 0x00, 0x00,
                                       UInt8(x), UInt8(y), 0x00, 0x00, UInt8(z)])
                }
            }
        }
        print("CTX testing \(candidates.count) packets")
        var index = 0
        func step() {
            guard index < candidates.count else {
                print("CTX done, no metering")
                NSApp.terminate(nil)
                return
            }
            BLELink.sawMetering = false
            let packet = candidates[index]
            BLELink.shared.sendRaw(packet)
            let current = index
            index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                if BLELink.sawMetering {
                    print("CTX FOUND \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    try? Data(packet.map { String(format: "%02x", $0) }.joined(separator: " ").utf8)
                        .write(to: URL(fileURLWithPath: "/tmp/flow8-ctx.txt"))
                    NSApp.terminate(nil)
                    return
                }
                if current % 64 == 0 { print("CTX at \(current)") }
                step()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { step() }
    }

    private func runBLEScan() {
        let ble = BLELink.shared
        let ids = Array(UInt8(0)...UInt8(0x30))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for (index, id) in ids.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.09) {
                    ble.queryParameter(id)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            ble.sendParameter(channel: 1, param: 0x0F, value: 0xFF)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) {
            for (index, id) in ids.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.09) {
                    ble.queryParameter(id)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
            ble.sendParameter(channel: 1, param: 0x0F, value: 0x00)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.0) {
            NSApp.terminate(nil)
        }
    }

    private func runBLEQuery() {
        let ble = BLELink.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ble.queryParameter(0x0F)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            ble.sendParameter(channel: 1, param: 0x0F, value: 0xFF)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            ble.queryParameter(0x0F)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            ble.sendParameter(channel: 1, param: 0x0F, value: 0x00)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            ble.queryParameter(0x0F)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - BLE transport

    private var canSend: Bool { bleControl && ble.isConnected }

    private func bleLevel(_ cc: Int) -> UInt8 { BLETables.ble(.level, cc) }
    private func bleLinear(_ cc: Int) -> UInt8 { BLETables.ble(.pan, cc) }
    private func blePercent(_ value: Int, of maxValue: Int) -> UInt8 {
        let position = Int((Double(value) / Double(maxValue) * 127.0).rounded())
        return BLETables.ble(.fxparam, position)
    }

    // MARK: - Channel controls

    func setLevel(channel id: Int, value: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 127)
        guard channels[index].level != clamped else { return }
        channels[index].level = clamped
            ble.sendMasterCommand(channel: UInt8(id), destination: 0x0F, value: bleLevel(clamped))
        
    }

    func setGain(channel id: Int, value: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }), channels[index].hasGain else { return }
        let clamped = min(max(value, 0), 127)
        guard channels[index].gain != clamped else { return }
        channels[index].gain = clamped
            ble.sendCommand(type: 0x02, channel: UInt8(id), value: BLETables.ble(.gain, clamped))
        
    }

    func setLowCut(channel id: Int, value: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }), channels[index].hasLowCut else { return }
        let clamped = min(max(value, 0), 127)
        guard channels[index].lowCut != clamped else { return }
        channels[index].lowCut = clamped
            // Low cut travels as big-endian Hz: 04 01 <channel> 00 <hi> <lo>
            let hz = BLETables.bleInt(.lowcut, clamped)
            appendLowCutLog("set ch=\(id) cc=\(clamped) hz=\(hz)")
            ble.sendRaw([0x04, 0x01, UInt8(id), 0x00, UInt8((hz >> 8) & 0xFF), UInt8(hz & 0xFF)])
        
    }

    func setPan(channel id: Int, value: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 127)
        guard channels[index].pan != clamped else { return }
        channels[index].pan = clamped
            ble.sendCommand(type: 0x00, channel: UInt8(id), value: BLETables.ble(.pan, clamped))
        
    }

    func setEQ(channel id: Int, band: Int, value: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }), (0..<4).contains(band) else { return }
        let clamped = min(max(value, 0), 127)
        guard channels[index].eq[band] != clamped else { return }
        channels[index].eq[band] = clamped
            let eqFreq: [(UInt8, UInt8, UInt8)] = [
                (0x00, 0x64, 0x00), (0x01, 0xF4, 0x06), (0x07, 0xD0, 0x06), (0x2E, 0xE0, 0x00)
            ]
            let fq = eqFreq[band]
            ble.sendRaw([0x09, 0x01, UInt8(id), UInt8(band), fq.0, fq.1, fq.2, BLETables.ble(.eq, clamped)])
        
    }

    func setCompressor(channel id: Int, value: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }), channels[index].hasCompressor else { return }
        let clamped = min(max(value, 0), 100)
        guard channels[index].comp != clamped else { return }
        channels[index].comp = clamped
            ble.sendCommand(type: 0x13, channel: UInt8(id), value: BLETables.ble(.comp, clamped))
        
    }

    func togglePhantom(channel id: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }), channels[index].hasPhantom else { return }
        channels[index].phantom.toggle()
            ble.sendCommand(type: 0x15, channel: UInt8(id), value: channels[index].phantom ? 1 : 0)
        
    }

    func setSend(channel id: Int, send: Int, value: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }), (0..<4).contains(send) else { return }
        let clamped = min(max(value, 0), 127)
        // When Mon 1/2 are linked as a stereo pair, M1 and M2 move together.
        let targets = (monStereoLinked && (send == 0 || send == 1)) ? [0, 1] : [send]
        for target in targets {
            guard channels[index].sends[target] != clamped else { continue }
            channels[index].sends[target] = clamped
                ble.sendMasterCommand(channel: UInt8(id), destination: UInt8(0x0A + target), value: BLETables.ble(.level, clamped))
            
        }
    }

    func toggleMute(channel id: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].mute.toggle()
            ble.sendCommand(type: 0x08, channel: UInt8(id), value: channels[index].mute ? 1 : 0)
        
    }

    func toggleSolo(channel id: Int) {
        markInteraction()
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].solo.toggle()
            ble.sendCommand(type: 0x01, channel: UInt8(id), value: channels[index].solo ? 1 : 0)
        
    }

    // MARK: - Bus controls

    func setBusLevel(bus id: Int, value: Int) {
        markInteraction()
        guard buses.firstIndex(where: { $0.id == id }) != nil else { return }
        let clamped = min(max(value, 0), 127)
        let targets = (monStereoLinked && (id == 8 || id == 9)) ? [8, 9] : [id]
        for target in targets {
            guard let index = buses.firstIndex(where: { $0.id == target }) else { continue }
            buses[index].level = clamped
                let busChannel = Self.bleBusId(target)
                ble.sendMasterCommand(channel: busChannel, destination: busChannel, value: BLETables.ble(.level, clamped))
            
        }
    }

    /// FX power: turning it off mutes the FX returns and hides the FX strips.
    /// Turning it on unmutes them and shows the strips again.
    func toggleFXPower() {
        if showsFXChannels {
            showsFXChannels = false
            setFXMuted(true)
        } else {
            showsFXChannels = true
            setFXMuted(false)
        }
    }

    func setFXMuted(_ muted: Bool) {
        markInteraction()
        guard fxMuted != muted else { return }
        fxMuted = muted
        let value: UInt8 = muted ? 1 : 0
        ble.sendRaw([0x08, 0x01, 0x0C, value])
        ble.sendRaw([0x08, 0x01, 0x0D, value])
    }

    /// Mon 1/2 act as one stereo bus while linked.
    private func linkedMonTargets(_ id: Int) -> [Int] {
        guard monStereoLinked, id == 8 || id == 9 else { return [id] }
        return [8, 9]
    }

    func toggleMonStereoLink() {
        monStereoLinked.toggle()
        if monStereoLinked {
            if let mon1 = buses.first(where: { $0.id == 8 }) {
                setBusLevel(bus: 9, value: mon1.level)
                setBusLimiter(bus: 9, value: mon1.limiter)
                for band in 0..<9 {
                    setBusEQ(bus: 9, band: band, value: mon1.eq[band])
                }
            }
            // Mirror M1 sends into M2 for every channel.
            for channel in channels {
                setSend(channel: channel.id, send: 1, value: channel.sends[0])
            }
        }
    }

    func setBusBalance(bus id: Int, value: Int) {
        markInteraction()
        guard let index = buses.firstIndex(where: { $0.id == id }), buses[index].kind.hasBalance else { return }
        let clamped = min(max(value, 0), 127)
        guard buses[index].balance != clamped else { return }
        buses[index].balance = clamped
        if id == 7 {
            let raw = UInt8(min(254, max(0, clamped * 2 - 2)))
            ble.sendRaw([0x00, 0x01, 0x0F, raw])
        }
    }

    func setBusLimiter(bus id: Int, value: Int) {
        markInteraction()
        guard let index = buses.firstIndex(where: { $0.id == id }), buses[index].kind.hasLimiter else { return }
        let clamped = min(max(value, 0), 127)
        for target in linkedMonTargets(id) {
            guard let targetIndex = buses.firstIndex(where: { $0.id == target }) else { continue }
            guard buses[targetIndex].limiter != clamped else { continue }
            buses[targetIndex].limiter = clamped
            ble.sendRaw([0x14, 0x01, Self.bleBusId(target), BLETables.ble(.limiter, clamped)])
        }
    }

    func setBusEQ(bus id: Int, band: Int, value: Int) {
        markInteraction()
        guard let index = buses.firstIndex(where: { $0.id == id }),
              buses[index].kind.hasEQ, (0..<9).contains(band) else { return }
        let clamped = min(max(value, 0), 127)
        let geq: [(UInt8, UInt8)] = [
            (0x00, 0x3F), (0x00, 0x7D), (0x00, 0xFA), (0x01, 0xF4), (0x03, 0xE8),
            (0x07, 0xD0), (0x0F, 0xA0), (0x1F, 0x40), (0x3E, 0x80)
        ]
        let f = geq[band]
        for target in linkedMonTargets(id) {
            guard let targetIndex = buses.firstIndex(where: { $0.id == target }) else { continue }
            guard buses[targetIndex].eq[band] != clamped else { continue }
            buses[targetIndex].eq[band] = clamped
            ble.sendRaw([0x03, 0x01, Self.bleBusId(target), UInt8(band), f.0, f.1, 0x08, BLETables.ble(.eq, clamped)])
        }
    }

    private static func bleBusId(_ id: Int) -> UInt8 {
        switch id {
        case 7: return 0x0F
        case 8: return 0x0A
        case 9: return 0x0B
        case 10: return 0x0C
        default: return 0x0D
        }
    }

    private func sendFXSetup(slot: Int) {
        let address: UInt8 = slot == 0 ? 0x0C : 0x0D
        let param1 = blePercent(fx[slot].param1, of: 100)
        let param2: UInt8 = fx[slot].param2 ? 1 : 0
        ble.sendRaw([0x11, 0x01, address, param1, param2, 0x00, 0x01])
    }

    // MARK: - FX

    func setFXPreset(slot: Int, preset: Int) {
        markInteraction()
        guard fx.indices.contains(slot) else { return }
        let clamped = min(max(preset, 1), 16)
        guard fx[slot].preset != clamped else { return }
        fx[slot].preset = clamped
        fx[slot].param2 = false
            let address: UInt8 = slot == 0 ? 0x0C : 0x0D
            ble.sendRaw([0x31, 0x01, address, UInt8(max(0, clamped - 1))])
        
    }

    func setFXParam1(slot: Int, value: Int) {
        markInteraction()
        guard fx.indices.contains(slot) else { return }
        let clamped = min(max(value, 0), 100)
        guard fx[slot].param1 != clamped else { return }
        fx[slot].param1 = clamped
            sendFXSetup(slot: slot)
        
    }

    func setFXParam2(slot: Int, isOn: Bool) {
        markInteraction()
        guard fx.indices.contains(slot) else { return }
        guard fx[slot].param2 != isOn else { return }
        fx[slot].param2 = isOn
            sendFXSetup(slot: slot)
        
    }

    func toggleFXMute() {
        markInteraction()
        setFXMuted(!fxMuted)
    }

    func tapTempo() {
        let now = Date()
        tapTimes.append(now)
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 4 }
        if tapTimes.count > 6 { tapTimes.removeFirst(tapTimes.count - 6) }
        guard tapTimes.count >= 2 else { return }
        var intervals: [Double] = []
        for index in 1..<tapTimes.count {
            intervals.append(tapTimes[index].timeIntervalSince(tapTimes[index - 1]))
        }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        let bpm = 60.0 / average
        tapBPM = min(max(bpm, 40), 300)
        if ble.isConnected {
            let value = Int(bpm.rounded())
            ble.sendRaw([0x40, 0x01, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
        }
    }

    private var tapTimes: [Date] = []

    // MARK: - Snapshots / global

    func loadSnapshot(_ index: Int) {
        guard (0..<15).contains(index) else { return }
        currentSnapshot = index
        // Snapshot load: type 0x20, slot is 0-based (0...14).
        ble.sendRaw([0x20, 0x01, UInt8(index)])
        
        appendLog("Загрузка снапшота \(index + 1)")
    }

    func saveSnapshot(_ index: Int) {
        saveSnapshot(index, name: snapshotNames[index] ?? "Snapshot \(index + 1)")
    }

    /// Stores the current mixer state in a slot under the given name.
    func saveSnapshot(_ index: Int, name: String) {
        guard (0..<15).contains(index), ble.isConnected else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Snapshot \(index + 1)"
        let bytes = Array((trimmed.isEmpty ? fallback : trimmed).utf8.prefix(14))
        var packet: [UInt8] = [0x19, 0x01, UInt8(index), UInt8(bytes.count)]
        packet.append(contentsOf: bytes)
        ble.sendRaw(packet)
        snapshotNames[index] = String(decoding: bytes, as: UTF8.self)
        appendLog("Сохранение снапшота \(index + 1)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.syncNow(silent: true) }
    }

    /// Clears a snapshot slot: the mixer has no dedicated delete, so the slot is
    /// stored with an empty name, which the official app does as well.
    func clearSnapshot(_ index: Int) {
        guard (0..<15).contains(index), ble.isConnected else { return }
        ble.sendRaw([0x19, 0x01, UInt8(index), 0x00])
        snapshotNames[index] = nil
        appendLog("Очистка снапшота \(index + 1)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.syncNow() }
    }

    func resetMixer() {
        currentSnapshot = 15
        if ble.isConnected {
            ble.sendRaw([0x20, 0x01, 15])
        }
        appendLog("Сброс микшера")
    }

    // MARK: - Names

    func renameChannel(id: Int, to name: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = name
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        channels[index].name = String(cleaned.prefix(14))
        saveChannelNames()
    }

    private static func isPlausibleChannelName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 14 else { return false }
        for scalar in name.unicodeScalars {
            if scalar == "\u{FFFD}" { return false }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if !(CharacterSet.alphanumerics.contains(scalar)
                 || CharacterSet.punctuationCharacters.contains(scalar)
                 || CharacterSet.symbols.contains(scalar)
                 || scalar == " ") {
                return false
            }
        }
        return name.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private func saveChannelNames() {
        UserDefaults.standard.set(channels.map(\.name), forKey: "channelNames")
    }

    private func loadChannelNames() {
        if !UserDefaults.standard.bool(forKey: "namesResetV2") {
            UserDefaults.standard.removeObject(forKey: "channelNames")
            UserDefaults.standard.set(true, forKey: "namesResetV2")
        }
        guard let names = UserDefaults.standard.stringArray(forKey: "channelNames"),
              names.count == channels.count else { return }
        for index in channels.indices where Self.isPlausibleChannelName(names[index]) {
            channels[index].name = names[index]
        }
    }


    func clearLog() {
        log.removeAll()
    }

    private func appendLowCutLog(_ text: String) {
        let path = "/tmp/flow8-lowcut.log"
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func appendLog(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 400 {
            log.removeFirst(log.count - 400)
        }
    }

    // MARK: - Strip visibility

    /// In full screen every strip is shown, even the ones hidden in a window.
    @Published var fullScreen = false

    var visibleChannels: [ChannelState] {
        channels.filter { !hiddenChannels.contains($0.id) }
    }

    var visibleBuses: [BusState] {
        buses.filter { bus in
            guard !hiddenBuses.contains(bus.id) else { return false }
            if !showsFXChannels && (bus.kind == .fx1 || bus.kind == .fx2) { return false }
            return true
        }
    }

    /// Strips that stay hidden in window mode — shown as a separate group at
    /// the right in full screen.
    var parkedChannels: [ChannelState] {
        guard fullScreen else { return [] }
        return channels.filter { hiddenChannels.contains($0.id) }
    }

    var parkedBuses: [BusState] {
        guard fullScreen else { return [] }
        return buses.filter { hiddenBuses.contains($0.id) }
    }

    var hiddenStripCount: Int { hiddenChannels.count + hiddenBuses.count }

    /// Width the mixer needs for the strips that are currently visible.
    var mixerContentWidth: CGFloat {
        let channelCount = visibleChannels.count
        let busCount = visibleBuses.filter { !(monStereoLinked && $0.id == 9) }.count
        let hasDivider = channelCount > 0 && busCount > 0
        let itemCount = channelCount + busCount
        let spacingCount = max(0, itemCount - 1) + (hasDivider ? 1 : 0)
        var width: CGFloat = 24
        width += CGFloat(channelCount) * 106
        width += CGFloat(busCount) * 96
        width += CGFloat(spacingCount) * 8
        if hasDivider { width += 1 }
        return width
    }

    func setChannel(_ id: Int, hidden: Bool) {
        if hidden { hiddenChannels.insert(id) } else { hiddenChannels.remove(id) }
    }

    func setBus(_ id: Int, hidden: Bool) {
        if hidden { hiddenBuses.insert(id) } else { hiddenBuses.remove(id) }
    }

    func showAllStrips() {
        hiddenChannels.removeAll()
        hiddenBuses.removeAll()
    }

    // MARK: - Derived helpers

    func channel(_ id: Int) -> ChannelState? {
        channels.first(where: { $0.id == id })
    }

    var syncLabel: LocalizedStringKey {
        switch syncState {
        case .idle: return "Синхронизация не выполнялась"
        case .connecting: return "Подключение по Bluetooth…"
        case .syncing: return "Чтение состояния…"
        case .synced: return "Синхронизировано"
        case .failed(let message): return "Ошибка: \(L10n.string(message))"
        }
    }
}
