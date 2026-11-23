import AVFoundation
import XCTest
@testable import Playback

/// The sleep timer as the engine executes it: a deadline that pauses, or the end of the track
/// playing now (port of `SleepTimer` and the service's `watchSleepTimer` / "sleep after this song").
@MainActor
final class SleepTimerEngineTests: EngineTestCase {
    /// Android d4817fcc's SleepTimerTest: full volume until the last 30 s, then linear to silence.
    func testTheFadeVolumeIsLinearOverTheLastThirtySeconds() {
        XCTAssertEqual(SleepTimerState.fadeVolume(remaining: 60, enabled: true), 1)
        XCTAssertEqual(SleepTimerState.fadeVolume(remaining: 30, enabled: true), 1)
        XCTAssertEqual(SleepTimerState.fadeVolume(remaining: 15, enabled: true), 0.5, accuracy: 1e-6)
        XCTAssertEqual(SleepTimerState.fadeVolume(remaining: 3, enabled: true), 0.1, accuracy: 1e-6)
        XCTAssertEqual(SleepTimerState.fadeVolume(remaining: 0, enabled: true), 0)
        XCTAssertEqual(SleepTimerState.fadeVolume(remaining: -1, enabled: true), 0)
        XCTAssertEqual(SleepTimerState.fadeVolume(remaining: 5, enabled: false), 1, "off: no fade")
    }

    func testATimedSleepFadesTheDeckDownAndHandsItBackAtFullVolume() async throws {
        let item = try tone(8, name: "sleep-timed-fade")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        let deck = h.engine.activeDeckID

        h.engine.startSleepTimer(.duration(2))
        await waitUntil("quieter", timeout: 2) { h.engine.deck(deck).volume < 0.2 }
        await waitUntil("paused by the timer", timeout: 3) { !h.engine.playWhenReady }
        XCTAssertEqual(h.engine.deck(deck).volume, 1, "the deck is handed back at full volume for next time")
    }

    func testCancellingMidFadeRestoresTheVolume() async throws {
        let item = try tone(8, name: "sleep-fade-cancel")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        let deck = h.engine.activeDeckID

        h.engine.startSleepTimer(.duration(5))
        await waitUntil("quieter", timeout: 2) { h.engine.deck(deck).volume < 0.8 }
        h.engine.cancelSleepTimer()
        XCTAssertEqual(h.engine.deck(deck).volume, 1)
        XCTAssertTrue(h.engine.playWhenReady)
    }

    func testReplacingTheTimerMidFadeRestoresTheVolume() async throws {
        for replacement in [SleepTimerRequest.minutes(15), .endOfTrack] {
            let item = try tone(8, name: "sleep-fade-replace")
            let h = harness(queue: [item])
            h.engine.load(item, playWhenReady: true)
            await waitUntil("playing") { h.engine.isPlaying }
            let deck = h.engine.activeDeckID

            h.engine.startSleepTimer(.duration(5))
            await waitUntil("quieter", timeout: 2) { h.engine.deck(deck).volume < 0.8 }
            h.engine.startSleepTimer(replacement)
            XCTAssertEqual(h.engine.deck(deck).volume, 1, "replaced by \(replacement)")
            await pause(for: 0.3)
            XCTAssertEqual(h.engine.deck(deck).volume, 1, "the old fade is gone, replaced by \(replacement)")
            XCTAssertTrue(h.engine.playWhenReady)
            h.engine.cancelSleepTimer()
        }
    }

    func testABlendSeesNoSleepGainUnlessTheFadeIsDue() throws {
        let item = try tone(2, name: "sleep-gain")
        let h = harness(queue: [item])
        XCTAssertEqual(h.engine.sleepFadeGain, 1, "no timer")
        h.engine.startSleepTimer(.minutes(15))
        XCTAssertEqual(h.engine.sleepFadeGain, 1, "timer set, fade not yet due")
        h.engine.startSleepTimer(.endOfTrack)
        XCTAssertEqual(h.engine.sleepFadeGain, 1, "end of track has its own fade")
        h.engine.startSleepTimer(.duration(15))
        XCTAssertEqual(h.engine.sleepFadeGain, 0.5, accuracy: 0.05, "half way through the last 30 s")
        h.engine.sleepTimerFadeOut = false
        XCTAssertEqual(h.engine.sleepFadeGain, 1, "fade switched off")
        h.engine.cancelSleepTimer()
    }

    func testWithTheFadeOffTheVolumeStaysFull() async throws {
        let item = try tone(6, name: "sleep-no-fade")
        let h = harness(queue: [item])
        h.engine.sleepTimerFadeOut = false
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        let deck = h.engine.activeDeckID

        h.engine.startSleepTimer(.duration(1))
        await pause(for: 0.5)
        XCTAssertEqual(h.engine.deck(deck).volume, 1)
        await waitUntil("paused by the timer", timeout: 3) { !h.engine.playWhenReady }
    }

    func testTheTimerPausesAtItsDeadline() async throws {
        let item = try tone(6, name: "sleep-deadline")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.startSleepTimer(.duration(1.0))
        XCTAssertNotNil(h.engine.sleepTimer?.deadline)
        XCTAssertFalse(h.engine.sleepTimer?.afterTrack ?? true)
        let remaining = try XCTUnwrap(h.engine.sleepTimerRemaining)
        XCTAssertEqual(remaining, 1.0, accuracy: 0.1)

        await pause(for: 0.5)
        XCTAssertTrue(h.engine.isPlaying, "not before the deadline")
        await waitUntil("paused by the timer", timeout: 3) { !h.engine.playWhenReady }
        XCTAssertNil(h.engine.sleepTimer, "a timer that ran out is spent")
        XCTAssertNil(h.engine.sleepTimerRemaining)
        await waitUntil("stopped") { !h.engine.isPlaying }
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
    }

    func testSettingTheTimerAgainReplacesTheWait() async throws {
        let item = try tone(6, name: "sleep-reset")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.startSleepTimer(.duration(0.6))
        h.engine.startSleepTimer(.minutes(15))
        XCTAssertEqual(h.engine.sleepTimer?.presetMinutes, 15)
        XCTAssertEqual(h.engine.sleepTimerRemaining ?? 0, 900, accuracy: 1)
        await pause(for: 1.0)
        XCTAssertTrue(h.engine.playWhenReady, "the earlier, shorter wait was cancelled, not left to fire")

        h.engine.cancelSleepTimer()
        XCTAssertNil(h.engine.sleepTimer)
    }

    func testStoppingForgetsTheTimer() async throws {
        let item = try tone(6, name: "sleep-stop")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.startSleepTimer(.minutes(15))
        h.engine.stop()
        XCTAssertNil(h.engine.sleepTimer, "clearing the queue takes the timer with it")
        XCTAssertNil(h.engine.sleepTimerRemaining)
    }

    func testEndOfTrackPausesOnTheNextTrackWithoutPlayingIt() async throws {
        let first = try tone(1.2, frequency: 440, name: "sleep-eot-1")
        let second = try tone(3, frequency: 660, name: "sleep-eot-2")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        h.engine.startSleepTimer(.endOfTrack)
        XCTAssertEqual(h.engine.sleepTimer?.afterTrack, true)
        XCTAssertNil(h.engine.sleepTimerRemaining, "no deadline: it waits for the track to end")

        await waitUntil("moved on", timeout: 5) { h.engine.currentItem?.id == second.id }
        XCTAssertEqual(h.delegate.changes.last?.reason, .ended)
        XCTAssertFalse(h.engine.playWhenReady)
        XCTAssertNil(h.engine.sleepTimer)
        await pause(for: 0.5)
        XCTAssertFalse(h.engine.isPlaying, "the next track is cued, not heard")
        XCTAssertLessThan(h.engine.position, 0.3)
        XCTAssertEqual(h.processors[h.engine.activeDeckID]?.begunItems.map(\.id).contains(second.id), false)
    }

    func testEndOfTrackOnTheLastTrackStopsThere() async throws {
        let item = try tone(1, name: "sleep-eot-last")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        h.engine.startSleepTimer(.endOfTrack)
        await waitUntil("finished", timeout: 5) { h.engine.hasEnded }
        XCTAssertNil(h.engine.sleepTimer)
        XCTAssertFalse(h.engine.playWhenReady)
    }

    func testEndOfTrackWithCrossfadeFadesTheTrackOutAndPauses() async throws {
        // With a crossfade set there is still no next track to fade into: the track fades to
        // silence over the crossfade span and playback pauses.
        let first = try tone(3, frequency: 440, name: "sleep-fade-1")
        let second = try tone(3, frequency: 660, name: "sleep-fade-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 1
        h.engine.load(first, playWhenReady: true)
        h.engine.startSleepTimer(.endOfTrack)
        let deck = h.engine.activeDeckID

        await waitUntil("fading out", timeout: 5) { h.engine.crossfade.phase == .sleepFade }
        XCTAssertTrue(h.engine.isTransitioning)
        await waitUntil("quieter", timeout: 2) { h.engine.deck(deck).volume < 0.7 }
        await waitUntil("paused", timeout: 3) { !h.engine.playWhenReady }
        XCTAssertNil(h.engine.sleepTimer)
        XCTAssertEqual(h.engine.deck(deck).volume, 1, "the deck is handed back at full volume for next time")
        XCTAssertNil(h.engine.deck(deck == .a ? .b : .a).current, "no second deck was armed")
        XCTAssertFalse(h.delegate.changes.contains { $0.item.id == second.id && $0.reason == .crossfade })
    }
}
