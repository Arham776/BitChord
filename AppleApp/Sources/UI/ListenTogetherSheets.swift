import SwiftUI
import BitChordShared
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Name and size, asked once, before a party exists.
///
/// Both are changeable afterwards from the party's own page — this is not the only
/// chance to set them — but they are the two things somebody starting a party tends
/// to have an opinion about, and asking here costs one sheet rather than a trip into
/// settings after the fact.
struct CreatePartySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast
    @Environment(PartyStore.self) private var party

    /// Told once the party exists, so the page behind can put its invite up over a
    /// page that has visibly become something else.
    var onCreated: () -> Void

    @State private var nickname = ""
    @State private var maxMembers = 5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        PartyAvatar(url: party.avatarUrl, name: nickname, size: 40)
                        TextField(PartyCopy.createNicknamePlaceholder, text: $nickname)
                            .textFieldStyle(.plain)
                            .onChange(of: nickname) { _, value in
                                // Bounded on the way in, not on the way out: the name
                                // is sent to every other device and rendered in a row
                                // on each of them.
                                let trimmed = String(value.prefix(48))
                                if trimmed != value { nickname = trimmed }
                            }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text(PartyCopy.createSubtitle)
                } footer: {
                    // Only when it is actually overriding something. A hint that is
                    // always on screen is a hint nobody reads by the third party.
                    if nickname.isEmpty, !party.accountName.isEmpty {
                        Text("You will show up as \(party.accountName).")
                    }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Party size")
                            Text(PartyCopy.createSizeSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        StepperStep(symbol: "minus", enabled: maxMembers > 2) {
                            maxMembers -= 1
                        }
                        Text("\(maxMembers)")
                            .font(.title3.monospacedDigit())
                            .frame(minWidth: 32)
                            .multilineTextAlignment(.center)
                        StepperStep(symbol: "plus", enabled: maxMembers < 10) {
                            maxMembers += 1
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Create a party")
            // `navigationSubtitle` is iOS 26. Below that the subtitle is a section
            // header instead of chrome that is only sometimes there — a sheet whose
            // explanation vanishes on an older release is worse than one that always
            // explains itself the same way.
            .modifier(PartySheetSubtitle(text: PartyCopy.createSubtitle))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(party.busy ? "Creating…" : "Create") {
                        Task { await create() }
                    }
                    .disabled(party.busy || !party.hasServer)
                }
            }
            .onAppear {
                if nickname.isEmpty { nickname = party.nickname }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460)
        #endif
    }

    private func create() async {
        do {
            try await party.create(nickname: nickname, autoplay: true)
            // The party is already made by the time a size could have travelled with
            // the request, so it goes as a control rather than being pretended into
            // the create. A fresh party is one device, so the floor is never in the way.
            if maxMembers != 5 { party.setMaxMembers(Int32(maxMembers)) }
            dismiss()
            onCreated()
            toast.show("Party \(party.code) created")
        } catch {
            // The message is in `party.failure`, shown below the form.
        }
    }
}

/// Six characters, and the button that looks them up.
///
/// Looking up rather than joining: what this sheet hands back is a party to
/// *consider*, and [JoinConfirmSheet] is where the slot is actually taken.
struct JoinPartySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PartyStore.self) private var party

    @State private var code: String
    @State private var looked = false

    init(initialCode: String = "") {
        _code = State(initialValue: initialCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PartyCodeField(code: $code) {
                        Task { await lookUp() }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    // The hint lives here rather than only in the title bar, so it is
                    // on screen on every release. `PartySheetSubtitle` moves it up to
                    // the bar where the platform can spare the space.
                    Text(PartyCopy.joinCodeHint)
                }

                if let message = party.failure {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(party.busy ? "Looking up…" : "Join") {
                        Task { await lookUp() }
                    }
                    .disabled(party.busy || code.count < 6)
                    .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Join a party")
            .modifier(PartySheetSubtitle(text: PartyCopy.joinCodeHint))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460)
        #endif
    }

    private func lookUp() async {
        guard code.count >= 6, !party.busy else { return }
        looked = true
        do {
            let preview = try await party.preview(code: code)
            party.pendingPreview = preview
            dismiss()
        } catch {
            // Shown in the sheet, where it can be read.
        }
        _ = looked
    }
}

/// The last step before a device slot is committed: who is in there, and a way out
/// that is not the back button.
struct JoinConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PartyStore.self) private var party

    let preview: PartyPreview?
    let server: String?

    @State private var nickname = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        PartyAvatar(url: party.avatarUrl, name: nickname, size: 40)
                        TextField(PartyCopy.createNicknamePlaceholder, text: $nickname)
                            .textFieldStyle(.plain)
                    }
                } footer: {
                    Text(PartyCopy.joinPreviewFooter)
                }

                if let preview {
                    Section {
                        HStack(spacing: 12) {
                            MemberAvatarStack(
                                members: preview.members.map {
                                    (name: $0.displayName, avatar: $0.avatarUrl)
                                },
                                total: Int(preview.memberCount)
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: preview))
                                    .font(.headline)
                                if preview.memberCount > 0 {
                                    Text("Listening · \(preview.memberCount) of \(preview.maxMembers)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                    if preview.isFull {
                        Section {
                            Label("This party is full", systemImage: "person.2.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let server, !server.isEmpty {
                        Section {
                            LabeledContent("Server") {
                                Text(server).lineLimit(1).truncationMode(.middle)
                            }
                        } footer: {
                            Text("This invite points at somebody else’s party server, so joining switches this device to it.")
                        }
                    }
                }

                if let message = party.failure {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(party.busy ? "Joining…" : "Join") {
                        Task { await join() }
                    }
                    .disabled(party.busy || preview?.isFull == true || !party.hasServer)
                    .frame(maxWidth: .infinity)

                    Button("Not now", role: .cancel) { dismiss() }
                        .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Join")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if nickname.isEmpty { nickname = party.nickname }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460)
        #endif
    }

    private func title(for preview: PartyPreview) -> String {
        PartyCopy.joinQuestion(hostName: preview.hostName)
    }

    private func join() async {
        guard let preview else { return }
        do {
            if let server, !server.isEmpty {
                // The server named on the invite always wins, whether this device is
                // idle or already in a party: it is the one place the party the preview
                // came from is actually known. Already being in a party then means a
                // switch, which keeps this device where it is if the new party turns
                // it away.
                party.setConfiguredServer(server)
            }
            try await party.join(code: preview.code, nickname: nickname)
            dismiss()
        } catch {
            // Shown in the sheet, where it can be read.
        }
    }
}

/// A link and a square, for getting somebody else in.
struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast
    @Environment(PartyStore.self) private var party

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        if let link = party.inviteLink {
                            PartyQRCode.view(for: link)
                                .frame(width: 160, height: 160)
                                .accessibilityLabel("QR code for the party invite")
                        }
                        Text(party.code)
                            .font(.title2.monospaced().weight(.semibold))
                            .tracking(3)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                Section {
                    if let link = party.inviteLink {
                        ShareLink(
                            item: link,
                            subject: Text("Listen together"),
                            message: Text("Listen with me on BitChord — party code \(party.code)")
                        ) {
                            Label("Share invite", systemImage: "link")
                        }
                    }
                    Button {
                        copyCode()
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                    }
                } footer: {
                    // The link opens the app directly. It also carries the party
                    // server, so the people it reaches do not have to have configured
                    // a server of their own to find the party — which is the whole
                    // reason it is a `bitchord://` link rather than just the code.
                    Text(PartyCopy.inviteFooter)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Invite")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460)
        #endif
    }

    private func copyCode() {
        #if os(iOS)
        UIPasteboard.general.string = party.code
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(party.code, forType: .string)
        #endif
        toast.show("Copied \(party.code)")
    }
}

/// The party server, typed once.
///
/// A row and a sheet rather than a field sitting open on the page. An address is
/// typed once and then never again, and a field left on screen has to explain itself
/// continuously: what the button beside it applies to, why it greys out, what becomes
/// of a half-typed address when the page is scrolled away from. Behind a row there is
/// nothing half-typed to explain.
struct PartyServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast
    @Environment(PartyStore.self) private var party

    @State private var address = ""
    @State private var testing = false
    @State private var result: String?
    @State private var reached = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // No autocapitalisation and no correction, on both platforms: an
                    // address is not English, and a keyboard that helpfully "fixes" it
                    // turns a server that works into one that does not.
                    TextField("https://your-server.com", text: $address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Party server")
                } footer: {
                    if let problem = party.serverProblem(address) {
                        Text(problem).foregroundStyle(.red)
                    } else if address.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Leave this empty to use the default server.")
                    } else {
                        Text("Everyone in a party has to be pointed at the same server, and it has to be one somebody is running.")
                    }
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        if testing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(testing || party.serverProblem(address) != nil)
                } footer: {
                    if let result {
                        // Under the address rather than in a toast, because the
                        // interesting case is the one nobody is watching for: a server
                        // that answered when it was saved and has since gone quiet.
                        Text(result).foregroundStyle(reached ? Color.accentColor : Color.red)
                    } else {
                        Text("A party server is a deployment somebody has to run. This app does not ship one.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Party server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(party.serverProblem(address) != nil)
                }
            }
            .onAppear { address = party.configuredServer }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500)
        #endif
    }

    private func test() async {
        testing = true
        result = nil
        party.setConfiguredServer(address)
        await party.resolveServer()
        testing = false
        // `ServerConnection` is a Kotlin sealed interface and therefore a Swift
        // protocol, so the cases are read by casting rather than by switching. And
        // nothing resolved yet is reported as such rather than as a failure — a test
        // that has not run is not a server that did not answer.
        guard let connection = party.server?.connection else {
            testing = false
            reached = false
            result = "Enter an address to test."
            return
        }
        if let online = connection as? ServerConnectionCustomOnline {
            reached = true
            result = "Answered in \(online.latencyMs) ms."
        } else if connection is ServerConnectionCustomFallback {
            reached = false
            result = "That address did not answer. The default server is being used instead."
        } else if let builtIn = connection as? ServerConnectionDefaultOnline {
            reached = true
            result = "Answered in \(builtIn.latencyMs) ms."
        } else if connection is ServerConnectionOffline {
            reached = false
            result = "Couldn’t reach that address."
        } else if connection is ServerConnectionChecking {
            result = "Still checking."
        } else {
            result = "Enter an address to test."
        }
    }

    private func save() {
        party.setConfiguredServer(address)
        dismiss()
        Task {
            await party.resolveServer()
            toast.show("Party server saved")
        }
    }
}

// MARK: - The landing page

/// A sheet's one-line explanation, placed as high as the platform allows.
///
/// `navigationSubtitle` is the right place for it and only exists from iOS 26, so
/// below that it becomes a section header above the form. Not omitted: a sheet that
/// asks for a nickname with no hint as to what a nickname is *for* is the one people
/// fill with their email address, and a sheet that only appears correct on the newest
/// OS is a sheet that is wrong on the oldest supported one.
private struct PartySheetSubtitle: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

/// What the screen is when there is no party yet.
///
/// Two doors rather than one, and they are not equals: creating is the common case
/// and gets the filled button; joining is what somebody does who already has a code,
/// and a plain button is enough for a person who arrived looking for it.
struct PartyLanding: View {
    let avatarUrl: String?
    let enabled: Bool
    let serverMissing: Bool
    let busy: Bool
    let onCreate: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)
            GlowingPartyAvatar(url: avatarUrl, size: 104)
            Spacer().frame(height: 20)
            Text(PartyCopy.landingTitle)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
            Spacer().frame(height: 8)
            Text(PartyCopy.landingSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: 28)
            Button(action: onCreate) {
                Text(busy ? "Working…" : "Create a party")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .clipShape(Capsule())
            .disabled(!enabled)
            Spacer().frame(height: 6)
            Button(action: onJoin) {
                Text("Join existing")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!enabled)
            if serverMissing {
                Spacer().frame(height: 10)
                Text(PartyCopy.landingNoServer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }
}

/// This device's own face, lit from behind.
///
/// The glow is the whole of the decoration here, and it is one blurred circle rather
/// than a pattern: the listener's picture is the subject, and a field of shapes around
/// it — the obvious thing to reach for — competes with the one element that is
/// actually about them.
private struct GlowingPartyAvatar: View {
    let url: String?
    var size: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(breathing ? 0.6 : 0.35),
                            Color.accentColor.opacity(breathing ? 0.21 : 0.12),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.875
                    )
                )
                // Blurred as well as faded to transparent: a radial gradient alone
                // bands visibly on a dark background at this size.
                .blur(radius: 28)
                .frame(width: size * 1.75, height: size * 1.75)
                .scaleEffect(breathing ? 1.14 : 0.92)
                // A slow, offset pair of animations rather than one, so the rise and
                // the fade do not turn over together — which is what a single looping
                // scale reads as: a pulse, rather than something lit.
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                    value: breathing
                )
            PartyAvatar(url: url, name: "", size: size)
                .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 2) }
        }
        .frame(width: size * 2.1, height: size * 2.1)
        .onAppear {
            guard !reduceMotion else { return }
            // Deliberately not the same period as the scale above: equal periods make
            // the brightest frame always the widest one, which reads as one object
            // throbbing instead of light moving.
            breathing = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                self.breathing = false
            }
        }
    }
}

/// The party code, entered as six cells rather than one box.
///
/// A code that gets read out loud and typed in by somebody else is a sequence of
/// characters, not a word. Six cells say so without a hint line: they show how many
/// are wanted, which one is being typed, and how far in the reading has got.
///
/// One text field underneath, not six. Six fields means six focus targets to hand
/// along on every keystroke and back again on every backspace, and a pasted code that
/// lands entirely in the first one. So the real field is invisible and the cells are
/// only ever a picture of what it holds.
struct PartyCodeField: View {
    @Binding var code: String
    var onSubmit: () -> Void

    @FocusState private var focused: Bool
    @State private var caretOn = false

    private let length = 6

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<length, id: \.self) { index in
                    cell(at: index)
                }
            }
            TextField("", text: $code)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .focused($focused)
                .opacity(0.001)
                .accessibilityLabel("Party code")
                .onChange(of: code) { _, value in
                    // Normalised on the way in rather than on the way out: the cells
                    // are a picture of the field, and a lowercase letter in a cell
                    // looks like a cell showing something other than what will be sent.
                    let cleaned = String(
                        value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(length)
                    )
                    if cleaned != value {
                        code = cleaned
                        return
                    }
                    if cleaned.count == length { onSubmit() }
                }
                .onSubmit(onSubmit)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            caretOn = true
        }
    }

    private func cell(at index: Int) -> some View {
        // Only ever one cell, and only while the keyboard is up: a ring left lit on a
        // field nobody is typing into reads as something being wrong with it.
        let isNext = focused && index == min(code.count, length - 1)
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary.opacity(0.5))
            .frame(height: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isNext ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: isNext ? 1.5 : 1
                    )
            }
            .overlay {
                if index < code.count {
                    Text(String(code[code.index(code.startIndex, offsetBy: index)]))
                        .font(.title2)
                } else if isNext {
                    // A caret, and only in the empty cell being typed into — once there
                    // is a character to show, the character already answers "where am
                    // I".
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 22)
                        .opacity(caretOn ? 1 : 0.15)
                        .animation(
                            focused && !reduceMotion
                                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                : .default,
                            value: caretOn
                        )
                }
            }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// The faces already in a party, overlapped, with a count for the rest.
///
/// Three and a number rather than all of them: the row has to stay the same width at
/// two members and at ten, and past three faces nobody is identifying anyone — they
/// are reading "a few people", which the number says better.
struct MemberAvatarStack: View {
    /// Name and face, as plain values.
    ///
    /// A tuple rather than the Kotlin `PartyPreviewMember`, because a SwiftUI `ForEach`
    /// over Kotlin objects has no stable identity — they are value types that arrive
    /// fresh on every frame, and keying on one re-creates the whole row each time.
    let members: [(name: String, avatar: String?)]
    let total: Int
    var faceSize: CGFloat = 44
    var shown = 3

    var body: some View {
        HStack(spacing: -12) {
            ForEach(Array(members.prefix(shown).enumerated()), id: \.offset) { _, member in
                PartyAvatar(
                    url: member.avatar,
                    name: member.name,
                    size: faceSize
                )
                .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
            }
            let extra = max(0, total - min(shown, members.count))
            if extra > 0 {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Text("+\(extra)")
                        .font(.system(size: faceSize * 0.34, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: faceSize, height: faceSize)
                .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total) in this party")
    }
}

/// A party code as a QR code.
///
/// Rendered on demand and cached, because generating one is not free and this view is
/// redrawn on every party frame. Error correction at `M` rather than `H`: the code is
/// on screen in the same room as the phone, and `H` would cost a third of the dots for
/// damage nobody is going to do to it.
enum PartyQRCode {
    private static let context = CIContext()
    private static let cache = NSCache<NSString, PartyQRImage>()

    #if os(iOS)
    typealias PartyQRImage = UIImage
    #else
    typealias PartyQRImage = NSImage
    #endif

    /// Both platforms, because the caller should not have to care and because
    /// `.interpolation(.none)` is the whole point — a QR code scaled with smoothing
    /// has soft edges, and a soft edge is a code some scanners will not read.
    #if os(iOS)
    static func view(for text: String) -> some View {
        Group {
            if let image = image(for: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                // A missing QR code is not a reason to show nothing at all: the code
                // is still below it in text, and that is the part somebody can read
                // out loud across a room.
                EmptyView()
            }
        }
    }
    #else
    static func view(for text: String) -> some View {
        Group {
            if let image = image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                EmptyView()
            }
        }
    }
    #endif

    static func image(for text: String) -> PartyQRImage? {
        if let cached = cache.object(forKey: text as NSString) { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        let image = UIImage(cgImage: cg)
        #else
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
        cache.setObject(image, forKey: text as NSString)
        return image
    }
}
