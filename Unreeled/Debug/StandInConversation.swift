#if DEBUG
import SwiftUI

/// -standInConversations YES: a blank screen instead of a conversation, so testing the inbox
/// (where the list is when you come back, for one) opens nobody's messages and marks nothing read.
struct StandInConversation: View {
    let title: String
    @Environment(InboxModel.self) private var inbox

    var body: some View {
        Text("Stand-in for a conversation")
            .font(Theme.font(15))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .classicBar(showsBack: true, title: "Test")
            // As a conversation does: back in the inbox, it loads again.
            .task { inbox.invalidate() }
    }
}
#endif
