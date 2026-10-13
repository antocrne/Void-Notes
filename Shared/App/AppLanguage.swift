import Foundation
#if os(macOS)
import AppKit
#endif

/// The language of Void Notes' interface: the system's by default (French, or English for any
/// other language), or the one chosen in Réglages, as in Void. The choice is the app's own
/// AppleLanguages, which is also what System Settings → Langue et région → Apps (Mac) and
/// Réglages → Void Notes → Langue (iOS) change; it applies from the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, fr, en
    var id: String { rawValue }

    /// Each language is named in itself, so that it can be found whatever the current one.
    var label: String {
        switch self {
        case .system: String(localized: "Langue du système")
        case .fr: "Français"
        case .en: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice saved for Void Notes alone (UserDefaults would also return the system's list).
    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = languages.first else { return .system }
        return first.hasPrefix("fr") ? .fr : first.hasPrefix("en") ? .en : .system
    }

    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// The language the interface shows since launch.
    static let shown = Bundle.main.preferredLocalizations.first ?? "en"

    /// The language this choice gives the interface.
    var resolved: String {
        switch self {
        case .fr, .en: rawValue
        case .system:
            Bundle.preferredLocalizations(from: Self.supported, forPreferences: Self.systemLanguages).first ?? "en"
        }
    }

    /// Whether Void Notes must start again to show this choice.
    var needsRelaunch: Bool { resolved != Self.shown }

    private static var supported: [String] { Bundle.main.localizations.filter { $0 != "Base" } }

    /// The system's languages, whatever was chosen for Void Notes.
    private static var systemLanguages: [String] {
        #if os(macOS)
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String] ?? Locale.preferredLanguages
        #else
        Locale.preferredLanguages
        #endif
    }

    #if os(macOS)
    private(set) static var relaunchRequested = false

    /// Quits — the notes written and sent as at any other quit — then opens Void Notes again.
    @MainActor
    static func relaunch() {
        relaunchRequested = true
        NSApp.terminate(nil)
        relaunchRequested = false   // only reached when quitting was cancelled
    }

    /// Called as Void Notes quits, once everything is saved: a new copy is opened, this one ends
    /// right after. Waits for the system to have taken the request, the app being about to exit.
    static func relaunchIfRequested() {
        guard relaunchRequested else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in opened.signal() }
        _ = opened.wait(timeout: .now() + 3)
    }
    #endif
}
