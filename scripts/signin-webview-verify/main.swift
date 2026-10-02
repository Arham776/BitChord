import AppKit
import SwiftUI
import WebKit
import BitChordShared

/// Exercises the app's actual coordinator, WebKit cookie store, and page probe.
/// HTML and credentials are synthetic; no saved account or Keychain is touched.
@main struct SignInWebViewChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var failures = 0
        var checks = 0
        func check(_ label: String, _ ok: Bool) {
            checks += 1
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(label)")
        }
        func waitUntil(_ predicate: () -> Bool) async {
            for _ in 0..<100 {
                if predicate() { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let flow = LoginFlow()
        var captures: [SignInCapture] = []
        var complete: ((Bool) -> Void)?
        let coordinator = LoginWebCoordinator(flow: flow, onCaptured: { session, done in
            captures.append(session)
            complete = done
        }, onUnavailable: { flow.captureFailed($0) }, profileLoader: { _, _ in
            SignInProfilePreview(name: "Fixture Channel", subtitle: "@fixture", avatarURL: nil)
        })
        let view = coordinator.makeWebView(loadInitialPage: false)
        view.frame = NSRect(x: 0, y: 0, width: 393, height: 740)
        let originalStore = view.configuration.websiteDataStore
        let jar = originalStore.httpCookieStore
        for properties: [HTTPCookiePropertyKey: Any] in [
            [.domain: ".youtube.com", .path: "/", .name: "SAPISID", .value: "synthetic-fixture-only", .secure: "TRUE"],
            [.domain: ".google.com", .path: "/", .name: "SID", .value: "foreign-fixture-only"],
            [.domain: "music.youtube.com", .path: "/private", .name: "OTHER_PATH", .value: "other-path-only"]
        ] {
            await jar.setCookie(HTTPCookie(properties: properties)!)
        }
        let musicURL = URL(string: "https://music.youtube.com/")!
        func load(_ config: String?, origin: URL = musicURL) async {
            flow.navigating(to: origin)
            let script = config.map { "window.ytcfg = {get: function(key) { return (\($0))[key]; }};" } ?? ""
            view.loadHTMLString("<html><body>Isolated sign-in fixture<script>\(script)</script></body></html>", baseURL: origin)
            await waitUntil { !view.isLoading && !flow.checkingPage && !flow.loadingProfile }
        }

        await load("{LOGGED_IN:false}")
        check("upstream confirmation remains available after Music loads", flow.pageReady)
        check("an unfinished login keeps the Google page visible", !flow.showsCompletion)
        flow.session.take?()
        try? await Task.sleep(for: .milliseconds(100))
        check("an incomplete login never reaches the validation callback", captures.isEmpty)

        await load(nil)
        check("a page with no ytcfg remains in the browser", flow.pageReady && !flow.showsCompletion)

        let selected = "{LOGGED_IN:true,DELEGATED_SESSION_ID:'brand-fixture',DATASYNC_ID:'account||brand-fixture',SESSION_INDEX:'1',VISITOR_DATA:'visitor-fixture',INNERTUBE_CLIENT_VERSION:'1.fixture'}"
        // ytcfg can arrive after didFinish. Confirmation must still be able to
        // read that late configuration without requiring a fresh navigation.
        _ = try? await view.evaluateJavaScript("window.ytcfg = {get: function(key) { return (\(selected))[key]; }};", in: nil, contentWorld: .page)
        flow.session.take?()
        await waitUntil { captures.count == 1 }
        check("late page configuration can still be confirmed without reloading", captures.count == 1 && flow.taking)
        complete?(false)
        await waitUntil { !flow.taking }
        captures.removeAll()
        complete = nil

        await load(selected)
        check("a signed-in page shows native completion", flow.pageReady && flow.showsCompletion)
        check("arrival never captures automatically", captures.isEmpty)
        check("the card shows this candidate's name and handle", flow.profile?.name == "Fixture Channel" && flow.profile?.subtitle == "@fixture")
        check("the card is tied to the live delegated identity", flow.profileScope?.pageId == "brand-fixture")
        let before = Innertube.shared.cookie
        let fields = SignInCapture.parse(jsResult: ["loggedIn":"true", "pageId":"brand-fixture", "dataSyncId":"account||brand-fixture", "authUser":"1", "clientVersion":"1.fixture"])!
        let request = SignInProfileLoader.request(cookie: "SAPISID=synthetic-fixture-only", fields: fields)!
        check("the preview goes only to Music's account-menu endpoint", request.url?.host == "music.youtube.com" && request.url?.path == "/youtubei/v1/account/account_menu")
        check("the preview request retains the selected account and channel", request.value(forHTTPHeaderField: "X-Goog-AuthUser") == "1" && request.value(forHTTPHeaderField: "X-Goog-PageId") == "brand-fixture")
        check("preview signing never applies the candidate to the active app session", Innertube.shared.cookie == before)
        let other = selected.replacingOccurrences(of: "brand-fixture", with: "other-brand")
        _ = try? await view.evaluateJavaScript("window.ytcfg = {get: function(key) { return (\(other))[key]; }};", in: nil, contentWorld: .page)
        flow.session.take?()
        await waitUntil { !flow.taking }
        check("a changed channel cannot be saved under the previously shown profile", captures.isEmpty && flow.profile == nil && flow.captureFailedMessage != nil)
        await load(selected)
        flow.chooseProfile()
        check("profile selection reveals the same browser", !flow.showsCompletion && view.configuration.websiteDataStore === originalStore)

        // WebKit reports a cancelled external-app link as a policy change. It
        // must leave the signed-in page and its confirmation usable.
        flow.refusal = .notAWebPage
        coordinator.webView(view, didFailProvisionalNavigation: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        check("blocking an app link preserves the available profile", flow.pageReady)

        flow.session.take?()
        await waitUntil { captures.count == 1 }
        check("explicit confirmation captures once", captures.count == 1)
        check("the chosen delegated identity survives", captures.first?.pageId == "brand-fixture" && captures.first?.dataSyncId == "brand-fixture")
        check("the page's account and client scope survives", captures.first?.authUser == "1" && captures.first?.visitorData == "visitor-fixture" && captures.first?.clientVersion == "1.fixture")
        check("only Music cookies are captured", captures.first?.cookie == "SAPISID=synthetic-fixture-only")
        check("capture keeps Checking until validation finishes", flow.taking && !flow.pageReady && flow.showsCompletion)
        flow.session.take?()
        try? await Task.sleep(for: .milliseconds(100))
        check("a second tap cannot start concurrent validation", captures.count == 1)
        complete?(false)
        await waitUntil { !flow.taking }
        check("a refused candidate leaves the selected page available to retry", flow.pageReady && flow.captureFailedMessage != nil)
        flow.session.take?()
        await waitUntil { captures.count == 2 }
        check("retry captures the current profile again", captures.count == 2 && flow.taking)
        complete?(true)
        await waitUntil { !flow.taking }
        check("accepted validation clears Checking and errors", !flow.taking && flow.captureFailedMessage == nil)
        flow.session.take?()
        try? await Task.sleep(for: .milliseconds(100))
        check("an accepted candidate cannot be submitted twice", captures.count == 2)

        await load(selected, origin: URL(string: "https://music.youtube.com.evil.test/")!)
        check("a lookalike cannot enable confirmation despite its ytcfg", !flow.pageReady && !flow.showsCompletion)
        let passwordHTML = #"""
        <html><body>
        <button id="alternative" onclick="window.alternativeClicks=(window.alternativeClicks || 0)+1; setTimeout(() => { document.getElementById('passwordOption').hidden=false; this.hidden=true; }, 300);">Try another way</button>
        <button id="passwordOption" hidden onclick="window.passwordClicks=(window.passwordClicks || 0)+1; window.passwordChosen=true; document.getElementById('passwordInput').hidden=false; this.hidden=true;">Enter your password</button>
        <input id="passwordInput" type="password" value="synthetic-do-not-touch" hidden>
        </body></html>
        """#
        func waitForFlag(_ view: WKWebView, _ flag: String) async -> Bool {
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript("window." + flag + " === true", in: nil, contentWorld: .page)) as? Bool == true { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        view.loadHTMLString(passwordHTML, baseURL: URL(string: "https://accounts.google.com/v3/signin/challenge/pk"))
        let passwordChosen = await waitForFlag(view, "passwordChosen")
        check("the passkey-first page opens Google's real password alternative", passwordChosen)
        let clickedOnce = (try? await view.evaluateJavaScript("window.alternativeClicks === 1 && window.passwordClicks === 1", in: nil, contentWorld: .page)) as? Bool
        check("overlapping page callbacks choose each method once", clickedOnce == true)
        let untouched = (try? await view.evaluateJavaScript("document.getElementById('passwordInput').value === 'synthetic-do-not-touch'", in: nil, contentWorld: .page)) as? Bool
        check("choosing a method never changes credential fields", untouched == true)
        view.loadHTMLString("<html><body><button onclick='window.laterChallengeSkipped=true'>Try another way</button></body></html>", baseURL: URL(string: "https://accounts.google.com/v3/signin/challenge/pk"))
        try? await Task.sleep(for: .milliseconds(500))
        let skippedAgain = (try? await view.evaluateJavaScript("window.laterChallengeSkipped === true", in: nil, contentWorld: .page)) as? Bool
        check("a later verification challenge is not automatically skipped", skippedAgain == false)

        let spaFlow = LoginFlow()
        let spaCoordinator = LoginWebCoordinator(flow: spaFlow, onCaptured: { _, _ in }, onUnavailable: { spaFlow.captureFailed($0) }, profileLoader: { _, _ in nil })
        let spaView = spaCoordinator.makeWebView(loadInitialPage: false)
        spaView.frame = view.frame
        spaView.loadHTMLString(passwordHTML, baseURL: URL(string: "https://accounts.google.com/v3/signin/identifier"))
        await waitUntil { !spaView.isLoading }
        _ = try? await spaView.evaluateJavaScript("history.pushState({}, '', '/v3/signin/challenge/pk'); document.body.appendChild(document.createElement('span'));", in: nil, contentWorld: .page)
        let spaChosen = await waitForFlag(spaView, "passwordChosen")
        check("a passkey challenge inside the same document is handled", spaChosen)
        spaCoordinator.stopObserving()

        let unavailableFlow = LoginFlow()
        let unavailableCoordinator = LoginWebCoordinator(flow: unavailableFlow, onCaptured: { _, _ in }, onUnavailable: { unavailableFlow.captureFailed($0) })
        let unavailableView = unavailableCoordinator.makeWebView(loadInitialPage: false)
        unavailableView.frame = view.frame
        unavailableView.loadHTMLString("<html><body><button onclick='this.hidden=true; document.getElementById(\"device\").hidden=false'>Try another way</button><button id='device' hidden onclick='window.deviceChosen=true'>Use another device</button></body></html>", baseURL: URL(string: "https://accounts.google.com/v3/signin/challenge/pk"))
        await waitUntil { unavailableFlow.passwordAdvice?.contains("if it is offered") == true }
        let choseDevice = (try? await unavailableView.evaluateJavaScript("window.deviceChosen === true", in: nil, contentWorld: .page)) as? Bool
        check("when Google offers no password, other methods remain the user's choice", choseDevice == false && unavailableFlow.passkeyHelp && !unavailableFlow.selectingPassword)
        unavailableCoordinator.stopObserving()

        let layoutFlow = LoginFlow()
        layoutFlow.navigating(to: musicURL)
        layoutFlow.inspectedPage(loggedIn: true)
        layoutFlow.profile = SignInProfilePreview(name: "Alex Morgan", subtitle: "@alexmorgan", avatarURL: nil)
        let hosted = NSHostingView(rootView: SignInCompletionStep(flow: layoutFlow, onConfirm: {}, onChoose: {})
            .frame(width: 720, height: 640).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .environment(\.controlActiveState, .key))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosted
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(200))
        hosted.layoutSubtreeIfNeeded()
        if let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) {
            hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])!
            try? png.write(to: URL(fileURLWithPath: "/tmp/bitchord-auth-mac-preview.png"))
            check("the polished review card renders at the Mac sheet size", true)
        } else { check("the polished review card renders at the Mac sheet size", false) }
        window.orderOut(nil)

        coordinator.stopObserving()
        check("dismissing disconnects the confirmation action", flow.session.take == nil)
        coordinator.webView(view, didFinish: nil)
        check("late navigation callbacks cannot restore confirmation", !flow.pageReady)

        print("\n\(failures == 0 ? "all \(checks) checks passed" : "\(failures) of \(checks) checks FAILED")")
        exit(failures == 0 ? 0 : 1)
    }
}
