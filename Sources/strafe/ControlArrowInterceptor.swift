import Carbon.HIToolbox
import CoreGraphics
import Foundation
import CStrafe

/// Optional, active keyboard tap. Main-run-loop confined, like SwipeInterceptor.
/// It receives key-down/up events but only consumes Control+Left/Right. It never
/// reads text, logs keys, or retains unrelated events. Native shortcuts stay on.
final class ControlArrowInterceptor: @unchecked Sendable {
    private let engine: SwitchEngine
    private let canSwitch: () -> Bool
    private let isExposeActive: () -> Bool
    private let now: () -> TimeInterval
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captured: UInt8 = 0
    private var lastSwitch: TimeInterval = -.infinity

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init(engine: SwitchEngine,
         canSwitch: @escaping () -> Bool = { Permissions.isAccessibilityGranted },
         isExposeActive: @escaping () -> Bool = { strafe_is_expose_active() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine
        self.canSwitch = canSwitch
        self.isExposeActive = isExposeActive
        self.now = now
    }

    func start() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ControlArrowInterceptor>.fromOpaque(context)
                    .takeUnretainedValue().handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            FileHandle.standardError.write(Data(
                "[ControlArrowInterceptor] Cannot create keyboard tap; native shortcuts remain available. Check Accessibility.\n".utf8))
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        reset()
    }

    private func reset() {
        captured = 0
        lastSwitch = -.infinity
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return passthrough
        }
        guard type == .keyDown || type == .keyUp else { return passthrough }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let bit: UInt8
        let direction: SwitchDirection
        switch key {
        case Int64(kVK_LeftArrow): bit = 1; direction = .left
        case Int64(kVK_RightArrow): bit = 2; direction = .right
        default: return passthrough
        }
        if type == .keyUp {
            guard captured & bit != 0 else { return passthrough }
            captured &= ~bit
            return nil // Match a consumed down even if Control was released first.
        }
        // Ignore Caps Lock and hardware arrow flags, but never take over
        // Command/Option/Shift combinations, including existing Carbon hotkeys.
        let modifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        let controlOnly = event.flags.intersection(modifiers) == .maskControl
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if captured & bit != 0 {
            // Keep the whole captured key sequence out of the native handler.
            // Bound repeats so an 80–110ms ramp cannot build an unbounded queue.
            if repeating && controlOnly && canSwitch() && !isExposeActive() {
                let time = now()
                if time - lastSwitch >= 0.15 {
                    _ = fire(direction)
                    lastSwitch = time
                }
            }
            return nil
        }
        // Never acquire a key mid-hold: its original down may have reached an app.
        guard !repeating, controlOnly, canSwitch(), !isExposeActive() else { return passthrough }
        guard fire(direction) else { return passthrough }
        captured |= bit
        lastSwitch = now()
        return nil
    }

    private func fire(_ direction: SwitchDirection) -> Bool {
        do {
            try engine.switchSpace(direction)
            return true
        } catch SwitchEngineError.atEdge {
            return true // Consume at the edge to avoid native bounce/double handling.
        } catch {
            return false // Initial failure leaves the original shortcut to macOS.
        }
    }
}
