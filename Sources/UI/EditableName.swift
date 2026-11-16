import AppKit
import SwiftUI

/// Channel name as plain text. Double-click starts editing, Return commits,
/// Escape cancels. The field is not focusable (and shows no focus ring) until
/// the double-click, so the strip no longer looks permanently selected.
struct ChannelNameLabel: NSViewRepresentable {
    let name: String
    var onCommit: (String) -> Void

    func makeNSView(context: Context) -> NameTextField {
        let field = NameTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.isEditable = false
        field.isSelectable = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.onCommit = onCommit
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.toolTip = "Двойной клик — переименовать канал"
        return field
    }

    func updateNSView(_ field: NameTextField, context: Context) {
        field.onCommit = onCommit
        if !field.isEditingName {
            field.stringValue = name
        }
    }
}

final class NameTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    private var valueBeforeEditing = ""

    var isEditingName: Bool { isEditable }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, !isEditable else {
            super.mouseDown(with: event)
            return
        }
        beginEditing()
    }

    private func beginEditing() {
        valueBeforeEditing = stringValue
        isEditable = true
        isSelectable = true
        delegate = self
        window?.makeFirstResponder(self)
        if let editor = currentEditor() as? NSTextView {
            editor.selectedRange = NSRange(location: 0, length: stringValue.count)
        }
    }

    private func finish(commit: Bool) {
        guard isEditable else { return }
        isEditable = false
        isSelectable = false
        if commit {
            onCommit?(stringValue)
        } else {
            stringValue = valueBeforeEditing
        }
        window?.makeFirstResponder(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? NSReturnTextMovement
        finish(commit: movement != NSCancelTextMovement)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            textView.string = valueBeforeEditing
            finish(commit: false)
            return true
        }
        return false
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
    }
}
