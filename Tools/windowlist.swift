import AppKit

let options: CGWindowListOption = [.optionAll]
if let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        if owner.contains("FLOW") {
            print("owner=\(owner) id=\(w[kCGWindowNumber as String] ?? "?") name=\(w[kCGWindowName as String] ?? "") bounds=\(w[kCGWindowBounds as String] ?? "") onscreen=\(w[kCGWindowIsOnscreen as String] ?? "?") alpha=\(w[kCGWindowAlpha as String] ?? "?") layer=\(w[kCGWindowLayer as String] ?? "?")")
        }
    }
}
