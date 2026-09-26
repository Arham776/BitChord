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
//
// The last group is not about a URL at all. It reads the sign-in view's own source
// and asserts that it cannot hand a URL to the system at all — because the bug
// being guarded against is not "the wrong host was allowed", it is "there is a
// branch here that opens things elsewhere". A check that only asks about hosts
// passes happily while that branch is still there.

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
    check("\(label) → \(name(of: want))", got == want, got == want ? "" : "got \(name(of: got))")
}

func name(of decision: SignInNavigation.Decision) -> String {
    switch decision {
    case .load: return "load"
    case .refuse(let why): return "refuse(\(why))"
    }
}

print("sign-in: what the web view will navigate to")

// ---- the sign-in has no exits ----------------------------------------------

// A sign-in is a chain of http(s) hops we do not own, and nothing in a navigation
// action says which one is the next step of the transaction and which is a footer
// link. So every web page loads, in place. This is upstream's shape too: its
// WebViewClient overrides onPageFinished and nothing else, because Android's WebView
// has no "open this elsewhere" affordance to intercept in the first place.
expect("the login page", "https://accounts.google.com/ServiceLogin?service=youtube", .load)
expect("the password step", "https://accounts.google.com/signin/challenge/pwd", .load)
expect("two-factor", "https://accounts.google.com/signin/challenge/2fa", .load)
expect("a passkey prompt", "https://accounts.google.com/signin/challenge", .load)
expect("the consent screen", "https://accounts.google.com/o/oauth2/auth", .load)
expect("the Music origin", "https://music.youtube.com/", .load)
expect("a static asset host", "https://ssl.gstatic.com/accounts/x", .load)
expect("a YouTube asset host", "https://s.ytimg.com/vi/abc/x.jpg", .load)
expect("plain http", "http://accounts.google.com/ServiceLogin", .load)

// ---- everything that used to be handed to another app ----------------------

// Each of these was answered "open it outside", which is `UIApplication.open`. For
// a domain the system has given to an app that is the YouTube Music app, not
// Safari: the session finishes in another app's cookie jar and ours is never
// written. They load now, and the two that matter most are named again below.
expect("a regional Google domain", "https://accounts.google.co.uk/ServiceLogin", .load)
expect("a blog post", "https://blog.youtube/", .load)
expect("an unrelated site", "https://example.com/", .load)
expect("the App Store over https", "https://apps.apple.com/app/id123", .load)

// ---- what is still refused -------------------------------------------------

// Every other scheme. WebKit hands these to the system by itself whether we ask
// it to or not, so refusing them is the whole of the remaining job — and unlike
// `open`, a refusal is a decision this app owns.
expect("the YouTube Music app link", "youtube://music", .refuse(.notAWebPage))
expect("a youtube-music app link", "youtubemusic://", .refuse(.notAWebPage))
expect("a spotify-style app link", "spotify://", .refuse(.notAWebPage))

// The App Store, which a "get the app" banner links to.
expect("the App Store", "itms-apps://apps.apple.com/app/id123", .refuse(.notAWebPage))

// Every other scheme a page can hand over. All of them leave the app.
expect("mailto", "mailto:someone@example.com", .refuse(.notAWebPage))
expect("tel", "tel:+15550100", .refuse(.notAWebPage))
expect("sms", "sms:body", .refuse(.notAWebPage))
expect("facetime", "facetime:someone@example.com", .refuse(.notAWebPage))
expect("maps", "maps://?q=coffee", .refuse(.notAWebPage))
expect("javascript:", "javascript:void(0)", .refuse(.notAWebPage))
expect("data:", "data:text/html,<b>hi</b>", .refuse(.notAWebPage))
expect("file:", "file:///etc/passwd", .refuse(.notAWebPage))
expect("about:", "about:blank", .refuse(.notAWebPage))
expect("blob:", "blob:https://music.youtube.com/abc", .refuse(.notAWebPage))

// A scheme with no host is refused on the scheme, before its host is even read —
// a hostname that looks right is not a reason to follow a `youtube://` URL.
expect("a scheme with no host", "youtube://", .refuse(.notAWebPage))

// ---- nothing at all -------------------------------------------------------

// A malformed or missing URL is refused rather than allowed. Allowing "I do not
// know where this goes" is how a policy becomes decorative.
check("nil is refused", SignInNavigation.decision(for: nil) == .refuse(.unusable))
expect("an empty string", "", .refuse(.unusable))
expect("no scheme", "accounts.google.com/ServiceLogin", .refuse(.unusable))
expect("a scheme with no host over https", "https://", .refuse(.unusable))

// The two refusals say different things, and both say something: a cancel the
// listener cannot see is a cancel they read as a broken sign-in.
check("a non-web page explains itself", !SignInNavigation.Refusal.notAWebPage.summary.isEmpty)
check("an unusable URL explains itself", !SignInNavigation.Refusal.unusable.summary.isEmpty)
check(
    "the two refusals read differently",
    SignInNavigation.Refusal.notAWebPage.summary != SignInNavigation.Refusal.unusable.summary
)

// ---- the host list, which no longer decides anything -----------------------

// The reason the suffix comparison has a dot in it. A check written as
// `host.contains("google.com")` — or a suffix match without the dot — accepts
// this, and it would then be labelled as Google's sign-in. It answers a different
// question now (should the listener be told they have wandered off) but it still
// has to be right, so the test stays.
check("a sign-in host is recognised", SignInNavigation.isSignInHost(URL(string: "https://music.youtube.com/")))
check("so is accounts.google.com", SignInNavigation.isSignInHost(URL(string: "https://accounts.google.com/ServiceLogin")))
// A *regional* Google domain is deliberately not on the list. The login host is
// `accounts.google.com` everywhere — the sign-in never goes to `accounts.google.co.uk` —
// so widening the list to every regional domain would buy nothing and enlarge the
// surface a lookalike could be aimed at. Note what it still does, though: it
// *loads* (checked above). Not being Google's sign-in is a reason to say where the
// listener is, never a reason to send them somewhere else.
check("a regional Google domain is not a sign-in host", !SignInNavigation.isSignInHost(URL(string: "https://accounts.google.co.uk/x")))
check("a lookalike is not", !SignInNavigation.isSignInHost(URL(string: "https://accounts.google.com.evil.test/")))
check("google in the path is not", !SignInNavigation.isSignInHost(URL(string: "https://evil.test/accounts.google.com")))
check("a host merely ending in the letters is not", !SignInNavigation.isSignInHost(URL(string: "https://notgoogle.com/")))
check("a subdomain of a lookalike is not", !SignInNavigation.isSignInHost(URL(string: "https://x.notgoogle.com/")))
check("a non-web scheme is not a sign-in host", !SignInNavigation.isSignInHost(URL(string: "youtube://music.youtube.com")))

// Every entry is a suffix of its own registrable domain and nothing else. A
// domain that would let a lookalike through does not belong in here.
check("the host list is not empty", !SignInNavigation.signInDomains.isEmpty)
check(
    "no entry carries a leading dot",
    SignInNavigation.signInDomains.allSatisfy { !$0.hasPrefix(".") },
    SignInNavigation.signInDomains.joined(separator: ", ")
)

// The line that tells a listener they have left the sign-in names the host,
// because the host is the only part they can check against their own address bar.
let advice = SignInNavigation.offSignInHostAdvice(host: "blog.youtube")
check("the advice names the host", advice.contains("blog.youtube"), advice)
check("the advice is not empty for no host", !SignInNavigation.offSignInHostAdvice(host: nil).isEmpty)
check("the advice is not empty for an empty host", !SignInNavigation.offSignInHostAdvice(host: "").isEmpty)

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

// ---- the capture: the page's own identity, not a later guess --------------

// The bug that kept the session in the web view while the app stayed signed
// out: `evaluateJavaScript` hands back a natively-decoded object for a JS
// object, not the JSON string Android returns. Reading it as a string fails on
// every signed-in page, so Continue could never succeed. Both shapes are
// accepted, with fixtures built as values rather than raw JSON text.
let liveDict: [String: Any] = [
    "loggedIn": "true",
    "pageId": "page-1",
    "dataSyncId": "account||delegated",
    "authUser": "1",
    "visitorData": "CgABC",
    "clientVersion": "1.20250101.01.00",
]
if let fields = SignInCapture.parse(jsResult: liveDict) {
    check("a decoded object parses", fields.loggedIn)
    check("the page id survives", fields.pageId == "page-1")
    check("the raw datasync id survives", fields.dataSyncId == "account||delegated")
    check("the auth user survives", fields.authUser == "1")
    check("visitor data survives", fields.visitorData == "CgABC")
    check("the client version survives", fields.clientVersion == "1.20250101.01.00")
} else {
    check("a decoded object parses", false)
}

// The Android shape still parses, so the rule is stated once and the platform
// difference cannot reintroduce the bug by changing which branch runs.
let androidJSON = """
{"loggedIn":"true","pageId":"page-1","dataSyncId":"ds-1","authUser":"0","visitorData":"CgABC","clientVersion":"1.0"}
"""
if let fields = SignInCapture.parse(jsResult: androidJSON) {
    check("a JSON string parses too", fields.loggedIn && fields.pageId == "page-1")
} else {
    check("a JSON string parses too", false)
}

// A page without ytcfg — an error page, a redirect that hasn't landed — is a
// fine answer and not an error. NSNull is what a null in the object arrives as,
// and reading it as the string "null" would be an identity made of nothing.
check("nil is no session", SignInCapture.parse(jsResult: nil) == nil)
check("NSNull is no session", SignInCapture.parse(jsResult: NSNull()) == nil)
let signedOut: [String: Any] = ["loggedIn": "false"]
check("a signed-out page reports signed out",
      SignInCapture.parse(jsResult: signedOut)?.loggedIn == false)
let nulls: [String: Any] = ["loggedIn": "true", "pageId": NSNull(), "dataSyncId": NSNull()]
if let fields = SignInCapture.parse(jsResult: nulls) {
    check("nulls are absent, not identities", fields.loggedIn && fields.pageId == nil && fields.dataSyncId == nil)
} else {
    check("nulls are absent, not identities", false)
}
check("a number is not a session", SignInCapture.parse(jsResult: 42) == nil)

// ---- normalizeDataSyncId ----------------------------------------------------

// Same rule as upstream and shared `Innertube`: the second half of
// `account||delegated` is the active identity.
check("a plain id is returned as is", SignInCapture.normalizeDataSyncId("ds-123") == "ds-123")
check("a delegated id resolves to the active half",
      SignInCapture.normalizeDataSyncId("account||delegated") == "delegated")
check("an empty active half falls back to the account half",
      SignInCapture.normalizeDataSyncId("account||") == "account")
check("blank is absent", SignInCapture.normalizeDataSyncId(nil) == nil
    && SignInCapture.normalizeDataSyncId("") == nil
    && SignInCapture.normalizeDataSyncId("   ") == nil
    && SignInCapture.normalizeDataSyncId("||") == nil)

// ---- the sign-in screen cannot leave the app -------------------------------

// Textual, and said so: this reads the sign-in view's source rather than running
// it, because the claim is about a capability that is *absent* and the only way to
// show a capability is absent is to show the call is not there. It is a guard
// against the branch being reintroduced, not a proof about runtime behaviour.
//
// Scoped to the sign-in file on purpose. `NSWorkspace.shared.open` is correct in
// PlaybackController — the Last.fm sign-in genuinely is another app — and a check
// this broad would have to fail on that.
if let root = CommandLine.arguments.dropFirst().first {
    let source = URL(fileURLWithPath: root)
        .appendingPathComponent("AppleApp/Sources/UI/YtMusicLoginView.swift")
    guard let text = try? String(contentsOf: source, encoding: .utf8) else {
        check("the sign-in view's source can be read", false, source.path)
        exit(failures == 0 ? 0 : 1)
    }
    // Matched on the *call*, not on the type name: `SignInUserAgent`'s own doc
    // comment explains at length why `ASWebAuthenticationSession` is not the answer,
    // and a guard that matched the prose would fail on the explanation.
    for (what, call) in [
        ("UIApplication.open", "UIApplication.shared.open("),
        ("the deprecated openURL", ".openURL("),
        ("NSWorkspace.open", "NSWorkspace.shared.open("),
        ("a Safari view controller", "SFSafariViewController("),
        ("ASWebAuthenticationSession", "ASWebAuthenticationSession("),
    ] {
        check("the sign-in screen never calls \(what)", !text.contains(call))
    }
    // And the other half of the same bug: the old `.openOutside` decision itself.
    check("the old open-outside decision is gone", !text.contains("openOutside"))
    check("the policy has no open-outside decision either",
          !String(describing: SignInNavigation.Decision.self).contains("openOutside"))
    // The confirmation lives in the navigation bar, like upstream's header —
    // not in a bottom Continue button below a page that scrolls.
    check("the confirmation matches upstream", text.contains("Use This Profile"))
    check("no bottom Continue button", !text.contains("Text(\"Continue\")"))
} else {
    print("  · no repository root given, skipping the source guard")
}

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
