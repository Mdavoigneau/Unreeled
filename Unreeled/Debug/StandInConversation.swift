#if DEBUG
import SwiftUI

/// -standInConversations YES: a stand-in instead of a conversation, so testing the inbox (where
/// the list is when you come back, for one) opens nobody's messages and marks nothing read. The
/// field at the bottom is the conversations' own, to test typing and sending: what's sent here
/// shows on this screen and goes nowhere.
struct StandInConversation: View {
    let title: String
    @Environment(InboxModel.self) private var inbox
    @State private var model = StandInConversation.model()
    @State private var recorder = VoiceRecorder()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Stand-in for a conversation")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    ForEach(model?.shownMessages ?? []) { message in
                        Text(message.textBody.flatMap { $0.isEmpty ? nil : $0 } ?? "Not text")
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            if let model {
                Composer(model: model, recorder: recorder)
            }
        }
        .background(Color.white)
        .classicBar(showsBack: true, title: "Test")
        .onDisappear { recorder.cancel() }
        // As a conversation does: back in the inbox, it loads again.
        .task { inbox.invalidate() }
    }

    /// A conversation with no one, which sends nothing.
    private static func model() -> ConversationModel? {
        let nobody = Data(#"{"thread_fbid": "stand-in"}"#.utf8)
        guard let thread = try? InstagramAPI.decodeSaved(DirectThread.self, from: nobody) else { return nil }
        let model = ConversationModel(thread: thread)
        model.sendsNothing = true
        return model
    }
}
#endif
