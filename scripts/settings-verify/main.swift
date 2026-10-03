import Foundation
import BitChordShared
let mode = CommandLine.arguments[1]
let keys = ["autoplay", "smart_fade_enabled"]
for key in keys {
    if mode == "missing" { UserDefaults.standard.removeObject(forKey: key) }
    else { UserDefaults.standard.set(mode == "on", forKey: key) }
}
let expected = mode != "off"
precondition(PlatformSettings.shared.getBoolean(key: "autoplay", default: true) == expected)
precondition(PlatformSettings.shared.getBoolean(key: "smart_fade_enabled", default: true) == expected)
precondition(AppSettings.shared.autoplay.value as? Bool == expected)
precondition(AppSettings.shared.smartFadeEnabled.value as? Bool == expected)
print("PASS \(mode) Autoplay/Automix preferences")
for key in keys { UserDefaults.standard.removeObject(forKey: key) }
