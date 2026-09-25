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

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// How long a notice stays. Long enough to read, short enough that a burst of
    /// actions does not stack up.
    private let dwell: Duration = .seconds(3)

    func show(_ message: String, kind: Notice.Kind = .success, action: Action? = nil) {
        dismissTask?.cancel()
        current = Notice(message: message, kind: kind, action: action)
        let dwell = self.dwell
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
}

/// The host view. Place once, at the top of the root view's hierarchy.
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
