import Testing
@testable import HarkCore

@Suite struct IslandModelTests {
    let notch = IslandModel.Geometry.notch(width: 200, height: 32)

    /// Steps at 60 Hz for `seconds`, calling `each` after every step.
    func run(_ model: inout IslandModel, from start: Double = 0, for seconds: Double,
             _ each: (IslandModel, Double) -> Void = { _, _ in }) {
        var t = start
        while t < start + seconds {
            t += 1.0 / 60
            model.step(now: t, dt: 1.0 / 60)
            each(model, t)
        }
    }

    @Test func eachStateHasItsWidth() {
        var model = IslandModel(geometry: notch)
        #expect(model.targetWidth == 200)
        for (mode, wing) in [(IslandModel.Mode.recording, 64.0), (.transcribing, 96), (.done, 72), (.error, 84)] {
            model.set(mode, now: 0)
            #expect(model.targetWidth == 200 + 2 * wing)
            #expect(model.targetHeight == 32)
        }
    }

    @Test func screensWithNoNotchGetAPillBelowTheMenuBar() {
        let pill = IslandModel.Geometry.noNotch(menuBarHeight: 24)
        var model = IslandModel(geometry: pill)
        #expect(model.targetWidth == 0)
        model.set(.recording, now: 0)
        #expect(model.targetWidth == 16 + 128)
        #expect(model.targetHeight == 30)
        // An auto-hidden menu bar reports no height.
        #expect(IslandModel.Geometry.noNotch(menuBarHeight: 0).height == 30)
    }

    @Test func theSpringSettlesWithASmallOvershoot() {
        var model = IslandModel(geometry: notch)
        model.set(.recording, now: 0)
        var peak = 0.0
        run(&model, for: 2) { model, _ in peak = max(peak, model.width.x) }
        let target = 200.0 + 128
        #expect(abs(model.width.x - target) < 0.5)
        // Damping 0.62 overshoots by about 8 % of the 128 pt step.
        let overshoot = (peak - target) / 128
        #expect(overshoot > 0.05 && overshoot < 0.12)
    }

    @Test func theOldStateFadesOutBeforeTheNewOneIsIn() {
        var model = IslandModel(geometry: notch)
        model.set(.recording, now: 0)
        run(&model, for: 1)
        model.set(.transcribing, now: 1)
        var checked = false
        run(&model, from: 1, for: 1) { model, _ in
            if !checked && model.fades[.transcribing]! >= 0.9 {
                #expect(model.fades[.recording]! < 0.01)
                checked = true
            }
        }
        #expect(checked)
        #expect(model.fades[.transcribing]! > 0.99)
    }

    @Test func resultsHoldThenTheIslandCloses() {
        var model = IslandModel(geometry: notch)
        model.set(.recording, now: 0)
        run(&model, for: 1)
        model.set(.done, now: 1)
        run(&model, from: 1, for: 1.1)
        #expect(model.mode == .done)
        run(&model, from: 2.1, for: 0.2)
        #expect(model.mode == .idle)
        run(&model, from: 2.3, for: 2)
        #expect(model.isClosed)

        model.set(.error, message: "No speech", now: 10)
        run(&model, from: 10, for: 1.5)
        #expect(model.mode == .error)
        #expect(model.message == "No speech")
        run(&model, from: 11.5, for: 0.2)
        #expect(model.mode == .idle)
    }

    @Test func levelsMapFromMinusFiftyToMinusFifteenDecibels() {
        #expect(IslandModel.level(rms: 0.003) == 0) // −50 dB
        #expect(abs(IslandModel.level(rms: 0.1778) - 1) < 0.001) // −15 dB
        #expect(abs(IslandModel.level(rms: 0.0316) - 0.571) < 0.01) // −30 dB
        #expect(IslandModel.level(rms: 1) == 1)
        #expect(IslandModel.level(rms: 0) == 0)
    }

    @Test func barsFollowTheLevelOnlyWhileRecording() {
        var model = IslandModel(geometry: notch)
        model.set(.recording, now: 0)
        var t = 0.0
        for _ in 0..<30 {
            t += 1.0 / 60
            model.setLevel(rms: 0.1, now: t)
            model.step(now: t, dt: 1.0 / 60)
        }
        #expect(model.level > 0.5)
        #expect(model.bands.allSatisfy { $0 > 0.1 })
        // Levels older than 0.25 s fall back to silence.
        run(&model, from: t, for: 1)
        #expect(model.level < 0.01)
    }

    @Test func theTimerCountsFromTheStartOfRecording() {
        var model = IslandModel(geometry: notch)
        model.set(.recording, now: 5)
        run(&model, from: 5, for: 3)
        #expect(abs(model.elapsed - 3) < 0.05)
    }

    @Test func theDotPulsesOnceASecond() {
        #expect(IslandModel.blink(now: 0) == 1)
        #expect(abs(IslandModel.blink(now: 0.5)) < 1e-9)
        #expect(abs(IslandModel.blink(now: 1) - 1) < 1e-9)
    }
}
