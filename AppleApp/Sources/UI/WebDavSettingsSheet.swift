import SwiftUI
import BitChordShared

/// Set up a WebDAV share: where it is, who to be on it, and whether that works.
///
/// Upstream's WebDAV editor, and its order: the address, the account, then a button
/// that proves both before anything is saved. Testing before saving is the whole point
/// of the button — a share that is saved and wrong is a library that reads as empty,
/// and "empty" sends people looking for the wrong problem.
///
/// ## Why the password field starts empty
///
/// A settings form that renders a stored secret puts a credential in every
/// screenshot, screen recording and bug report taken of it. The field starts blank
/// and says so, and leaving it blank keeps what is stored — writing the empty string
/// back would forget the credential because nobody typed it.
struct WebDavSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast

    @State private var url: String
    @State private var username: String
    @State private var password = ""
    /// Why the last test failed, or nil when the last test worked.
    @State private var problem: String?
    @State private var testing = false
    /// Whether the last thing that happened was a successful test, so the address can
    /// say so rather than leaving the listener to assume.
    @State private var tested = false

    @MainActor init() {
        let store = WebDavStore.shared
        _url = State(initialValue: store.url)
        _username = State(initialValue: store.username)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://cloud.example.com/dav", text: $url)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    // A URL keyboard, because the thing being typed is a URL and an
                    // address bar's keyboard is the one built for it. macOS has no
                    // equivalent and no need: its field is already free text with the
                    // clipboard and spellcheck behaving.
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField(passwordHint, text: $password)
            } header: {
                Text("Share")
            } footer: {
                Text(footer)
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(testing || url.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                // The line that answers "did that work", in the place a listener is
                // already looking. A green tick somewhere else on the screen is a
                // green tick nobody sees.
                if testing {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                } else if let problem {
                    Text(problem).foregroundStyle(.red)
                } else if tested {
                    Label("That works.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Button("Save") {
                    save()
                }
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if WebDavStore.shared.isConfigured {
                Section {
                    Button("Disconnect", role: .destructive) {
                        WebDavStore.shared.forget()
                        dismiss()
                    }
                } footer: {
                    Text("Forgets the address, the account and the password. Nothing on the server is touched.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("WebDAV")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            #else
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            #endif
        }
        // Anything typed invalidates the last answer. Testing a share and then
        // changing the address must not leave a green tick next to the new one.
        .onChange(of: url) { _, _ in tested = false; problem = nil }
        .onChange(of: username) { _, _ in tested = false; problem = nil }
    }

    private var passwordHint: String {
        WebDavStore.shared.hasPassword ? "Password (unchanged)" : "Password"
    }

    private var footer: String {
        if WebDavStore.shared.hasPassword {
            return "Your password is in the Keychain and is never shown. Leave the field empty to keep it."
        }
        return "Leave the password empty for a share that does not need one. It is stored in the Keychain, and never in a backup."
    }

    private func test() async {
        testing = true
        problem = nil
        tested = false
        let answer = await WebDavStore.shared.test(
            url: url.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            // A blank field means "whatever is stored", which is also what the test
            // has to mean: testing a share's *stored* credentials is the only test
            // worth running once one has been saved.
            password: password.isEmpty ? nil : password
        )
        testing = false
        if let answer {
            problem = answer
        } else {
            tested = true
        }
    }

    private func save() {
        let trimmedUrl = url.trimmingCharacters(in: .whitespaces)
        WebDavStore.shared.save(
            url: trimmedUrl,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password.isEmpty ? nil : password
        )
        // The stored address is the normalized one — a scheme added, trailing slashes
        // trimmed — so the field is re-read rather than left showing what was typed.
        // Otherwise the screen and the settings disagree until it is reopened.
        url = WebDavStore.shared.url
        toast.show("Saved. Your library is in Library → WebDAV.", kind: .success)
        dismiss()
    }
}
