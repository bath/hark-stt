import AppKit
import HarkCore

/// Plays the current pack's sound for each transition.
@MainActor
final class SoundPlayer {
    let library: SoundLibrary
    private let settings: HarkSettings
    private var loaded: [URL: NSSound] = [:]
    private var previewTimers: [Timer] = []

    init(library: SoundLibrary, settings: HarkSettings) {
        self.library = library
        self.settings = settings
    }

    func play(_ transition: SoundTransition) {
        guard let url = library.current(settings)?.files[transition] else { return }
        let sound = loaded[url] ?? NSSound(contentsOf: url, byReference: true)
        guard let sound else { return }
        loaded[url] = sound
        sound.stop()
        sound.volume = Float(settings.soundVolume)
        sound.play()
    }

    /// All four sounds of the current pack, one after the other.
    func preview() {
        previewTimers.forEach { $0.invalidate() }
        previewTimers = SoundTransition.allCases.enumerated().map { index, transition in
            Timer.scheduledTimer(withTimeInterval: Double(index) * 0.9, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.play(transition) }
            }
        }
    }
}
