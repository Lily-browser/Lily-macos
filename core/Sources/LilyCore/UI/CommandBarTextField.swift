import AppKit
import SwiftUI

/// The command bar's text field. AppKit underneath because inline completion needs to select the
/// completed part of the text, which SwiftUI's TextField can't do. Keys: ↑/↓ move through the
/// suggestions, Return opens, Esc removes a completion first and closes the bar second, → / End /
/// Tab take the completion into the text, Delete removes it (and nothing completes again until
/// you type another character).
struct CommandBarTextField: NSViewRepresentable {
    let bar: CommandBarModel
    let placeholder: String
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(bar: bar, dismiss: dismiss) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.allowsEditingTextAttributes = false
        field.importsGraphics = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = bar.displayText
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.bar = bar
        context.coordinator.dismiss = dismiss
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // Changes made outside the field (the clear button); typing keeps the two in step itself.
        let text = bar.displayText
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.selectedRange = bar.completion?.selectedRange ?? NSRange(location: (text as NSString).length, length: 0)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var bar: CommandBarModel
        var dismiss: () -> Void
        /// Set while a delete command runs, so the change it makes doesn't complete again.
        private var deleting = false

        init(bar: CommandBarModel, dismiss: @escaping () -> Void) {
            self.bar = bar
            self.dismiss = dismiss
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let editor = field.currentEditor() else { return }
            let text = editor.string
            let selection = editor.selectedRange
            let atEnd = selection.length == 0 && selection.location == (text as NSString).length
            let previous = bar.query
            // Typed (or pasted) at the end: longer than before, or a different text altogether.
            let composing = (editor as? NSTextView)?.hasMarkedText() == true // an input method is mid-word
            let added = atEnd && !deleting && !composing && !text.isEmpty
                && (text.count > previous.count || !previous.lowercased().hasPrefix(text.lowercased()))
            bar.userEdited(text, typing: added)
            if let completion = bar.completion, completion.typed == text {
                editor.string = completion.text
                editor.selectedRange = completion.selectedRange
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                bar.moveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                bar.moveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                bar.commit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if bar.completion != nil {
                    removeCompletion(textView)
                } else {
                    dismiss()
                }
                return true
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
                 #selector(NSResponder.moveToRightEndOfLine(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
                 #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)),
                 #selector(NSResponder.insertTab(_:)):
                guard bar.completion != nil else { return selector == #selector(NSResponder.insertTab(_:)) }
                bar.acceptCompletion()
                textView.string = bar.query
                textView.selectedRange = NSRange(location: (bar.query as NSString).length, length: 0)
                return true
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteWordForward(_:)),
                 #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToEndOfLine(_:)),
                 #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)):
                if bar.completion != nil {
                    // The first Delete takes away only the completion, as in Safari.
                    removeCompletion(textView)
                    return true
                }
                deleting = true
                defer { deleting = false }
                textView.perform(selector, with: nil) // runs the edit; controlTextDidChange follows synchronously
                return true
            default:
                return false
            }
        }

        private func removeCompletion(_ textView: NSTextView) {
            bar.removeCompletion()
            textView.string = bar.query
            textView.selectedRange = NSRange(location: (bar.query as NSString).length, length: 0)
        }
    }
}

/// Takes keyboard focus as soon as it's on screen: when added to the window, and again when the
/// command bar's (hidden while closed) overlay is shown.
final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focus()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        focus()
    }

    private func focus() {
        guard let window, !isHiddenOrHasHiddenAncestor, currentEditor() == nil else { return }
        window.makeFirstResponder(self)
    }
}
