import Foundation
import Speech

/// The languages the listening writes in (Réglages → Écoute). Named in their own language, like
/// the app's languages.
enum ListenLanguage {
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let choices: [Choice] = [
        Choice(id: "fr-FR", name: "Français"),
        Choice(id: "en-US", name: "English (US)"),
        Choice(id: "en-GB", name: "English (UK)"),
        Choice(id: "es-ES", name: "Español"),
        Choice(id: "it-IT", name: "Italiano"),
        Choice(id: "de-DE", name: "Deutsch"),
    ]

    static let key = "listenLanguage"

    #if DEBUG
    /// Debug builds only: the language of the self-test, whatever is chosen.
    nonisolated(unsafe) static var override: String?
    #endif

    /// The one chosen; by default the system's, when it is one of them — else French.
    static var current: String {
        #if DEBUG
        if let override { return override }
        #endif
        if let id = UserDefaults.standard.string(forKey: key), choices.contains(where: { $0.id == id }) { return id }
        return systemDefault
    }

    static var systemDefault: String {
        let language = Locale.current.language.languageCode?.identifier ?? "fr"
        let region = Locale.current.region?.identifier ?? ""
        return choices.first { $0.id == "\(language)-\(region)" }?.id
            ?? choices.first { $0.id.hasPrefix(language + "-") }?.id
            ?? "fr-FR"
    }

    static func name(_ id: String) -> String {
        choices.first { $0.id == id }?.name ?? id
    }
}

/// Apple's on-device transcription model for a language. It is a system asset: downloaded once
/// per language, shared by every app, and never part of Void Notes.
@available(macOS 26, iOS 26, *)
enum SpeechModel {
    enum Status {
        case ready
        case needsDownload
        case unsupported
    }

    static func locale(_ id: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
    }

    static func status(_ id: String) async -> Status {
        guard SpeechTranscriber.isAvailable, let locale = await locale(id) else { return .unsupported }
        switch await AssetInventory.status(forModules: [module(locale)]) {
        case .installed: return .ready
        // "Supported" also describes a model already on the device for another app, not yet
        // given to this one: claiming it fetches nothing, so it isn't asked.
        case .supported: return await isOnDevice(locale) ? .ready : .needsDownload
        case .downloading: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// The locale to listen in, its model ready. Throws a sentence one can act on.
    static func ready(_ id: String) async throws -> Locale {
        guard let locale = await locale(id) else { throw ListenError.unsupported(ListenLanguage.name(id)) }
        switch await status(id) {
        case .ready:
            // A model already on the device, given to Void Notes.
            if await AssetInventory.status(forModules: [module(locale)]) != .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) {
                try await request.downloadAndInstall()
            }
            return locale
        case .needsDownload: throw ListenError.notInstalled(id)
        case .unsupported: throw ListenError.unsupported(ListenLanguage.name(id))
        }
    }

    /// Downloads the language's model through the system. `progress` is the system's own,
    /// handed over as soon as it exists.
    static func install(_ id: String, progress: @escaping @MainActor (Progress) -> Void) async throws {
        guard let locale = await locale(id) else { throw ListenError.unsupported(ListenLanguage.name(id)) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) {
            await progress(request.progress)
            try await request.downloadAndInstall()
        }
    }

    private static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    private static func isOnDevice(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }
}

enum ListenError: LocalizedError {
    case microphoneDenied
    case noMicrophone
    /// iPhone: a call or another app holds the microphone.
    case microphoneBusy
    case audioSession(Int)
    case unsupported(String)
    /// The language's model isn't on the device yet: its id (`ListenLanguage`).
    case notInstalled(String)
    /// The Mac's sound couldn't be heard: the step, and Core Audio's code.
    case macSound(String, OSStatus)
    /// The Mac's sound stayed silent for the whole listening: most often, the permission refused.
    case macSilent
    /// The output changed during the listening, and the Mac's sound couldn't be taken on the new one.
    case macSoundLost

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            #if os(macOS)
            String(localized: "Void Notes n'a pas accès au micro. Autorisez-le dans Réglages Système → Confidentialité et sécurité → Micro.")
            #else
            String(localized: "Void Notes n'a pas accès au micro. Autorisez-le dans Réglages → Apps → Void Notes β → Micro.")
            #endif
        case .noMicrophone:
            String(localized: "Aucun micro n'est disponible.")
        case .microphoneBusy:
            String(localized: "Le micro est pris par un appel ou par une autre app.")
        case .audioSession(let code):
            String(localized: "Le micro n'a pas pu démarrer (code \(code)).")
        case .unsupported(let language):
            String(localized: "La transcription sur l'appareil ne sait pas encore écrire en \(language).")
        case .notInstalled(let id):
            String(localized: "Le modèle de transcription en \(ListenLanguage.name(id)) n'est pas encore sur l'appareil.")
        case .macSound(let step, let code):
            String(localized: "Le son du Mac n'a pas pu être capté (\(step), code \(Int(code))).")
        case .macSoundLost:
            String(localized: "Le son du Mac n'est plus capté depuis que la sortie audio a changé.")
        case .macSilent:
            String(localized: "Le son du Mac est resté muet pendant toute l'écoute. Si un appel ou une vidéo jouait, autorisez Void Notes dans Réglages Système → Confidentialité et sécurité → Enregistrement audio du système.")
        }
    }
}
