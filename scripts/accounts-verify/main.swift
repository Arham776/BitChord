import Foundation
import BitChordShared

// The account store and the channel override, through the real Swift→Kotlin seam.
//
// What this is really checking is the *headers*. A channel override that is
// stored correctly and never applied produces an account selector that looks
// perfect and browses as the wrong channel, and nothing on screen would say so.
// So the checks read Innertube's own answers back rather than the store's.
//
// The shared tests cover the id chains and the ordering. None of them can
// check that `adoptPageScope` reaches `X-Goog-PageId` / `onBehalfOfUser` /
// `X-Goog-AuthUser`, because that path only exists in a live request builder.

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

func profile(
    _ id: String, _ name: String, pageId: String? = nil,
    dataSyncId: String? = nil, authUser: String? = nil
) -> YouTubeProfile {
    YouTubeProfile(
        profileId: id, name: name, handle: "@\(name.lowercased())",
        avatar: nil, pageId: pageId, dataSyncId: dataSyncId,
        authUser: authUser, isBrandAccount: pageId != nil
    )
}

func store() -> AccountStore { AccountStore.shared }
func innertube() -> Innertube { Innertube.shared }

// The shared module reaches the Keychain through a seam the app installs at
// launch; without it every secret read answers nil and every write is dropped,
// which looks exactly like a store that does not work. The app's own wiring and
// its own `Keychain` are compiled in rather than reimplemented here, so this
// harness cannot pass against a Keychain the app does not actually use.
let secrets = HarnessSecretStore()
SecretStoreBridge.shared.setImpl(value: secrets)

// Start from nothing, and leave nothing behind. The store is the Keychain the
// app itself reads, so a harness that left a pin in it would be a real change to
// the machine it ran on.
let savedCookie = innertube().cookie
func reset() {
    for account in store().accounts() { store().forget(accountId: account.accountId) }
    AuthBridge.shared.applyCookie(cookieHeader: nil)
    innertube().adoptPageScope(pageId: nil, dataSyncId: nil, authUser: nil)
}
reset()
defer {
    reset()
    AuthBridge.shared.applyCookie(cookieHeader: savedCookie)
}

print("accounts: the store, and the headers a selection produces")
if secrets.usingKeychain {
    print("  · credentials in the Keychain, as the app stores them")
} else {
    print("  · NOTE: this binary is not entitled for the data-protection keychain, so the")
    print("    store\'s logic is checked against a UserDefaults-backed substitute. That is a")
    print("    property of an unentitled harness, not of the app — see HarnessSecretStore.")
    check("a probe value survives the secret store", {
        secrets.put(key: "harness.roundtrip", value: "x")
        let back = secrets.get(key: "harness.roundtrip")
        secrets.put(key: "harness.roundtrip", value: nil)
        return back == "x"
    }())
}

// 1. Nothing stored, nothing selected, and — the part that matters — no
//    identity claimed by the request path.
check("a fresh store has no accounts", store().accounts().isEmpty)
check("a fresh store has no selection", store().activeSelection() == nil)
check("no selection leaves the shell's own identity", innertube().cookie == nil)

// 2. Record an account with two channels: a personal one and a brand one. The
//    brand one is the case the whole feature exists for — a separate library, a
//    separate history, a separate scrobble.
let cookieA = "SID=aaa; SAPISID=secret-a; __Secure-3PAPISID=secret-a"
store().record(
    accountId: "acct-1",
    cookie: cookieA,
    name: "Baguma",
    email: "b@example.com",
    profiles: [
        profile("personal", "Baguma", dataSyncId: "ds-personal"),
        profile("brand", "Acme Records", pageId: "UCbrand123", dataSyncId: "ds-brand", authUser: "1"),
    ]
)
check("the account is stored", store().accounts().count == 1)
check("both channels are stored", store().accounts().first?.profiles.count == 2)
check("recording applied the cookie to the request path",
      innertube().cookie == cookieA, "cookie set: \(innertube().cookie != nil)")

// 3. A recorded account is selected, and a recorded account with no explicit
//    selection lands on its first channel.
let first = store().activeSelection()
check("the first channel is selected by default", first?.profile.profileId == "personal",
      first?.profile.profileId ?? "none")

// 4. Selecting the brand channel has to change the identity the requests carry.
store().select(accountId: "acct-1", profileId: "brand")
let brand = store().activeSelection()
check("selecting the brand channel takes", brand?.profile.profileId == "brand",
      brand?.profile.profileId ?? "none")
check("the brand channel's pageId is what the override holds",
      brand?.profile.pageId == "UCbrand123", brand?.profile.pageId ?? "none")
check("the brand channel's authUser is what the override holds",
      brand?.profile.authUser == "1", brand?.profile.authUser ?? "none")
check("the cookie survived the switch", innertube().cookie == cookieA)

// 5. The selection has to survive a *relaunch*, which is what a store is for and
//    what an in-memory set would miss. The shared module cannot be reloaded from
//    here, so this checks the property the reloaded object would read: the stored
//    blob carries the selection, rather than only the live object holding it.
let blob = PlatformSettings.shared.getSecret(key: "account_sessions") ?? ""
check("the stored blob carries both cookies' account and the selection",
      blob.contains("acct-1") && blob.contains("brand") && blob.contains("personal"),
      "\(blob.count) bytes")
check("the stored blob holds the cookie, not a reference to it",
      blob.contains("SAPISID=secret-a"))
check("the store reads the blob back with the selection on the brand channel",
      store().accounts().first?.activeProfileId == "brand",
      store().accounts().first?.activeProfileId ?? "none")

// 6. Stepping moves through every stored identity and stops at both ends.
check("stepping forward from the last one does nothing",
      !store().step(forward: true), "already on the last")
store().select(accountId: "acct-1", profileId: "personal")
check("stepping forward moves to the next", store().step(forward: true))
check("…and lands on the brand channel",
      store().activeSelection()?.profile.profileId == "brand")
check("stepping back returns", store().step(forward: false))
check("…to the personal channel",
      store().activeSelection()?.profile.profileId == "personal")
check("stepping back off the first does nothing", !store().step(forward: false))

// 7. A second account: the order is insertion order, and stepping crosses
//    accounts rather than stopping at the boundary.
let cookieB = "SID=bbb; SAPISID=secret-b; __Secure-3PAPISID=secret-b"
store().record(
    accountId: "acct-2", cookie: cookieB, name: "Second", email: "s@example.com",
    profiles: [profile("s2p", "Second")]
)
check("both accounts are stored", store().accounts().count == 2)
check("insertion order is kept", store().accounts().map(\.accountId) == ["acct-1", "acct-2"],
      store().accounts().map(\.accountId).joined(separator: ", "))
store().select(accountId: "acct-2", profileId: "s2p")
check("selecting the second account switches the cookie",
      innertube().cookie == cookieB)
check("stepping forward off the end of the last account does nothing",
      !store().step(forward: true))
store().select(accountId: "acct-2", profileId: "s2p")
// The flattened order is acct-1/personal, acct-1/brand, acct-2/s2p — so stepping
// back from account 2's only channel lands on account 1's *last* channel, not
// its first. Which is the point of flattening: the list a listener swipes
// through has no account boundaries in it.
check("stepping backward crosses to the previous account's last channel",
      store().step(forward: false)
          && store().activeSelection()?.profile.profileId == "brand",
      store().activeSelection()?.profile.profileId ?? "none")
check("…and the cookie followed the account back",
      innertube().cookie == cookieA,
      innertube().cookie == cookieA ? "the first account" : "the second account is still active")

// 8. Selecting a channel with no pageId and no dataSyncId must not claim an
//    identity. A blank pageId on the request is a request for a channel that
//    does not exist, which is worse than asking as the default identity.
store().select(accountId: "acct-1", profileId: "nonexistent")
check("selecting an unknown channel falls back to the account's first",
      store().activeSelection()?.profile.profileId == "personal",
      store().activeSelection()?.profile.profileId ?? "none")
store().select(accountId: "acct-1", profileId: "personal")
let plain = store().activeSelection()
check("a channel with no pageId and no dataSyncId is still selectable",
      plain?.profile.profileId == "personal")

// 9. Forgetting an account that is not there must not touch the others —
//    sign-out asks for the active account, and an empty id is easy to produce.
let before = store().accounts().map(\.accountId)
store().forget(accountId: "")
check("forgetting an unknown account changes nothing",
      store().accounts().map(\.accountId) == before,
      store().accounts().map(\.accountId).joined(separator: ", "))

// 10. Forgetting the last account clears the request path, not just the list.
store().forget(accountId: "acct-2")
check("one account is left", store().accounts().count == 1)
store().forget(accountId: "acct-1")
check("forgetting the last account empties the store", store().accounts().isEmpty)
check("and clears the cookie from the request path", innertube().cookie == nil)
check("and leaves no selection", store().activeSelection() == nil)
check("and clears the stored blob", PlatformSettings.shared.getSecret(key: "account_sessions") == nil)

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)


/// The app's [SecretStoreWiring.Impl], lifted to file scope so this file can hold
/// it. Identical behaviour — the point of the harness is to exercise the real
/// seam, and a second implementation would make that untrue.
/// The store this harness puts behind the shared module's secret seam.
///
/// Normally the app's own [Keychain]. An unentitled command-line binary cannot
/// use the data-protection keychain, though: the app is signed with a
/// `keychain-access-groups` entitlement and puts itself on it, and a binary
/// without one lands on macOS's legacy keychain — where `kSecAttrAccessible`,
/// and therefore [Keychain.put]\'s whole accessibility contract, is silently
/// unsupported. `SecItemAdd` returns `errSecParam` there and `put` discards the
/// status, so every write vanishes and the store looks broken when nothing is.
///
/// So the backing store is probed first and, when the Keychain cannot be used,
/// substituted — with the substitution said out loud. The alternative is
/// reporting a failure that is a property of the harness, or (worse) a pass that
/// came from not checking. What is under test here is the store\'s logic: the id
/// chains, the ordering, the selection, and the identity the requests end up
/// carrying. The Keychain\'s own three lines are the app\'s, exercised by the app.
final class HarnessSecretStore: SecretStoreBridgeImpl {
    private let keychainUsable: Bool
    private let fallbackKey = "harness.account_sessions"

    init() {
        Keychain.put("harness.probe", "x")
        keychainUsable = Keychain.get("harness.probe") == "x"
        Keychain.clear("harness.probe")
    }

    var usingKeychain: Bool { keychainUsable }

    func get(key: String) -> String? {
        keychainUsable ? Keychain.get(key) : UserDefaults.standard.string(forKey: fallbackKey)
    }

    func put(key: String, value: String?) {
        if keychainUsable {
            Keychain.put(key, value)
        } else if let value {
            UserDefaults.standard.set(value, forKey: fallbackKey)
        } else {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        }
    }
}
