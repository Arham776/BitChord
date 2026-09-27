import SwiftUI

/// Transient confirmation for actions that have no other visible result.
///
/// Upstream has this as `QueueActionNotice.kt` plus a `QueueActionNoticeHost` at
/// the root. This port had no equivalent at all, which is why adding to the
/// queue, playing next, downloading, liking, pinning, renaming and de-duplicating
/// all completed *silently* — for actions that are otherwise invisible and, in
/// two cases, destructive.
///
/// Hosted once at the root (see `RootView`) so a notice is never clipped by the
/// view that raised it — the same reason upstream puts its host at the top of the
/// tree rather than inside each screen.
@Observable
final class ToastCenter {
    /// An optional undo, offered as a trailing button on the banner.
    ///
    /// A struct rather than a tuple so `Notice` stays `Equatable` — the host
    /// animates on the current notice changing, and a closure member would take
    /// the synthesised conformance with it.
    struct Action: Equatable {
        let title: String
        let perform: () -> Void

        static func == (a: Action, b: Action) -> Bool { a.title == b.title }
    }

    struct Notice: Identifiable, Equatable {
        enum Kind: Equatable {
            case success
            case failure
            case info
        }
        let id = UUID()
        let message: String
        let kind: Kind
        var action: Action?
    }

    private(set) var current: Notice?

    /// A track-log viewer request, served by `ToastHost`'s sheet.
    ///
    /// Song menus are ephemeral — a `Menu` or context menu tears its content
    /// down the moment an item is tapped — so a `.sheet` hung off a menu item
    /// is torn down with it and never appears. This rides the one presenter
    /// that is always in the hierarchy instead.
    private(set) var trackLogEntry: QueueEntry?
    /// A destructive-action confirmation, served by `ToastHost`'s sheet.
    /// Same reason as `trackLogEntry`: confirmations raised from menus need a
    /// presenter that outlives the menu.
    private(set) var confirmation: ConfirmationRequest?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// How long a notice stays. Long enough to read, short enough that a burst of
    /// actions does not stack up.
    private let dwell: Duration = .seconds(3)

    func show(_ message: String, kind: Notice.Kind = .success, action: Action? = nil) {
        show(message, kind: kind, action: action, dwell: dwell)
    }

    /// Upstream `QueueActionNotice`: the transient "Playing next …" / "Added to
    /// queue" confirmation shown just above the playback pill.
    ///
    /// Shorter dwell than a general toast (2s vs 3s) because queue actions are
    /// high-frequency and back-to-back notices must not stack up. Same bottom
    /// placement as `ToastHost`, which sits above the pill at the root.
    func queueNotice(_ message: String) {
        show(message, kind: .info, dwell: .seconds(2))
    }

    private func show(_ message: String, kind: Notice.Kind, action: Action? = nil, dwell: Duration) {
        dismissTask?.cancel()
        current = Notice(message: message, kind: kind, action: action)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    /// Open the per-track playback log viewer for this entry.
    func showTrackLog(_ entry: QueueEntry) {
        trackLogEntry = entry
    }

    func dismissTrackLog() {
        trackLogEntry = nil
    }

    /// Ask for confirmation before a destructive action. The dialog's Confirm
    /// runs `request.onConfirm`, then clears — so a stale confirm can never
    /// fire twice.
    func requestConfirmation(_ request: ConfirmationRequest) {
        confirmation = request
    }

    func resolveConfirmation() {
        confirmation?.onConfirm()
        confirmation = nil
    }

    func dismissConfirmation() {
        confirmation = nil
    }
}

/// What `ToastCenter.requestConfirmation` presents.
///
/// A struct with an identity so `ToastHost` can show it with `.sheet(item:)`.
/// The handler is intentionally opaque to the host: the host confirms or
/// cancels, and the caller owns what confirming means.
struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirm: String
    let onConfirm: () -> Void
}

/// The host view. Place once, at the top of the root view's hierarchy.
///
/// Also the presenter for the track-log viewer and destructive-action
/// confirmations (see `ToastCenter.trackLogEntry` / `confirmation`): both are
/// routinely raised from song menus, whose content is torn down on tap, so
/// hanging their sheets here is what lets them appear at all.
struct ToastHost: View {
    @Environment(ToastCenter.self) private var center

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let notice = center.current {
                ToastBanner(notice: notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
                    .padding(.horizontal, 16)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: center.current)
        // A toast is decorative confirmation; the action it announces has already
        // happened, and re-announcing it would double up with whatever caused it.
        .allowsHitTesting(center.current != nil)
        .sheet(item: trackLogBinding) { entry in
            TrackLogSheet(entry: entry)
        }
        .sheet(item: confirmationBinding) { request in
            ConfirmationDialog(
                title: request.title,
                message: request.message,
                confirm: request.confirm
            ) {
                center.resolveConfirmation()
            }
        }
    }

    private var trackLogBinding: Binding<QueueEntry?> {
        Binding(
            get: { center.trackLogEntry },
            set: { if $0 == nil { center.dismissTrackLog() } }
        )
    }

    private var confirmationBinding: Binding<ConfirmationRequest?> {
        Binding(
            get: { center.confirmation },
            set: { if $0 == nil { center.dismissConfirmation() } }
        )
    }
}

private struct ToastBanner: View {
    let notice: ToastCenter.Notice
    @Environment(ToastCenter.self) private var center

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(tint)
            Text(notice.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let action = notice.action {
                Button(action.title) {
                    action.perform()
                    center.dismiss()
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
            }        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var symbol: String {
        switch notice.kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .success: .green
        case .failure: .orange
        case .info: .accentColor
        }
    }
}
