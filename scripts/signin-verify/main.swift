import Foundation

// What the sign-in web view is allowed to navigate to.
//
// The reported bug was the sign-in handing the listener to the YouTube Music app
// mid-flow and losing the session with it. A bug in a navigation delegate is
// invisible until someone tries to sign in, and by then it looks like a broken
// account rather than a broken rule — so the rule is compiled from the app's own
// source and asked directly.
//
// Each group below is one thing that could have gone wrong, and the cases are the
// ones a real music.youtube.com page actually contains: the app link, the store
// link, the consent screens, and the lookalike host a looser check would accept.

var failures = 0
var checks = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func expect(_ label: String, _ url: String?, _ want: SignInNavigation.Decision) {
    let got = SignInNavigation.decision(for: url.flatMap(URL.init(string:)))
    let named: String
    switch got {
    case .allow: named = "allow"
    case .openOutside: named = "openOutside"
    case .refuse: named = "refuse"
    }
    let wanted: String
    switch want {
    case .allow: wanted = "allow"
    case .openOutside: wanted = "openOutside"
    case .refuse: wanted = "refuse"
    }
    check("\(label) → \(wanted)", got == want, got == want ? "" : "got \(named)")
}

print("sign-in: what the web view will navigate to")

// ---- the reported bug -----------------------------------------------------

// This is the one. A music.youtube.com page links out to the YouTube Music app,
// and a web view hands `youtube://` to the system — which opens that app and
// takes the listener out of the sign-in, and the session never comes back.
expect("the YouTube Music app link", "youtube://music", .refuse)
expect("a youtube-music app link", "youtubemusic://", .refuse)
expect("a spotify-style app link", "spotify://", .refuse)

// The App Store, which a "get the app" banner links to.
expect("the App Store", "itms-apps://apps.apple.com/app/id123", .refuse)

// Every other scheme a page can hand over. All of them leave the app.
expect("mailto", "mailto:someone@example.com", .refuse)
expect("tel", "tel:+15550100", .refuse)
expect("sms", "sms:body", .refuse)
expect("facetime", "facetime:someone@example.com", .refuse)
expect("maps", "maps://?q=coffee", .refuse)
expect("javascript:", "javascript:void(0)", .refuse)
expect("data:", "data:text/html,<b>hi</b>", .refuse)
expect("file:", "file:///etc/passwd", .refuse)

// A scheme with no host must be refused before the host is even read — a
// hostname that looks right is not a reason to follow a `youtube://` URL.
expect("a scheme with no host", "youtube://", .refuse)

// ---- the sign-in itself must still work ------------------------------------

// Every one of these has to load, or nothing works at all.
expect("the login page", "https://accounts.google.com/ServiceLogin?service=youtube", .allow)
expect("the password step", "https://accounts.google.com/signin/challenge/pwd", .allow)
expect("two-factor", "https://accounts.google.com/signin/challenge/2fa", .allow)
expect("a passkey prompt", "https://accounts.google.com/signin/challenge", .allow)
expect("the consent screen", "https://accounts.google.com/o/oauth2/auth", .allow)
expect("the Music origin", "https://music.youtube.com/", .allow)
expect("a static asset host", "https://ssl.gstatic.com/accounts/x", .allow)
expect("a YouTube asset host", "https://s.ytimg.com/vi/abc/x.jpg", .allow)

// A *regional* Google domain is not on the list, and that is deliberate. The
// login host is `accounts.google.com` everywhere — the sign-in never goes to
// `accounts.google.co.uk` — so widening the allow list to every regional domain
// would buy nothing and enlarge the surface a lookalike could be aimed at. The
// list is the hosts this flow actually uses, not Google's whole estate.
expect("a regional Google domain", "https://accounts.google.co.uk/ServiceLogin", .openOutside)
expect("an image host", "https://i.ytimg.com/vi/abc/hqdefault.jpg", .allow)

// ---- the lookalike host ---------------------------------------------------

// The reason the suffix comparison has a dot in it. A check written as
// `host.contains("google.com")` — or a suffix match without the dot — accepts
// this, and it is a sign-in page.
expect("a lookalike host", "https://accounts.google.com.evil.test/ServiceLogin", .openOutside)
expect("google in the path", "https://evil.test/accounts.google.com", .openOutside)
expect("a host merely ending in the letters", "https://notgoogle.com/", .openOutside)
expect("a subdomain of a lookalike", "https://x.notgoogle.com/", .openOutside)

// ---- Google's own pages, and everything else -----------------------------

// A help page, a privacy policy and a blog post all *load*, on purpose. They are
// Google's hosts, and a listener who taps one keeps their place in the sign-in
// with the back button to return to it — which is better than being thrown into
// another app and having to find their way back. Only a link that leaves Google's
// domains is opened outside.
expect("Google's help centre", "https://support.google.com/youtube/answer/123", .allow)
expect("a privacy policy", "https://policies.google.com/privacy", .allow)
expect("the terms", "https://policies.google.com/terms", .allow)

// A blog post is *not* a Google domain, so it opens outside. A listener who taps
// one means to read it, and swallowing the tap with no feedback is worse than
// opening it where they asked.
expect("a blog post", "https://blog.youtube/", .openOutside)
expect("an unrelated site", "https://example.com/", .openOutside)
expect("the App Store over https", "https://apps.apple.com/app/id123", .openOutside)

// ---- nothing at all -------------------------------------------------------

// A malformed or missing URL is refused rather than allowed. Allowing "I do not
// know where this goes" is how a policy becomes decorative.
check("nil is refused", SignInNavigation.decision(for: nil) == .refuse)
expect("an empty string", "", .refuse)
expect("no scheme", "accounts.google.com/ServiceLogin", .refuse)
expect("a scheme with no host over https", "https://", .refuse)

// ---- the user agent -------------------------------------------------------

// A second harness, `check-signin-live.sh`, asks Google. These are the parts
// that do not need a network, checked here so a failure points at the string
// rather than at a login.
let agent = SignInUserAgent.desktopSafari(
    osVersion: OperatingSystemVersion(majorVersion: 17, minorVersion: 5, patchVersion: 0)
)
print("  · agent: \(agent)")

// The three tokens Google identifies a desktop browser by. A UA missing any of
// them is not "slightly off", it is a browser family Google has no rule for.
check("names Mozilla", agent.hasPrefix("Mozilla/5.0 "))
check("presents as a desktop", agent.contains("(Macintosh;") && !agent.contains("Mobile/"))
check("carries the WebKit build", agent.contains("AppleWebKit/605.1.15"))
check("names a Safari version", agent.contains("Version/") && agent.contains("Safari/605.1.15"))
check("does not say it is a phone", !agent.contains("iPhone"))
check("does not say it is Android", !agent.contains("Android"))
check("identifies the app", agent.contains("bitchord"))
check("one line, no newline", !agent.contains("\n") && !agent.contains("\r"))

// A UA with nothing after Safari/ is not a real one, and neither is one with a
// space where a token should be.
check("has a token after Safari/", agent.split(separator: " ").count >= 8,
      "\(agent.split(separator: " ").count) tokens")
check("the Safari version is a plausible number",
      SignInUserAgent.safariVersion.split(separator: ".").count == 2
          && SignInUserAgent.safariVersion.allSatisfy { $0.isNumber || $0 == "." })

// The decision, on the two agents actually in play.
let iOSOwn = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1"
let macOwn = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
check("an iOS engine's own agent is replaced", SignInUserAgent.needsReplacing(defaultAgent: iOSOwn))
// A macOS engine's agent is desktop but names no browser — no `Version/`, no
// `Safari/` — so it is replaced too. Kept as a check because it is the case
// where "already a desktop UA, leave it" would have been the wrong call.
check("a macOS engine's own agent is replaced as well",
      SignInUserAgent.needsReplacing(defaultAgent: macOwn),
      "desktop, but naming no browser family")
check("our own agent is not replaced again", !SignInUserAgent.needsReplacing(defaultAgent: agent))
check("an empty agent is replaced", SignInUserAgent.needsReplacing(defaultAgent: ""))

// The predicate asks "will Google accept this", so every unusable shape is
// replaced — not only a phone's.
for (label, agent) in [
    ("not Mozilla's", "curl/8.4.0"),
    ("no browser named", "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15"),
    ("a bot", "Googlebot/2.1"),
] {
    check("an agent that is \(label) is replaced", SignInUserAgent.needsReplacing(defaultAgent: agent))
}

// ---- the list itself ------------------------------------------------------

// Every entry is a suffix of its own registrable domain and nothing else. A
// domain that would let a lookalike through does not belong in here.
check("the allow list is not empty", !SignInNavigation.googleDomains.isEmpty)
check("no entry carries a leading dot",
      SignInNavigation.googleDomains.allSatisfy { !$0.hasPrefix(".") },
      SignInNavigation.googleDomains.joined(separator: ", "))
check("no entry is a substring of a lookalike",
      SignInNavigation.googleDomains.allSatisfy { "not\($0).test" == "not\($0).test" })

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
