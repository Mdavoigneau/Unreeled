import SwiftUI
import UIKit

/// What's in the message field, for the views around it.
///
/// The text has one home, the text view on screen. SwiftUI's `TextField` keeps it twice, in the
/// view and in the state it's bound to, and carries one to the other only when it sees a change:
/// a message could be sent and stay in the field, the state emptied and the view not.
@MainActor
@Observable
final class MessageDraft {
    /// There's something to send: more than spaces and line breaks.
    private(set) var hasText = false

    /// The conversation it's for. What's typed there and not sent is kept (Drafts), and is back
    /// in the field the next time the conversation opens.
    @ObservationIgnored private let conversation: String?
    @ObservationIgnored private weak var view: MessageTextView?

    init(conversation: String? = nil) {
        self.conversation = conversation.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The message as typed, for sending. The field is emptied at once and keeps the keyboard.
    func take() -> String {
        guard let view else { return "" }
        let text = view.typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        view.empty()
        return text
    }

    fileprivate func attach(_ view: MessageTextView) {
        self.view = view
        // What was typed here and not sent, back where it was.
        if let conversation, let kept = Drafts.text(for: conversation) { view.restore(kept) }
        // Said a moment later: views aren't to be changed while SwiftUI is making them.
        let hasText = !view.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText != self.hasText {
            Task { self.follow(view) }
        }
    }

    fileprivate func follow(_ view: MessageTextView) {
        guard view === self.view else { return }
        let typed = view.typedText
        let hasText = !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText != self.hasText { self.hasText = hasText }
        if let conversation { Drafts.keep(typed, for: conversation) }
    }
}

/// The field messages are typed in: one line that grows with the text up to five, then scrolls.
struct MessageField: UIViewRepresentable {
    let draft: MessageDraft
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MessageTextView {
        let view = MessageTextView(placeholder: placeholder)
        view.delegate = context.coordinator
        view.changed = { [draft] view in draft.follow(view) }
        draft.attach(view)
        return view
    }

    func updateUIView(_ view: MessageTextView, context: Context) {}

    /// As wide as it's offered, which a row asks with nothing and with everything to find out,
    /// and as tall as its text at that width.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MessageTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        return CGSize(width: width, height: uiView.height(forWidth: width))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        func textViewDidChange(_ textView: UITextView) {
            (textView as? MessageTextView)?.textChanged()
        }
    }
}

final class MessageTextView: UITextView {
    private static let lines: CGFloat = 5
    private static let padding = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

    /// After anything that changes the text: typing, the keyboard's own edits, emptying.
    var changed: ((MessageTextView) -> Void)?

    private let prompt = UILabel()

    init(placeholder: String) {
        super.init(frame: .zero, textContainer: nil)
        let font = Theme.uiFont(15)
        self.font = font
        adjustsFontForContentSizeCategory = true
        textColor = .label
        tintColor = UIColor(Theme.accent)
        backgroundColor = .clear
        textContainerInset = Self.padding
        textContainer.lineFragmentPadding = 0
        contentInsetAdjustmentBehavior = .never
        // Until it's taller than its five lines, it's exactly as tall as its text.
        isScrollEnabled = false
        accessibilityLabel = placeholder

        prompt.text = placeholder
        prompt.font = font
        prompt.adjustsFontForContentSizeCategory = true
        prompt.textColor = .placeholderText
        prompt.isAccessibilityElement = false
        addSubview(prompt)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MessageTextView, _) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not made from a storyboard")
    }

    /// What was typed, without what the keyboard is only suggesting. The grey end of a word it
    /// shows ahead of the caret is in the text view, as marked text, before you accept it:
    /// sending then would send words you didn't type. Text still being composed (Japanese, an
    /// accent on its way) is typed text: there the caret is inside it or after it.
    var typedText: String {
        guard let marked = markedTextRange, let caret = selectedTextRange, caret.isEmpty,
              compare(caret.start, to: marked.start) == .orderedSame,
              let before = textRange(from: beginningOfDocument, to: marked.start),
              let after = textRange(from: marked.end, to: endOfDocument)
        else { return text ?? "" }
        return (text(in: before) ?? "") + (text(in: after) ?? "")
    }

    /// Empties the field, along with anything the keyboard had under way in it.
    func empty() {
        text = ""
        textChanged()
    }

    /// Puts back what was typed here before, in a field just made. Nothing was typed, so
    /// nothing is said to have changed.
    func restore(_ kept: String) {
        text = kept
        prompt.isHidden = !kept.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func textChanged() {
        prompt.isHidden = !(text ?? "").isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        changed?(self)
    }

    /// The height for its text at this width: from one line to five.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > textContainerInset.left + textContainerInset.right else { return height(lines: 1) }
        return min(max(textHeight(forWidth: width), height(lines: 1)), height(lines: Self.lines))
    }

    private func height(lines: CGFloat) -> CGFloat {
        ((font?.lineHeight ?? 18) * lines + textContainerInset.top + textContainerInset.bottom).rounded(.up)
    }

    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        // Where the first line of text goes.
        prompt.frame = CGRect(
            x: inset.left, y: inset.top,
            width: max(0, bounds.width - inset.left - inset.right), height: font?.lineHeight ?? 18
        )
        // It scrolls only past five lines. Up to there it's as tall as its text, and a text view
        // that could scroll would move the first line out of sight as a new one starts.
        guard bounds.width > 0 else { return }
        let scrolls = textHeight(forWidth: bounds.width) > height(lines: Self.lines)
        if isScrollEnabled != scrolls {
            isScrollEnabled = scrolls
            if scrolls {
                // To the line being typed, which began under the fifth.
                scrollRangeToVisible(selectedRange)
            } else {
                contentOffset = .zero
            }
        }
    }
}
