import Foundation

/// Build-time identity shared by the app's Apple-platform integrations.
/// Values come from AppleApp/project.yml so contributors configure the bundle
/// ID once and use the same App Group in the app, widget, and shared framework.
enum AppIdentity {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.bitchord.BitChord"
    static let appGroupIdentifier = Bundle.main.object(
        forInfoDictionaryKey: "BitChordAppGroupIdentifier"
    ) as? String ?? "group.\(bundleIdentifier)"
}
