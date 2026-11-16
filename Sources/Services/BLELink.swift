import Combine
import CoreBluetooth
import Foundation

enum BLEState: Equatable {
    case unavailable
    case idle
    case scanning
    case connecting
    case authenticating
    case connected
    case failed(String)

    var text: String {
        switch self {
        case .unavailable: return "Bluetooth недоступен"
        case .idle: return "Bluetooth: не подключён"
        case .scanning: return "Поиск FLOW 8…"
        case .connecting: return "Подключение…"
        case .authenticating: return "Авторизация…"
        case .connected: return "Bluetooth: подключён"
        case .failed(let message): return "Bluetooth: \(message)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .authenticating: return true
        default: return false
        }
    }
}

/// Proprietary BLE link to the FLOW 8.
///
/// Used for reading the mixer state (SysEx dump trigger + snapshot names) and,
/// for the metering stream. Control itself also goes over Bluetooth.
final class BLELink: NSObject, ObservableObject {
    static let shared = BLELink()

    static let serviceUUID = CBUUID(string: "14839AD4-8D7E-415C-9A42-167340CF2339")
    static let characteristicUUID = CBUUID(string: "0034594A-A8E7-4B1A-A6B1-CD5243059A57")

    // Pre-built packets with the protocol checksum (sum of bytes mod 256).
    private static let authPacket: [UInt8] = [
        0x39, 0x01, 0xFD, 0x06, 0x2B, 0x06, 0x39, 0xF1, 0x7F, 0xE7,
        0xB7, 0x27, 0x8B, 0x8F, 0x35, 0x5A, 0x49, 0x5C, 0x2A
    ]
    private static let sessionStartPacket: [UInt8] = [0x37, 0x01, 0x38]
    private static let configRequestPacket: [UInt8] = [0x07, 0x01, 0x08]
    private static let dumpTriggerPacket: [UInt8] = [0x4B, 0x01, 0x4C]
    private static let contextPacket: [UInt8] = [
        0x21, 0x01, 0x08, 0x40, 0x41, 0x42, 0x43, 0xC4, 0xC5, 0xC6, 0xCF,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    @Published private(set) var state: BLEState = .idle
    @Published private(set) var peripheralName: String?
    @Published private(set) var lastError: String?

    /// Snapshot slot names received from the mixer (15 entries, nil = empty slot).
    var onSnapshotNames: (([String?]) -> Void)?
    /// Called once the session is authenticated and the mixer accepts commands.
    var onReady: (() -> Void)?
    /// Raw 0x22 metering packets.
    var onMetering: ((Data) -> Void)?
    /// Live parameter notifications coming from the mixer (own echo or hardware moves).
    var onParameter: ((UInt8, Data) -> Void)?
    /// Called with every outgoing frame (to suppress echoes of our own writes).
    var onWrite: ((Data) -> Void)?
    /// Called after a dump trigger was written, so the app can wait for SysEx.
    var onDumpRequested: (() -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var wantsConnection = false
    private var scanTimeout: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?
    private var pendingSnapshotRequest = false
    static var probeSession = 0
    private var dumpBuffer = Data()
    private var dumpChunks: [Int: Data] = [:]
    private static var dumpSaveCounter = 0
    private var readDumpChunks: [Int: Data] = [:]
    private var pendingParamFrames: [String: [UInt8]] = [:]
    private var paramFlushScheduled = false

    static var sawMetering = false

    /// Writes a fully formed packet (checksum appended automatically).
    func sendRaw(_ payload: [UInt8]) {
        guard state == .connected, characteristic != nil, peripheral != nil else { return }
        guard let type = payload.first else { return }
        let isParameter: Bool
        switch type {
        case 0x00...0x15, 0x31, 0x40: isParameter = true
        default: isParameter = false
        }
        guard isParameter else {
            writeNow(payload)
            return
        }
        // Coalesce rapid drag events: keep only the latest value per parameter
        // and flush at most every 20 ms. The key must identify the parameter
        // *without* its value, otherwise every drag step becomes a separate
        // write and the mixer lags behind the cursor.
        let key = self.coalescingKey(for: payload)
        pendingParamFrames[key] = payload
        if !paramFlushScheduled {
            paramFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.flushParamFrames()
            }
        }
    }

    private func coalescingKey(for payload: [UInt8]) -> String {
        guard let type = payload.first else { return "" }
        let keep: Int
        switch type {
        case 0x09, 0x03:      // EQ: type, 0x01, channel, band
            keep = 4
        case 0x06:            // level: type, 0x01, channel, destination
            keep = 4
        case 0x04:            // low cut: type, 0x01, channel, 0x00
            keep = 4
        default:              // gain, pan, comp, limiter, FX, tempo, ...
            keep = 3
        }
        return payload.prefix(min(keep, payload.count))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func flushParamFrames() {
        paramFlushScheduled = false
        let frames = Array(pendingParamFrames.values)
        pendingParamFrames.removeAll()
        for frame in frames { writeNow(frame) }
    }

    private var outstandingWrites = 0

    private func writeNow(_ payload: [UInt8]) {
        guard state == .connected, let characteristic, let peripheral else { return }
        var bytes = payload
        bytes.append(bytes.reduce(0, &+) & 0xFF)
        let data = Data(bytes)
        onWrite?(data)
        outstandingWrites += 1
        if ProcessInfo.processInfo.environment["FLOW8_WRITE_LOG"] != nil {
            let head = data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            NSLog("[WRITE] %@ depth=%d", head, outstandingWrites)
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    /// Called with a complete, reassembled 0x38 state dump (payload only).
    var onDump: ((Data) -> Void)?
    /// Called whenever the authenticated session becomes ready.
    var onConnected: (() -> Void)?
    private var dumpWorkItems: [DispatchWorkItem] = []
    private var meterPollTimer: Timer?

    private override init() {
        super.init()
    }

    var isConnected: Bool { state == .connected }

    // MARK: - Public API

    func connect() {
        wantsConnection = true
        lastError = nil

        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionShowPowerAlertKey: false
            ])
            return
        }
        startScanIfPossible()
    }

    func disconnect() {
        wantsConnection = false
        cancelTimers()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        characteristic = nil
        state = .idle
        peripheralName = nil
    }

    /// Asks the mixer for a fresh state dump and for
    /// the snapshot names (delivered over BLE).
    /// Sends a proprietary parameter command: 06 01 CH PARAM VALUE CHK.
    func sendParameter(channel: UInt8, param: UInt8, value: UInt8) {
        guard state == .connected, let characteristic, let peripheral else { return }
        var bytes: [UInt8] = [0x06, 0x01, channel, param, value]
        bytes.append(bytes.reduce(0, &+) & 0xFF)
        peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
    }

    /// Simple command: [type, 0x01, channel, value] + checksum.
    func sendCommand(type: UInt8, channel: UInt8, value: UInt8) {
        sendRaw([type, 0x01, channel, value])
    }

    /// Master/routing command: [0x06, 0x01, channel, destination, value] + checksum.
    func sendMasterCommand(channel: UInt8, destination: UInt8, value: UInt8) {
        sendRaw([0x06, 0x01, channel, destination, value])
    }

    /// Queries a parameter: 26 01 PARAM CHK. The mixer answers with 0x25.
    func queryParameter(_ param: UInt8) {
        guard state == .connected, let characteristic, let peripheral else { return }
        var bytes: [UInt8] = [0x26, 0x01, param]
        bytes.append(bytes.reduce(0, &+) & 0xFF)
        peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
    }

    /// Reconnects to obtain a fresh 0x38 state dump (debug/calibration helper).
    func reconnectForProbe() {
        guard let peripheral else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    /// Asks the mixer for the BLE state dump (0x37 → 0x38 parts).
    func requestBLEState() {
        guard state == .connected, let characteristic, let peripheral else { return }
        var packet = Self.sessionStartPacket
        packet.append(packet.reduce(0, &+) & 0xFF)
        let data = Data(packet)
        onWrite?(data)
        outstandingWrites += 1
        if ProcessInfo.processInfo.environment["FLOW8_WRITE_LOG"] != nil {
            let head = data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            NSLog("[WRITE] %@ depth=%d", head, outstandingWrites)
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func requestSync() {
        guard let characteristic, let peripheral, state == .connected else { return }

        pendingSnapshotRequest = true
        write(Self.configRequestPacket, to: characteristic, on: peripheral)
        write(Self.dumpTriggerPacket, to: characteristic, on: peripheral)
        onDumpRequested?()
    }

    // MARK: - Connection internals

    private func startScanIfPossible() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            if central.state == .unauthorized {
                state = .failed("нет разрешения")
            } else if central.state == .unsupported {
                state = .unavailable
            } else {
                state = .idle
            }
            return
        }

        guard peripheral == nil else { return }

        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)

        scanTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .scanning else { return }
            self.central?.scanForPeripherals(withServices: nil, options: nil)
        }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func cancelTimers() {
        scanTimeout?.cancel()
        scanTimeout = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        dumpWorkItems.forEach { $0.cancel() }
        dumpWorkItems.removeAll()
        central?.stopScan()
    }

    private func write(_ bytes: [UInt8], to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let data = Data(bytes)
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    private var pairingMode: Bool {
        ProcessInfo.processInfo.environment["FLOW8_BLE_PAIR"] != nil
    }

    private var pairingConfirmed = false
    private var pairingTimer: DispatchWorkItem?

    private func startSession() {
        guard let characteristic, let peripheral else { return }
        state = .authenticating
        if pairingMode {
            // Enabling notifications first is mandatory: the 0x36 pairing reply
            // only arrives as a notification.
            peripheral.setNotifyValue(true, for: characteristic)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.sendPairingAuth()
            }
        } else {
            write(Self.authFrame(), to: characteristic, on: peripheral)
            afterAuth()
        }
    }

    private static func storedClientID() -> [UInt8]? {
        guard let data = UserDefaults.standard.data(forKey: "pairedClientID"), data.count == 16 else { return nil }
        return [UInt8](data)
    }

    private static func authFrame() -> [UInt8] {
        if let id = storedClientID() {
            var packet = [0x39, 0x01] + id
            packet.append(packet.reduce(0, &+) & 0xFF)
            return packet
        }
        return authPacket
    }

    private func sendPairingAuth() {
        guard let characteristic, let peripheral else { return }
        let id: [UInt8]
        if let stored = Self.storedClientID() {
            id = stored
        } else {
            var fresh = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { fresh[i] = UInt8.random(in: 0...255) }
            UserDefaults.standard.set(Data(fresh), forKey: "pairedClientID")
            id = fresh
        }
        var packet = [0x39, 0x01] + id
        packet.append(packet.reduce(0, &+) & 0xFF)
        write(packet, to: characteristic, on: peripheral)
        NSLog("[PAIR] sent new client id, waiting for PAIR APP")
        // If this ID is already paired, the mixer stays connected but sends no
        // 0x36 — proceed with the session anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.state == .authenticating, self.characteristic != nil else { return }
            if !self.pairingConfirmed {
                self.pairingConfirmed = true
                self.afterAuth()
            }
        }
        let retry = DispatchWorkItem { [weak self] in
            guard let self, !self.pairingConfirmed, self.state == .authenticating else { return }
            self.sendPairingAuth()
        }
        pairingTimer?.cancel()
        pairingTimer = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: retry)
    }

    private func afterAuth() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let char = self.characteristic, let per = self.peripheral else { return }
            NSLog("[DBG] subscribing after auth")
            per.setNotifyValue(true, for: char)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, let c = self.characteristic, let p = self.peripheral else { return }
                self.write(Self.sessionStartPacket, to: c, on: p)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.characteristic != nil else { return }
            self.state = .connected
            if ProcessInfo.processInfo.environment["FLOW8_BLE_MINIMAL"] == nil {
                self.sendRaw(Self.contextPacket)
            }
            if let raw = ProcessInfo.processInfo.environment["FLOW8_METER_POLL"],
               let hz = Double(raw), hz > 0 {
                self.meterPollTimer?.invalidate()
                self.meterPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
                    guard let self, self.state == .connected else { return }
                    self.sendRaw(Self.contextPacket)
                }
            }
            self.onReady?()
            self.onConnected?()
            if ProcessInfo.processInfo.environment["FLOW8_BLE_STREAM37"] != nil {
                for step in 1...3600 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step)) { [weak self] in
                        guard let self, let c = self.characteristic, let p = self.peripheral else { return }
                        self.write(Self.sessionStartPacket, to: c, on: p)
                    }
                }
            } else if ProcessInfo.processInfo.environment["FLOW8_BLE_MULTI37"] != nil {
                for step in 1...5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step)) { [weak self] in
                        guard let self, let c = self.characteristic, let p = self.peripheral else { return }
                        self.write(Self.sessionStartPacket, to: c, on: p)
                    }
                }
            } else if ProcessInfo.processInfo.environment["FLOW8_BLE_NOSYNC"] == nil,
               ProcessInfo.processInfo.environment["FLOW8_BLE_MINIMAL"] == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.requestSync()
                }
            }
        }
    }

    // MARK: - Notification parsing

    private func handleNotification(_ data: Data) {
        guard let type = data.first else { return }
        if ProcessInfo.processInfo.environment["FLOW8_BLE_NOTIFY_LOG"] != nil {
            let line = String(format: "%.3f type=%02X len=%d %@\n",
                              Date().timeIntervalSince1970, type, data.count,
                              data.map { String(format: "%02x", $0) }.joined())
            append(Data(line.utf8), to: "/tmp/flow8-notify.log")
        }
        if ProcessInfo.processInfo.environment["FLOW8_BLE_SYSEX"] != nil {
            let url = URL(fileURLWithPath: "/tmp/flow8-ble-sysex.bin")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        switch type {
        case 0x27:
            let names = Self.parseSnapshotNames(data)
            if !names.isEmpty {
                onSnapshotNames?(names)
            }
        case 0x22:
            BLELink.sawMetering = true
            onMetering?(data)
        case 0x38:
            // Multi-part state dump: [0x38, totalParts, ?, partIndex, payload..., checksum]
            if data.count >= 5 {
                let total = Int(data[1])
                let index = Int(data[3])
                let payload = data.subdata(in: 4..<(data.count - 1))
                dumpChunks[index] = payload
                if total > 0 && dumpChunks.count >= total {
                    let ordered = (0..<total).compactMap { dumpChunks[$0] }
                    dumpChunks.removeAll()
                    if ordered.count == total {
                        var joined = Data()
                        ordered.forEach { joined.append($0) }
                        if ProcessInfo.processInfo.environment["FLOW8_BLE_SAVEDUMP"] != nil {
                            BLELink.dumpSaveCounter += 1
                            let path = "/tmp/flow8-notify-state-\(BLELink.dumpSaveCounter).bin"
                            try? joined.write(to: URL(fileURLWithPath: path))
                        }
                        onDump?(joined)
                    }
                }
            }
            if ProcessInfo.processInfo.environment["FLOW8_BLE_PROBE"] != nil {
                let path = "/tmp/flow8-0x38-\(BLELink.probeSession).bin"
                if data.count > 3 && data[3] == 0 {
                    try? Data().write(to: URL(fileURLWithPath: path))
                }
                append(data, to: path)
            }
            if ProcessInfo.processInfo.environment["FLOW8_BLE_DUMP"] != nil {
                let url = URL(fileURLWithPath: "/tmp/flow8-0x38.bin")
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: url)
                }
            }
        case 0x36:
            if pairingMode && !pairingConfirmed {
                pairingConfirmed = true
                pairingTimer?.cancel()
                NSLog("[PAIR] mixer confirmed the new client id")
                afterAuth()
            }
        case 0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x09, 0x11, 0x13, 0x14, 0x15, 0x31, 0x40:
            onParameter?(type, data)
        default:
            break
        }
    }

    private func append(_ data: Data, to path: String) {
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func parseSnapshotNames(_ data: Data) -> [String?] {
        guard data.count >= 4 else { return [] }
        let payload = data.dropFirst(2).dropLast(1)   // type, version ... checksum
        var names: [String?] = []
        var index = payload.startIndex

        while index < payload.endIndex && names.count < 15 {
            let length = Int(payload[index])
            index = payload.index(after: index)
            if length == 0 {
                names.append(nil)
            } else if let end = payload.index(index, offsetBy: length, limitedBy: payload.endIndex) {
                let bytes = payload[index..<end]
                let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                names.append(name.isEmpty ? nil : name)
                index = end
            } else {
                break
            }
        }
        return names
    }
}

// MARK: - CBCentralManagerDelegate

extension BLELink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsConnection {
                startScanIfPossible()
            }
        case .unauthorized:
            state = .failed("нет разрешения")
        case .unsupported:
            state = .unavailable
        case .poweredOff:
            state = .idle
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let matchesName = advertisedName.uppercased().contains("FLOW")
        let matchesService = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .contains(Self.serviceUUID) ?? false

        guard matchesName || matchesService else { return }
        NSLog("[DBG] discover %@", advertisedName)

        central.stopScan()
        scanTimeout?.cancel()
        self.peripheral = peripheral
        self.peripheralName = advertisedName.isEmpty ? "FLOW 8" : advertisedName
        state = .connecting
        peripheral.delegate = self
        central.connect(peripheral, options: nil)

        connectTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral === peripheral, self.state == .connecting else { return }
            self.state = .failed("таймаут подключения")
            central.cancelPeripheralConnection(peripheral)
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("[DBG] didConnect %@", peripheral.name ?? "?")
        connectTimeout?.cancel()
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        NSLog("[DBG] failConnect %@", error?.localizedDescription ?? "nil")
        self.peripheral = nil
        state = .failed(error?.localizedDescription ?? "не удалось подключиться")
        if wantsConnection {
            scheduleReconnect()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        NSLog("[DBG] disconnect %@", error?.localizedDescription ?? "nil")
        self.peripheral = nil
        self.characteristic = nil
        state = wantsConnection ? .failed("соединение потеряно") : .idle
        if wantsConnection {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard wantsConnection else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.wantsConnection, self.peripheral == nil else { return }
            self.startScanIfPossible()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLELink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if ProcessInfo.processInfo.environment["FLOW8_BLE_ENUM"] != nil {
            for svc in peripheral.services ?? [] {
                NSLog("[ENUM] service %@", svc.uuid.uuidString)
            }
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            state = .failed("сервис не найден")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if ProcessInfo.processInfo.environment["FLOW8_BLE_ENUM"] != nil {
            for ch in service.characteristics ?? [] {
                NSLog("[ENUM] char %@ props=%lu", ch.uuid.uuidString, ch.properties.rawValue)
            }
        }
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.characteristicUUID }) else {
            state = .failed("характеристика не найдена")
            return
        }
        NSLog("[DBG] char found props=%lu writeNR=%@", characteristic.properties.rawValue,
              characteristic.properties.contains(.writeWithoutResponse) ? "yes" : "no")
        if ProcessInfo.processInfo.environment["FLOW8_BLE_ENUM"] != nil {
            for ch in service.characteristics ?? [] where ch.properties.contains(.read) {
                peripheral.readValue(for: ch)
            }
        }
        if ProcessInfo.processInfo.environment["FLOW8_BLE_READDUMP"] != nil {
            peripheral.readValue(for: characteristic)
        }
        self.characteristic = characteristic
        startSession()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        outstandingWrites = max(0, outstandingWrites - 1)
        if ProcessInfo.processInfo.environment["FLOW8_WRITE_LOG"] != nil {
            NSLog("[WRITE] done err=%@ depth=%d", error?.localizedDescription ?? "ok", outstandingWrites)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let value = characteristic.value {
            if ProcessInfo.processInfo.environment["FLOW8_BLE_ENUM"] != nil {
                let hex = value.map { String(format: "%02x", $0) }.joined()
                NSLog("[ENUM] read %@ len=%d %@", characteristic.uuid.uuidString, value.count, hex)
            }
            if ProcessInfo.processInfo.environment["FLOW8_BLE_READDUMP"] != nil,
               characteristic.uuid == Self.characteristicUUID,
               let first = value.first, first == 0x38, value.count >= 5 {
                let total = Int(value[1])
                let index = Int(value[3])
                readDumpChunks[index] = value.subdata(in: 4..<(value.count - 1))
                if readDumpChunks.count >= total {
                    let ordered = (0..<total).compactMap { readDumpChunks[$0] }
                    readDumpChunks.removeAll()
                    var joined = Data()
                    ordered.forEach { joined.append($0) }
                    try? joined.write(to: URL(fileURLWithPath: "/tmp/flow8-ble-state.bin"))
                    NSLog("[ENUM] BLE state %d bytes", joined.count)
                } else {
                    peripheral.readValue(for: characteristic)
                }
            }
            handleNotification(value)
        }
    }
}
