import AppKit

enum Sounds {
    private static func play(_ name: String, volume: Float = 0.35) {
        guard Settings.shared.playSounds else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }

    static func start() { play("Pop") }
    static func done() { play("Tink", volume: 0.25) }
    static func error() { play("Basso", volume: 0.3) }
}
