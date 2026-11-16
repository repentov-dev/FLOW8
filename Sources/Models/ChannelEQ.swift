import Foundation

/// Fixed 4-band EQ of the FLOW 8 input channels. Only the band gains are
/// remote-controllable (CC 1...4), the crossover frequencies are fixed.
enum ChannelEQ {
    static let frequencies: [Double] = [100, 500, 2000, 12000]
    /// Bands 1 and 4 are shelving filters, the two middle bands are peaking.
    static let labels = ["LOW", "L-M", "H-M", "HIGH"]
    static let shortLabels = ["L", "LM", "HM", "H"]
    static let widthOctaves: Double = 1.15
    static let shelving = [true, false, false, true]

    /// 9-band graphic EQ of the output buses.
    static let nineBandFrequencies: [Double] = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let nineBandShelving: [Bool] = [true, false, false, false, false, false, false, false, true]

    /// Approximate magnitude response in dB at a frequency, built from two
    /// shelving and two peaking bands. Purely for display — the mixer does the
    /// real filtering.
    static func responseDB(gains: [Int], at frequency: Double) -> Double {
        responseDB(gains: gains, frequencies: frequencies, shelving: shelving, at: frequency)
    }

    /// Same curve for any band set (used by the 9-band bus EQ as well).
    static func responseDB(gains: [Int], frequencies: [Double], shelving: [Bool], at frequency: Double) -> Double {
        var total = 0.0
        for index in 0..<min(gains.count, frequencies.count) {
            let gain = Param.eqDB(gains[index])
            let ratio = frequency / frequencies[index]
            let isShelf = index < shelving.count ? shelving[index] : false
            if isShelf {
                // First-order shelves: full gain well below / above the corner.
                let t = ratio * ratio
                if index == 0 {
                    total += gain / (1 + t)
                } else {
                    total += gain * t / (1 + t)
                }
            } else {
                // Narrower bells when the bands are packed closer (9-band EQ).
                let spacing = index > 0 ? log2(frequencies[index] / frequencies[index - 1]) : 1.0
                let width = max(0.38, min(widthOctaves, spacing * 0.5))
                let x = log2(ratio) / width
                total += gain * exp(-0.5 * x * x)
            }
        }
        return total
    }
}
