import Foundation

/// Global "user is dragging a control" gate. While active, incoming BLE
/// notifications and USB state dumps are ignored, so controls never jump
/// back under the cursor.
enum InteractionGate {
    private static var activeUntil = Date.distantPast

    static func touch() {
        activeUntil = Date().addingTimeInterval(0.6)
    }

    static func end() {
        activeUntil = Date().addingTimeInterval(0.2)
    }

    static var isActive: Bool { Date() < activeUntil }
}
