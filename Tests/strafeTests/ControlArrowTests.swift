import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import strafe

final class ControlArrowTests: XCTestCase {
    private final class Engine: SwitchEngine {
        var directions: [SwitchDirection] = []
        var error: SwitchEngineError?
        func switchSpace(_ direction: SwitchDirection) throws {
            if let error { throw error }
            directions.append(direction)
        }
    }

    private func key(_ code: Int = kVK_LeftArrow, down: Bool = true,
                     flags: CGEventFlags = .maskControl, repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    func testBothDirectionsConsumeDownAndMatchingUp() {
        let engine = Engine()
        let tap = ControlArrowInterceptor(engine: engine, canSwitch: { true }, isExposeActive: { false })
        for code in [kVK_LeftArrow, kVK_RightArrow] {
            XCTAssertTrue(tap.handle(type: .keyDown, event: key(code)) == nil)
            // Release Control before the arrow: the consumed arrow's up must still be swallowed.
            XCTAssertTrue(tap.handle(type: .keyUp, event: key(code, down: false, flags: [])) == nil)
        }
        XCTAssertEqual(engine.directions.count, 2)
        XCTAssertTrue(engine.directions[0] == .left && engine.directions[1] == .right)
    }

    func testUnrelatedTypingAndOtherModifiersPassUnchanged() {
        let engine = Engine()
        let tap = ControlArrowInterceptor(engine: engine, canSwitch: { true }, isExposeActive: { false })
        for flags: CGEventFlags in [[], .maskShift, .maskCommand, .maskAlternate,
                                   [.maskControl, .maskShift], [.maskControl, .maskAlternate],
                                   [.maskControl, .maskCommand]] {
            for type: CGEventType in [.keyDown, .keyUp] {
                let event = key(down: type == .keyDown, flags: flags)
                XCTAssertTrue(tap.handle(type: type, event: event)?.takeUnretainedValue() === event)
            }
        }
        for code in [kVK_ANSI_A, kVK_Return, kVK_UpArrow, kVK_DownArrow] {
            let event = key(code)
            XCTAssertTrue(tap.handle(type: .keyDown, event: event)?.takeUnretainedValue() === event)
        }
        XCTAssertTrue(engine.directions.isEmpty)
    }

    func testHardwareArrowAndCapsLockFlagsDoNotBlockControl() {
        let engine = Engine()
        let tap = ControlArrowInterceptor(engine: engine, canSwitch: { true }, isExposeActive: { false })
        XCTAssertTrue(tap.handle(type: .keyDown, event: key(flags:
            [.maskControl, .maskAlphaShift, .maskNumericPad, .maskSecondaryFn])) == nil)
        XCTAssertEqual(engine.directions.count, 1)
    }

    func testRepeatedArrowIsBoundedAndNeverAcquiredMidHold() {
        let engine = Engine()
        var time = 0.0
        let tap = ControlArrowInterceptor(engine: engine, canSwitch: { true },
                                         isExposeActive: { false }, now: { time })
        let unownedRepeat = key(repeatKey: true)
        XCTAssertFalse(tap.handle(type: .keyDown, event: unownedRepeat) == nil)
        XCTAssertTrue(engine.directions.isEmpty)
        XCTAssertTrue(tap.handle(type: .keyDown, event: key()) == nil)
        time = 0.1
        XCTAssertTrue(tap.handle(type: .keyDown, event: key(repeatKey: true)) == nil)
        XCTAssertEqual(engine.directions.count, 1)
        time = 0.2
        XCTAssertTrue(tap.handle(type: .keyDown, event: key(repeatKey: true)) == nil)
        XCTAssertEqual(engine.directions.count, 2)
        time = 0.4
        XCTAssertTrue(tap.handle(type: .keyDown, event: key(flags: [.maskControl, .maskShift], repeatKey: true)) == nil)
        XCTAssertEqual(engine.directions.count, 2)
        XCTAssertTrue(tap.handle(type: .keyUp, event: key(down: false)) == nil)
        XCTAssertFalse(tap.handle(type: .keyDown, event: unownedRepeat) == nil)
    }

    func testUnavailablePermissionAndOverlayLeaveNativeShortcutIntact() {
        for (permission, overlay) in [(false, false), (true, true)] {
            let engine = Engine()
            let tap = ControlArrowInterceptor(engine: engine, canSwitch: { permission }, isExposeActive: { overlay })
            let event = key()
            XCTAssertTrue(tap.handle(type: .keyDown, event: event)?.takeUnretainedValue() === event)
            XCTAssertFalse(tap.handle(type: .keyUp, event: key(down: false)) == nil)
            XCTAssertTrue(engine.directions.isEmpty)
        }
    }

    func testInitialPostFailureFallsBackButBoundaryIsConsumed() {
        let engine = Engine()
        let tap = ControlArrowInterceptor(engine: engine, canSwitch: { true }, isExposeActive: { false })
        engine.error = .postFailed
        XCTAssertFalse(tap.handle(type: .keyDown, event: key()) == nil)
        XCTAssertFalse(tap.handle(type: .keyUp, event: key(down: false)) == nil)
        engine.error = .atEdge
        XCTAssertTrue(tap.handle(type: .keyDown, event: key()) == nil)
        XCTAssertTrue(tap.handle(type: .keyUp, event: key(down: false)) == nil)
    }

    func testTimeoutAndStopClearCapturedKeys() {
        let engine = Engine()
        let tap = ControlArrowInterceptor(engine: engine, canSwitch: { true }, isExposeActive: { false })
        for type: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
            XCTAssertTrue(tap.handle(type: .keyDown, event: key()) == nil)
            XCTAssertFalse(tap.handle(type: type, event: key()) == nil)
            XCTAssertFalse(tap.handle(type: .keyUp, event: key(down: false)) == nil)
        }
        XCTAssertTrue(tap.handle(type: .keyDown, event: key()) == nil)
        tap.stop()
        XCTAssertFalse(tap.handle(type: .keyUp, event: key(down: false)) == nil)
        XCTAssertFalse(tap.isRunning)
    }
}
