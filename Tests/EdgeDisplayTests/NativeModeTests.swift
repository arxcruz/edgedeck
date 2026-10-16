import Testing
@testable import EdgeDisplay

struct NativeModeTests {
    private func mode(_ w: Int, _ h: Int, hz: Double = 60, scale: Int = 1, usable: Bool = true) -> DisplayModeInfo {
        DisplayModeInfo(width: w, height: h, pixelWidth: w * scale, pixelHeight: h * scale, refresh: hz, usable: usable)
    }

    @Test func picksTheNativeModeOverOtherSizes() {
        let modes = [mode(1920, 1080), mode(2560, 720), mode(1280, 360)]
        #expect(NativeMode.pick(from: modes) == 1)
    }

    @Test func prefersTheHighestRefreshRate() {
        let modes = [mode(2560, 720, hz: 60), mode(2560, 720, hz: 120), mode(2560, 720, hz: 30)]
        #expect(NativeMode.pick(from: modes) == 1)
    }

    @Test func skipsHiDPIAndUnusableModes() {
        let modes = [mode(2560, 720, hz: 120, scale: 2), mode(2560, 720, hz: 90, usable: false), mode(2560, 720, hz: 60)]
        #expect(NativeMode.pick(from: modes) == 2)
    }

    @Test func nothingWhenTheEdgeOffersNoNativeMode() {
        #expect(NativeMode.pick(from: [mode(1920, 1080), mode(1280, 720)]) == nil)
    }

    @Test func nativeIsRecognisedByItsSizeAlone() {
        #expect(NativeMode.isNative(mode(2560, 720, hz: 30)))
        #expect(!NativeMode.isNative(mode(1920, 1080)))
        #expect(!NativeMode.isNative(mode(2560, 720, scale: 2)))
    }
}

struct FixAttemptsTests {
    private func tries(_ attempts: inout FixAttempts, _ n: Int) -> [Bool] {
        (0..<n).map { _ in attempts.shouldTry(isNative: false) }
    }

    @Test func triesThreeTimesThenStops() {
        var attempts = FixAttempts()
        #expect(tries(&attempts, 4) == [true, true, true, false])
    }

    @Test func nothingToTryWhenAlreadyNativeAndTheBudgetRefills() {
        var attempts = FixAttempts()
        _ = tries(&attempts, 2)
        let whenNative = attempts.shouldTry(isNative: true)
        #expect(!whenNative)
        #expect(tries(&attempts, 3) == [true, true, true])
    }

    @Test func aManualRetryStartsAgain() {
        var attempts = FixAttempts()
        _ = tries(&attempts, 4)
        attempts.reset()
        #expect(tries(&attempts, 1) == [true])
    }
}
