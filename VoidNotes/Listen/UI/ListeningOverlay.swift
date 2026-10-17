import SwiftUI

/// At the foot of the note: the listening bar while something is being listened to, and the
/// player of the recording open — on the Mac, over the foot of the note; on the iPhone, above the
/// keyboard or the spaces.
struct ListeningOverlay: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    private let listener = Listener.shared
    #if os(macOS)
    private let playback = AudioPlayback.shared
    private var playerShown: Bool { playback.isOpen }
    #else
    private let playerShown = false
    #endif

    var body: some View {
        VStack(spacing: 8) {
            #if os(macOS)
            if playerShown {
                PlayerBar(store: store, model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            #endif
            if listener.isActive {
                ListeningBar(listener: listener, store: store, model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        #if os(macOS)
        .padding(.horizontal, 16)
        .padding(.bottom, listener.isActive || playerShown ? 12 : 0)
        #else
        .padding(.horizontal, 12)
        .padding(.vertical, listener.isActive ? 6 : 0)
        #endif
        .animation(Theme.quick, value: listener.isActive)
        .animation(Theme.quick, value: playerShown)
    }
}
