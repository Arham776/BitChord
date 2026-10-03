import SwiftUI
import Observation
import BitChordShared

/// The GitHub release fields this UI needs. Kept native so iOS and macOS builds
/// always check this repository directly, without depending on a stale generated
/// Kotlin framework binary for its repository URL.
struct AppReleaseUpdate: Identifiable {
    let version: String
    let releaseUrl: String
    let notes: String?

    var id: String { version }
}

private struct GitHubReleasePayload: Decodable {
    let tag_name: String
    let html_url: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
}

/// Whether this build is behind the one on the project's GitHub releases.
///
/// Upstream's `AppUpdateChecker`, with the two Android halves left off: it downloads
/// the release's `.apk` into its own cache and hands it to the system package
/// installer, because an Android build is a sideloaded file it can replace itself.
///
/// None of that exists here. A build on this platform is an `.app` bundle or a
/// TestFlight build, and "Install Now" would be a button that cannot do what it says.
/// So the update *notice* is ported and the update is a link to the release, which is
/// the platform's own answer — and it happens to be the same release page upstream
/// installs from, so the notes a listener reads here are the notes for the build they
/// would get there.
///
/// The comparison itself is shared Kotlin (`AppUpdateChecker.isNewer`) because it is a
/// judgement with edges on every side and it has tests there.
@MainActor
@Observable
final class UpdateChecker {

    static let shared = UpdateChecker()

    /// The release, when there is one this build is behind.
    private(set) var available: AppReleaseUpdate?

    /// A check in flight. Every control that reaches the network is disabled on it,
    /// because a button that appears to work and does nothing is worse than one that
    /// is briefly greyed.
    private(set) var checking = false

    /// Why the last *asked-for* check found nothing, which is not the same as there
    /// being nothing.
    ///
    /// Separate from the silent launch poll on purpose: a poll that failed should say
    /// nothing at all, and a person who pressed the button should be told.
    var problem: String?

    /// The running build's version, from the bundle rather than from a constant.
    ///
    /// A hard-coded version string is a version string that is wrong from the day the
    /// second release ships, and being wrong here means never being offered an update.
    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short, !short.isEmpty else { return "0.0.0" }
        // A build number is a build number, not a version: `1.2.0 (450)` would not
        // parse, and the comparison is on the marketing version alone.
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// The version the comparison uses: the short one, with no build number.
    var comparableVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }

    private var checkedThisSession = false

    /// The once-per-launch poll.
    ///
    /// Quiet on every failure, which is the whole design: this runs unprompted on
    /// every start, and a notice about a network that was briefly down is a notice
    /// about nothing. It also costs a GitHub request against an unauthenticated
    /// rate limit, so it does not run twice in a session.
    func pollOnce() async {
        guard !checkedThisSession else { return }
        checkedThisSession = true
        guard let release = await fetchLatest() else { return }
        if AppUpdateChecker.shared.isNewer(
            latest: release.version,
            current: comparableVersion
        ) {
            available = release
        }
    }

    /// The person pressed the button, so they are told either way.
    @discardableResult
    func check() async -> AppReleaseUpdate? {
        checking = true
        problem = nil
        defer { checking = false }
        guard let release = await fetchLatest() else {
            problem = "Couldn’t reach GitHub to see what’s new. Check the connection and try again."
            return nil
        }
        if AppUpdateChecker.shared.isNewer(
            latest: release.version,
            current: comparableVersion
        ) {
            available = release
            return release
        }
        problem = "BitChord \(comparableVersion) is the newest release."
        return nil
    }

    /// Dismiss the notice, so it does not reappear on the next launch.
    ///
    /// For this session only. A release the listener chose to ignore is not a release
    /// they chose to never see, and there is no "don't ask again" upstream either —
    /// which is the right call, because an update notice is worth seeing twice.
    func dismiss() {
        available = nil
    }

    private func fetchLatest() async -> AppReleaseUpdate? {
        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/bagumamartin/BitChord/releases/latest")!
            )
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("BitChord macOS and iOS updater", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            let release = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            guard !release.draft, !release.prerelease else { return nil }
            let version = release.tag_name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            guard !version.isEmpty, URL(string: release.html_url) != nil else { return nil }
            return AppReleaseUpdate(
                version: version,
                releaseUrl: release.html_url,
                notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return nil
        }
    }
}

/// The release, as a sheet: its version, its notes, and the way to get it.
///
/// Markdown rendered as plain text rather than as markdown on purpose — a release
/// body is a changelog written by a maintainer for a terminal, and rendering it with
/// emphasis and headings inside a sheet on both platforms is more machinery than the
/// content earns. It reads as it was written, which is what a changelog wants.
///
/// `Identifiable` by the version, as above.
struct UpdateSheet: View {
    let release: AppReleaseUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BitChord \(release.version) is out")
                    .font(.title3.weight(.semibold))
                Text("You have \(UpdateChecker.shared.comparableVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                Text(notes)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }

            Divider()

            // A link, and the sentence that says why it is a link. The honest thing on
            // this platform: the app cannot replace itself, so it says where the build
            // is rather than offering a button that would not work.
            VStack(alignment: .leading, spacing: 10) {
                Text("BitChord installs from its releases page, so this opens it in your browser.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Link(destination: URL(string: release.releaseUrl)!) {
                        Text("Open the release")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var notes: String {
        let said = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !said.isEmpty else { return "There are no notes for this release." }
        // Release bodies open with a banner image, and this project's does: the first
        // line of v1.7's notes is `![BitChord banner](https://raw.githubusercontent…)`.
        // Rendered as text — which is the choice above — that is a line of markup
        // soup, so the image lines go and the words stay.
        let kept = said
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isImageOnly }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? "There are no notes for this release." : kept
    }
}

private extension StringProtocol {
    /// A line that is one Markdown image and nothing else.
    ///
    /// `![alt](url)` — the only shape a banner line takes, and the whole test: it
    /// starts `![`, it has a `](` joining the alt text to a target, and it ends `)`.
    var isImageOnly: Bool {
        let said = trimmingCharacters(in: .whitespaces)
        return said.hasPrefix("![")
            && said.contains("](")
            && said.hasSuffix(")")
    }
}
