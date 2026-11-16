import AppKit
import Foundation

/// Walks the proprietary BLE parameter space and records which bytes of the
/// 0x38 state dump respond to each parameter ID. Development/calibration tool:
/// start it with FLOW8_BLE_CALIB="channel,idFrom,idTo,value".
@MainActor
final class BLECalibrator {
    static let shared = BLECalibrator()

    private var channel: UInt8 = 7
    private var ids: [UInt8] = []
    private var probeValue: UInt8 = 0
    private var index = 0
    private var baseline: Data?
    private var pendingID: UInt8?
    private var results: [[String: Any]] = []
    private var timeoutWork: DispatchWorkItem?
    private var nextWork: DispatchWorkItem?
    private var isRunning = false

    private func log(_ text: String) {
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        let url = URL(fileURLWithPath: "/tmp/flow8-calib.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    func start(channel: UInt8, from: UInt8, to: UInt8, value: UInt8) {
        guard !isRunning else { return }
        isRunning = true
        self.channel = channel
        self.probeValue = value
        ids = Array(from...max(from, to))
        try? Data().write(to: URL(fileURLWithPath: "/tmp/flow8-calib.log"))
        log("start channel=\(channel) ids=\(from)...\(to) value=\(value)")

        BLELink.shared.onDump = { [weak self] data in
            Task { @MainActor in self?.handleDump(data) }
        }
        BLELink.shared.onConnected = { [weak self] in
            Task { @MainActor in self?.log("session connected") }
        }
        BLELink.shared.connect()
        scheduleTimeout(seconds: 20)
    }

    private func scheduleTimeout(seconds: Double) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.log("timeout waiting for dump (param \(self.pendingID ?? 0))")
                self.next()
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func handleDump(_ data: Data) {
        timeoutWork?.cancel()
        if baseline == nil {
            baseline = data
            log("baseline \(data.count) bytes: \(data.hex)")
            next()
            return
        }

        guard let pendingID, let baseline else {
            next()
            return
        }

        var changes: [[String: Any]] = []
        let count = min(baseline.count, data.count)
        for offset in 0..<count where baseline[offset] != data[offset] {
            changes.append([
                "offset": offset,
                "before": Int(baseline[offset]),
                "after": Int(data[offset])
            ])
        }
        results.append([
            "param": Int(pendingID),
            "channel": Int(channel),
            "changes": changes
        ])
        log("param \(pendingID): \(changes.count) changed \(changes)")

        if let first = changes.first, let offset = first["offset"] as? Int, offset < baseline.count {
            BLELink.shared.sendParameter(channel: channel, param: pendingID, value: baseline[offset])
        }
        self.pendingID = nil
        nextWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.next() }
        }
        nextWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func next() {
        guard isRunning else { return }
        if index >= ids.count {
            finish()
            return
        }
        let id = ids[index]
        index += 1
        pendingID = id
        log("probe param \(id) value \(probeValue)")
        BLELink.shared.sendParameter(channel: channel, param: id, value: probeValue)
        scheduleTimeout(seconds: 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            BLELink.shared.reconnectForProbe()
        }
    }

    private func finish() {
        guard isRunning else { return }
        isRunning = false
        log("finished")
        let payload: [String: Any] = [
            "channel": Int(channel),
            "value": Int(probeValue),
            "results": results
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/flow8-calib.json"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.terminate(nil)
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
