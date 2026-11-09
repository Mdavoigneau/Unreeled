import SwiftUI

/// Finds accounts by name. No Explore grid.
struct SearchView: View {
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var results: [User] = []
    @State private var error: String?
    /// The website starts a new search session each time you open search.
    @State private var sessionID = UUID().uuidString.lowercased()
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { user in
                    NavigationLink(value: Route.profile(user)) {
                        row(user)
                    }
                    .buttonStyle(.plain)
                }
                if let error {
                    ErrorRow(message: error)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.white)
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) {
            let query = query.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return results = [] }
            try? await Task.sleep(for: .milliseconds(300))  // wait for typing to pause
            guard !Task.isCancelled else { return }
            do {
                results = try await session.api.search(query, sessionID: sessionID)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                TextField("Search", text: $query)
                    .font(Theme.font(15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))

            if isFocused {
                Button("Cancel") {
                    query = ""
                    isFocused = false
                }
                .font(Theme.font(15))
                .foregroundStyle(Theme.ink)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color.white)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
        .animation(.snappy(duration: 0.2), value: isFocused)
    }

    private func row(_ user: User) -> some View {
        HStack(spacing: 12) {
            Avatar(url: user.avatarURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(user.username).font(Theme.font(14, .medium))
                    if user.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .foregroundStyle(Theme.ink)
                if let name = user.fullName, !name.isEmpty {
                    Text(name).font(Theme.font(14)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
