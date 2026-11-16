import Foundation

// MARK: - Input kinds

enum InputKind: String, Codable {
    case xlr
    case combo
    case line
    case usbBT

    var label: String {
        switch self {
        case .xlr: return "XLR"
        case .combo: return "COMBO"
        case .line: return "LINE"
        case .usbBT: return "USB · BT"
        }
    }

    var shortLabel: String {
        switch self {
        case .xlr: return "XLR"
        case .combo: return "COMBO"
        case .line: return "LINE"
        case .usbBT: return "USB"
        }
    }
}

enum BusKind: Int, Codable {
    case main = 7
    case mon1 = 8
    case mon2 = 9
    case fx1 = 10
    case fx2 = 11

    var title: String {
        switch self {
        case .main: return "MAIN"
        case .mon1: return "MON 1"
        case .mon2: return "MON 2"
        case .fx1: return "FX 1"
        case .fx2: return "FX 2"
        }
    }

    var hasLimiter: Bool { self != .fx1 && self != .fx2 }
    var hasBalance: Bool { self == .main }
    var hasEQ: Bool { hasLimiter }
}

// MARK: - Live state

struct ChannelState: Identifiable, Equatable, Codable {
    let id: Int                 // 0...6, mixer channel index
    var name: String
    let kind: InputKind
    let isStereo: Bool

    var level: Int = 100        // CC7, 0 = off, 1...127 = -70...+10 dB
    var gain: Int = 32          // CC8, -20...+60 dB
    var lowCut: Int = 0         // CC9, 20...600 Hz
    var pan: Int = 64           // CC10, 64 = center
    var eq: [Int] = [64, 64, 64, 64]   // CC1...4: low, low-mid, hi-mid, high
    var comp: Int = 0           // CC11, 0...100 %
    var phantom: Bool = false   // CC12
    var sends: [Int] = [0, 0, 0, 0]    // CC14...17: Mon1, Mon2, FX1, FX2
    var mute: Bool = false      // CC5
    var solo: Bool = false      // CC6

    var hasPhantom: Bool { kind == .xlr }
    var hasGain: Bool { kind != .usbBT }
    var hasLowCut: Bool { kind != .usbBT }
    var hasCompressor: Bool { kind != .usbBT }
}

struct BusState: Identifiable, Equatable, Codable {
    let id: Int                 // 7...11, mixer bus index
    let kind: BusKind

    var level: Int = 100        // CC7
    var balance: Int = 64       // CC10 (main only)
    var limiter: Int = 127      // CC8 (main/mon)
    var eq: [Int] = Array(repeating: 64, count: 9)  // CC11...19

    var title: String { kind.title }
}

struct FXSlotState: Identifiable, Equatable, Codable {
    let id: Int                 // 0 = FX1, 1 = FX2
    var preset: Int = 1         // 1...16
    var param1: Int = 50        // 0...100 %
    var param2: Bool = false

    var title: String { "FX \(id + 1)" }
}

/// Full state read back from the mixer through a SysEx dump.
struct DumpSnapshot {
    var names: [String] = Array(repeating: "", count: 7)
    var levels: [Int] = []
    var gains: [Int] = []
    var pans: [Int] = []
    var comps: [Int] = []
    var lowCuts: [Int] = []
    var eqs: [[Int]] = []
    var sends: [[Int]] = []
    var mutes: [Bool] = []
    var solos: [Bool] = []
    var phantoms: [Bool] = []
    var busLevels: [Int] = []
    var busBalances: [Int] = []
    var busLimiters: [Int] = []
    var busEQs: [[Int]] = []
    var fx: [FXSlotState] = []
}

// MARK: - Parameter conversions
//
// Parameter ranges of the FLOW 8:
//   level / sends: CC 0 = OFF, CC 1...127 = -70 ... +10 dB (linear in dB)
//   gain:         -20 ... +60 dB
//   low cut:      20 ... 600 Hz
//   pan/balance:  0 = L, 64 = center, 127 = R
//   EQ:           -15 ... +15 dB, 64 = 0 dB
//   compressor:   0 ... 100 %
//   limiter:      -30 ... 0 dB

enum Param {
    static let levelMinDB: Double = -70
    static let levelMaxDB: Double = 10

    /// Fader law measured on the mixer with a reference tone: the CC the
    /// hardware reports against the gain it actually applies. The top is
    /// close to linear in dB, the bottom falls away faster.
    private static let levelPoints: [(cc: Double, db: Double)] = [
        (1, -80), (20, -70), (30, -60), (40, -50.5), (50, -39),
        (60, -31), (70, -25), (80, -20), (95, -9), (111, 0), (127, 10)
    ]

    /// Where a level sits on the fader, 0 = bottom, 1 = top: a comfortable
    /// taper that keeps -10 dB exactly in the middle and spreads the useful
    /// -10…+10 dB range over the upper half.
    private static let positionPoints: [(db: Double, p: Double)] = [
        (-80, 0.0), (-60, 0.06), (-40, 0.16), (-20, 0.32), (-10, 0.50),
        (0, 0.76), (10, 1.0)
    ]

    static func levelDB(_ cc: Int) -> Double? {
        guard cc > 0 else { return nil }
        let c = Double(min(max(cc, 1), 127))
        for index in 0..<(levelPoints.count - 1) {
            let a = levelPoints[index]
            let b = levelPoints[index + 1]
            if c <= b.cc {
                let t = (c - a.cc) / (b.cc - a.cc)
                return a.db + t * (b.db - a.db)
            }
        }
        return levelMaxDB
    }

    static func levelCC(_ db: Double) -> Int {
        if db <= -80 { return 0 }
        let clamped = min(max(db, -80), levelMaxDB)
        for index in 0..<(levelPoints.count - 1) {
            let a = levelPoints[index]
            let b = levelPoints[index + 1]
            if clamped <= b.db {
                let t = (clamped - a.db) / (b.db - a.db)
                return Int((a.cc + t * (b.cc - a.cc)).rounded())
            }
        }
        return 127
    }

    /// Position of a dB value on the fader, 0…1.
    static func displayPosition(db: Double) -> Double {
        let clamped = min(max(db, -80), levelMaxDB)
        for index in 0..<(positionPoints.count - 1) {
            let a = positionPoints[index]
            let b = positionPoints[index + 1]
            if clamped <= b.db {
                let t = (clamped - a.db) / (b.db - a.db)
                return a.p + t * (b.p - a.p)
            }
        }
        return 1
    }

    /// Inverse of `displayPosition`.
    static func displayDB(position: Double) -> Double {
        let p = min(max(position, 0), 1)
        for index in 0..<(positionPoints.count - 1) {
            let a = positionPoints[index]
            let b = positionPoints[index + 1]
            if p <= b.p {
                let t = (p - a.p) / (b.p - a.p)
                return a.db + t * (b.db - a.db)
            }
        }
        return levelMaxDB
    }

    /// Normalised height of a meter for a level in dB.
    static func meterHeight(db: Double) -> Double {
        displayPosition(db: db)
    }

    static func sendsDB(_ cc: Int) -> Double? { levelDB(cc) }

    static func gainDB(_ cc: Int) -> Double {
        -20.0 + Double(min(max(cc, 0), 127)) / 127.0 * 80.0
    }

    static func gainCC(_ db: Double) -> Int {
        Int(((min(max(db, -20), 60) + 20) / 80.0 * 127.0).rounded())
    }

    static func pan(_ cc: Int) -> Double {
        let c = min(max(cc, 0), 127)
        if c < 64 { return Double(c - 64) / 64.0 }
        if c > 64 { return Double(c - 64) / 63.0 }
        return 0
    }

    static func panCC(_ value: Double) -> Int {
        let v = min(max(value, -1), 1)
        let raw = v < 0 ? v * 64.0 + 64.0 : v * 63.0 + 64.0
        return Int(min(max(raw.rounded(), 0), 127))
    }

    // EQ gain is centred on CC 64, so 64 must read exactly 0 dB instead of +0.1.
    static func eqDB(_ cc: Int) -> Double {
        let c = min(max(cc, 0), 127)
        if c < 64 { return Double(c - 64) / 64.0 * 15.0 }
        if c > 64 { return Double(c - 64) / 63.0 * 15.0 }
        return 0
    }

    static func eqCC(_ db: Double) -> Int {
        let value = min(max(db, -15), 15)
        let raw = value < 0 ? value / 15.0 * 64.0 + 64.0 : value / 15.0 * 63.0 + 64.0
        return Int(min(max(raw.rounded(), 0), 127))
    }

    static func compPercent(_ cc: Int) -> Int { min(max(cc, 0), 100) }

    static func limiterDB(_ cc: Int) -> Double {
        -30.0 + Double(min(max(cc, 0), 127)) / 127.0 * 30.0
    }

    static func limiterCC(_ db: Double) -> Int {
        Int(((min(max(db, -30), 0) + 30) / 30.0 * 127.0).rounded())
    }

    static func lowCutHz(_ cc: Int) -> Double {
        let t = Double(min(max(cc, 0), 127)) / 127.0
        return 20.0 * pow(30.0, t)   // 20 ... 600 Hz
    }

    static func lowCutCC(_ hz: Double) -> Int {
        let clamped = min(max(hz, 20), 600)
        return Int((log(clamped / 20.0) / log(30.0) * 127.0).rounded())
    }

    static func dbText(_ cc: Int) -> String {
        guard let db = levelDB(cc) else { return "−∞" }
        if abs(db) < 0.05 { return "0.0 dB" }
        return String(format: "%+.1f dB", db).replacingOccurrences(of: "-", with: "−")
    }

    static func eqText(_ cc: Int) -> String {
        let db = eqDB(cc)
        if abs(db) < 0.25 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }

    static func signedDB(_ value: Double, digits: Int = 1) -> String {
        String(format: "%+.\(digits)f", value)
    }

    static func panText(_ cc: Int) -> String {
        let v = pan(cc)
        if abs(v) < 0.01 { return "C" }
        return String(format: "%.0f%% %@", abs(v) * 100, v < 0 ? "L" : "R")
    }

    static func lowCutText(_ cc: Int) -> String {
        let hz = lowCutHz(cc)
        return hz >= 100 ? String(format: "%.0f Hz", hz) : String(format: "%.1f Hz", hz)
    }
}
