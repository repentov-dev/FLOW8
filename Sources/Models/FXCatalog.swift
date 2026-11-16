import Foundation

struct FXPresetInfo: Identifiable {
    let index: Int            // 1...16
    let name: String
    let param1Label: String
    let param2Off: String
    let param2On: String

    var id: Int { index }
}

enum FXCatalog {
    static let fx1: [FXPresetInfo] = [
        .init(index: 1, name: "Ambience", param1Label: "Decay", param2Off: "Instrument", param2On: "Vocal"),
        .init(index: 2, name: "Perc-Rev1", param1Label: "Decay", param2Off: "Dull", param2On: "Bright"),
        .init(index: 3, name: "Perc-Rev2", param1Label: "Decay", param2Off: "Dull", param2On: "Bright"),
        .init(index: 4, name: "Guit-Rev1", param1Label: "Decay", param2Off: "Less Bass", param2On: "More Bass"),
        .init(index: 5, name: "Guit-Rev2", param1Label: "Decay", param2Off: "Less Bass", param2On: "More Bass"),
        .init(index: 6, name: "Chamber", param1Label: "Decay", param2Off: "Pre-D Off", param2On: "Pre-D On"),
        .init(index: 7, name: "Room", param1Label: "Decay", param2Off: "Instrument", param2On: "Vocal"),
        .init(index: 8, name: "Concert", param1Label: "Decay", param2Off: "Instrument", param2On: "Vocal"),
        .init(index: 9, name: "Church", param1Label: "Decay", param2Off: "Instrument", param2On: "Vocal"),
        .init(index: 10, name: "Cathedral", param1Label: "Decay", param2Off: "Small", param2On: "Large"),
        .init(index: 11, name: "Temple", param1Label: "Decay", param2Off: "Pre-D Off", param2On: "Pre-D On"),
        .init(index: 12, name: "Stadium", param1Label: "Decay", param2Off: "Pre-D Off", param2On: "Pre-D On"),
        .init(index: 13, name: "Flanger", param1Label: "Mod Speed", param2Off: "Mono", param2On: "Stereo"),
        .init(index: 14, name: "Soft Chor", param1Label: "Density", param2Off: "Trem Off", param2On: "Trem On"),
        .init(index: 15, name: "Warm Chor", param1Label: "Density", param2Off: "Trem Off", param2On: "Trem On"),
        .init(index: 16, name: "Deep Chor", param1Label: "Density", param2Off: "Trem Off", param2On: "Trem On")
    ]

    static let fx2: [FXPresetInfo] = [
        .init(index: 1, name: "Delay 1/1", param1Label: "Feedback", param2Off: "Dull", param2On: "Bright"),
        .init(index: 2, name: "Delay 1/2", param1Label: "Feedback", param2Off: "Dull", param2On: "Bright"),
        .init(index: 3, name: "Delay 1/3", param1Label: "Feedback", param2Off: "Dull", param2On: "Bright"),
        .init(index: 4, name: "Delay 2/1", param1Label: "Feedback", param2Off: "Dull", param2On: "Bright"),
        .init(index: 5, name: "Echo 1/1", param1Label: "Feedback", param2Off: "Soft", param2On: "Strong"),
        .init(index: 6, name: "Echo 1/2", param1Label: "Feedback", param2Off: "Soft", param2On: "Strong"),
        .init(index: 7, name: "Echo 1/3", param1Label: "Feedback", param2Off: "Soft", param2On: "Strong"),
        .init(index: 8, name: "Echo 2/1", param1Label: "Feedback", param2Off: "Soft", param2On: "Strong"),
        .init(index: 9, name: "Wide Echo", param1Label: "Feedback", param2Off: "Wide", param2On: "Narrow"),
        .init(index: 10, name: "Ping Pong", param1Label: "Feedback", param2Off: "Wide", param2On: "Narrow"),
        .init(index: 11, name: "Ping P 1/3", param1Label: "Feedback", param2Off: "Wide", param2On: "Narrow"),
        .init(index: 12, name: "Ping P R>L", param1Label: "Feedback", param2Off: "Wide", param2On: "Narrow"),
        .init(index: 13, name: "Flanger", param1Label: "Mod Speed", param2Off: "Mono", param2On: "Stereo"),
        .init(index: 14, name: "Soft Chor", param1Label: "Density", param2Off: "Trem Off", param2On: "Trem On"),
        .init(index: 15, name: "Warm Chor", param1Label: "Density", param2Off: "Trem Off", param2On: "Trem On"),
        .init(index: 16, name: "Deep Chor", param1Label: "Density", param2Off: "Trem Off", param2On: "Trem On")
    ]

    static func presets(for slot: Int) -> [FXPresetInfo] {
        slot == 0 ? fx1 : fx2
    }

    static func info(slot: Int, preset: Int) -> FXPresetInfo {
        let list = presets(for: slot)
        let index = min(max(preset, 1), 16) - 1
        return list[index]
    }
}
