import Foundation

/// The Notch Island's motion, as a pure value. The numbers are the ones in
/// hark.lua and on the website (docs/index.html), so all three move alike.
/// The app steps it at 60 Hz and draws it.
public struct IslandModel: Sendable {
    public enum Mode: Sendable, Equatable {
        case idle, recording, transcribing, done, error
    }

    /// Growth past each side of the notch, in points.
    public static let wings: [Mode: Double] = [.recording: 64, .transcribing: 96, .done: 72, .error: 84]
    /// Seconds a result stays before the island closes.
    public static let holds: [Mode: Double] = [.done: 1.2, .error: 1.6]
    public static let widthSpring = (stiffness: 260.0, damping: 0.62)
    public static let heightSpring = (stiffness: 260.0, damping: 0.72)
    public static let fadeInRate = 12.0
    public static let fadeOutRate = 40.0
    public static let barCount = 5
    /// The empty middle of the pill on screens with no notch.
    public static let coreWithoutNotch = 16.0

    /// Where the island sits on one screen, in points.
    public struct Geometry: Sendable, Equatable {
        /// The width of the middle part: the notch, or `coreWithoutNotch`.
        public var core: Double
        /// The size when closed: the notch, or zero.
        public var restWidth: Double
        public var restHeight: Double
        /// The height when open.
        public var height: Double

        public init(core: Double, restWidth: Double, restHeight: Double, height: Double) {
            self.core = core
            self.restWidth = restWidth
            self.restHeight = restHeight
            self.height = height
        }

        public static func notch(width: Double, height: Double) -> Geometry {
            Geometry(core: width, restWidth: width, restHeight: height, height: height)
        }

        /// A pill that drops from the top center, below a menu bar of this height.
        public static func noNotch(menuBarHeight: Double) -> Geometry {
            let bar = menuBarHeight < 20 ? 24 : menuBarHeight // an auto-hidden menu bar reports 0
            return Geometry(core: IslandModel.coreWithoutNotch, restWidth: 0, restHeight: 0, height: bar + 6)
        }

        /// The widest the island gets, plus room for the overshoot.
        public var canvasWidth: Double { core + 2 * IslandModel.wings[.transcribing]! + 40 }
    }

    public struct Spring: Sendable, Equatable {
        public var x: Double
        public var v = 0.0

        public init(x: Double) { self.x = x }

        /// Semi-implicit Euler in steps of at most 8 ms, like hark.lua.
        public mutating func step(toward target: Double, dt: Double, stiffness: Double, damping zeta: Double) {
            let damping = 2 * zeta * stiffness.squareRoot()
            let steps = max(1, Int((dt / 0.008).rounded(.up)))
            let h = dt / Double(steps)
            for _ in 0..<steps {
                v += (stiffness * (target - x) - damping * v) * h
                x += v * h
            }
        }
    }

    public private(set) var geometry: Geometry
    public private(set) var mode = Mode.idle
    public private(set) var message = ""
    public private(set) var width: Spring
    public private(set) var height: Spring
    /// How visible each state's content is, 0…1.
    public private(set) var fades: [Mode: Double] = [.recording: 0, .transcribing: 0, .done: 0, .error: 0]
    public private(set) var level = 0.0
    public private(set) var bands = [Double](repeating: 0, count: IslandModel.barCount)
    public private(set) var elapsed = 0.0
    private var targetLevel = 0.0
    private var levelAt = -Double.infinity
    private var recordingStart = 0.0
    private var holdUntil: Double?

    public init(geometry: Geometry) {
        self.geometry = geometry
        width = Spring(x: geometry.restWidth)
        height = Spring(x: geometry.restHeight)
    }

    /// The width the spring is heading to now.
    public var targetWidth: Double {
        guard let wing = Self.wings[mode] else { return geometry.restWidth }
        return geometry.core + 2 * wing
    }

    public var targetHeight: Double {
        Self.wings[mode] == nil ? geometry.restHeight : geometry.height
    }

    /// Closed and still: the window can hide.
    public var isClosed: Bool {
        mode == .idle && abs(width.x - geometry.restWidth) < 0.5 && abs(width.v) < 2
            && abs(height.x - geometry.restHeight) < 0.5
    }

    /// How open the pill is: content shows only once there is room for it.
    public var openness: Double { clamp((width.x - geometry.restWidth) / 80) }

    /// The alpha for the content of one state.
    public func alpha(_ mode: Mode) -> Double {
        let any = fades.values.max() ?? 0
        return openness * clamp(any * 1.3 - 0.15) * (fades[mode] ?? 0)
    }

    /// Moves to another screen. The island starts closed there.
    public mutating func move(to geometry: Geometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        width = Spring(x: geometry.restWidth)
        height = Spring(x: geometry.restHeight)
    }

    public mutating func set(_ mode: Mode, message: String? = nil, now: Double) {
        if mode == .recording {
            recordingStart = now
            elapsed = 0
            targetLevel = 0
        }
        self.mode = mode
        if let message { self.message = message }
        holdUntil = Self.holds[mode].map { now + $0 }
    }

    /// A mic RMS level. Room noise is near −50 dB and close speech near −15 dB,
    /// so that range fills the bars.
    public mutating func setLevel(rms: Double, now: Double) {
        targetLevel = Self.level(rms: rms)
        levelAt = now
    }

    public static func level(rms: Double) -> Double {
        let db = 20 * log10(max(rms, 1e-6))
        return clamp((db + 50) / 35)
    }

    public mutating func step(now: Double, dt rawDt: Double) {
        let dt = min(0.05, max(0, rawDt))
        if let holdUntil, now >= holdUntil {
            mode = .idle
            self.holdUntil = nil
        }
        width.step(toward: targetWidth, dt: dt, stiffness: Self.widthSpring.stiffness, damping: Self.widthSpring.damping)
        height.step(toward: targetHeight, dt: dt, stiffness: Self.heightSpring.stiffness, damping: Self.heightSpring.damping)
        // The old state fades out faster than the new one fades in, so labels never overlap.
        let fadeIn = 1 - exp(-dt * Self.fadeInRate)
        let fadeOut = 1 - exp(-dt * Self.fadeOutRate)
        for key in fades.keys {
            let on = key == mode
            fades[key]! += ((on ? 1 : 0) - fades[key]!) * (on ? fadeIn : fadeOut)
        }
        if mode == .recording { elapsed = now - recordingStart }
        let target = mode == .recording && now - levelAt < 0.25 ? targetLevel : 0
        level += (target - level) * (1 - exp(-dt * 18))
        for i in bands.indices {
            let n = Double(i + 1)
            let wobble = abs(sin(now * (5.3 + n * 1.37) + n * 1.9) * cos(now * (2.1 + n * 0.71)))
            bands[i] += (level * (0.4 + 0.6 * wobble) - bands[i]) * (1 - exp(-dt * 20))
        }
    }

    /// The red dot's pulse, once a second, 0…1.
    public static func blink(now: Double) -> Double {
        0.5 + 0.5 * cos(now * 2 * .pi)
    }
}

extension IslandModel.Mode {
    public init(_ phase: DictationPhase) {
        switch phase {
        case .idle: self = .idle
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .done: self = .done
        case .error: self = .error
        }
    }
}

func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
