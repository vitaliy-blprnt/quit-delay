import CoreGraphics
import XCTest

@testable import QuitDelay

final class HoldToQuitStateMachineTests: XCTestCase {
  func testShortQReleaseCancelsWithoutQuitting() throws {
    var machine = HoldToQuitStateMachine()
    let started = machine.handle(.plainCommandQDown(targetPID: 42, duration: 1.5))
    let session = try XCTUnwrap(session(from: started))

    XCTAssertTrue(started.suppressEvent)
    XCTAssertEqual(machine.phase, .holding(session))

    let released = machine.handle(.qUp)

    XCTAssertTrue(released.suppressEvent)
    XCTAssertEqual(
      released.effects,
      [.cancelDeadline, .hideOverlay(generation: session.generation)]
    )
    XCTAssertEqual(machine.phase, .idle)
    XCTAssertFalse(released.effects.contains(.replayCommandQ(targetPID: 42)))
  }

  func testCommandReleaseCancelsAndDrainsUntilQUp() throws {
    var machine = HoldToQuitStateMachine()
    let session = try XCTUnwrap(
      session(
        from: machine.handle(
          .plainCommandQDown(targetPID: 42, duration: 1.5)
        )))

    let commandReleased = machine.handle(
      .modifiersChanged(plainCommandIsHeld: false, qIsDown: true)
    )

    XCTAssertFalse(commandReleased.suppressEvent)
    XCTAssertEqual(machine.phase, .suppressingUntilQUp)
    XCTAssertEqual(
      commandReleased.effects,
      [.cancelDeadline, .hideOverlay(generation: session.generation)]
    )
    XCTAssertTrue(machine.handle(.qDown).suppressEvent)
    XCTAssertTrue(machine.handle(.qUp).suppressEvent)
    XCTAssertEqual(machine.phase, .idle)
  }

  func testDeadlineReplaysExactlyOnce() throws {
    var machine = HoldToQuitStateMachine()
    let session = try XCTUnwrap(
      session(
        from: machine.handle(
          .plainCommandQDown(targetPID: 42, duration: 1.5)
        )))

    let deadline = machine.handle(
      .deadline(
        generation: session.generation,
        targetIsStillActive: true,
        chordIsStillHeld: true,
        qIsDown: true
      )
    )

    XCTAssertEqual(
      deadline.effects.filter { $0 == .replayCommandQ(targetPID: 42) }.count,
      1
    )
    XCTAssertEqual(machine.phase, .suppressingUntilQUp)

    let repeatedDeadline = machine.handle(
      .deadline(
        generation: session.generation,
        targetIsStillActive: true,
        chordIsStillHeld: true,
        qIsDown: true
      )
    )
    XCTAssertFalse(repeatedDeadline.effects.contains(.replayCommandQ(targetPID: 42)))
  }

  func testStaleDeadlineCannotQuitNewSession() throws {
    var machine = HoldToQuitStateMachine()
    let first = try XCTUnwrap(
      session(
        from: machine.handle(
          .plainCommandQDown(targetPID: 10, duration: 1)
        )))
    _ = machine.handle(.qUp)
    let second = try XCTUnwrap(
      session(
        from: machine.handle(
          .plainCommandQDown(targetPID: 20, duration: 1)
        )))

    let stale = machine.handle(
      .deadline(
        generation: first.generation,
        targetIsStillActive: true,
        chordIsStillHeld: true,
        qIsDown: true
      )
    )

    XCTAssertTrue(stale.effects.isEmpty)
    XCTAssertEqual(machine.phase, .holding(second))
  }

  func testFocusChangeAtDeadlineCancels() throws {
    var machine = HoldToQuitStateMachine()
    let session = try XCTUnwrap(
      session(
        from: machine.handle(
          .plainCommandQDown(targetPID: 42, duration: 1.5)
        )))

    let deadline = machine.handle(
      .deadline(
        generation: session.generation,
        targetIsStillActive: false,
        chordIsStillHeld: true,
        qIsDown: true
      )
    )

    XCTAssertFalse(deadline.effects.contains(.replayCommandQ(targetPID: 42)))
    XCTAssertEqual(machine.phase, .suppressingUntilQUp)
  }

  func testPhysicalReleaseWinsDeadlineRace() throws {
    var machine = HoldToQuitStateMachine()
    let session = try XCTUnwrap(
      session(
        from: machine.handle(
          .plainCommandQDown(targetPID: 42, duration: 1.5)
        )))

    let deadline = machine.handle(
      .deadline(
        generation: session.generation,
        targetIsStillActive: true,
        chordIsStillHeld: false,
        qIsDown: false
      )
    )

    XCTAssertFalse(deadline.effects.contains(.replayCommandQ(targetPID: 42)))
    XCTAssertEqual(machine.phase, .idle)
  }

  func testAutorepeatDoesNotRestartHold() throws {
    var machine = HoldToQuitStateMachine()
    let first = try XCTUnwrap(
      session(
        from: machine.handle(
          .plainCommandQDown(targetPID: 42, duration: 1.5)
        )))

    let repeatEvent = machine.handle(.qDown)

    XCTAssertTrue(repeatEvent.suppressEvent)
    XCTAssertTrue(repeatEvent.effects.isEmpty)
    XCTAssertEqual(machine.phase, .holding(first))
  }

  func testOrphanedAutorepeatIsSuppressedUntilQUp() {
    var machine = HoldToQuitStateMachine()

    let repeatEvent = machine.handle(.qDown)

    XCTAssertTrue(repeatEvent.suppressEvent)
    XCTAssertEqual(machine.phase, .suppressingUntilQUp)
    XCTAssertTrue(machine.handle(.qUp).suppressEvent)
    XCTAssertEqual(machine.phase, .idle)
  }

  func testInterruptionWhileQIsDownDrainsUntilRelease() throws {
    var machine = HoldToQuitStateMachine()
    let session = try XCTUnwrap(
      session(
        from: machine.handle(.plainCommandQDown(targetPID: 42, duration: 1.5))
      )
    )

    let interrupted = machine.handle(.interrupted(qIsDown: true))

    XCTAssertEqual(machine.phase, .suppressingUntilQUp)
    XCTAssertEqual(
      interrupted.effects,
      [.cancelDeadline, .hideOverlay(generation: session.generation)]
    )
    XCTAssertTrue(machine.handle(.qDown).suppressEvent)
    XCTAssertTrue(machine.handle(.qUp).suppressEvent)
    XCTAssertEqual(machine.phase, .idle)
  }

  func testOnlyPlainCommandModifierIsAccepted() {
    XCTAssertTrue(QuitShortcut.isPlainCommand([.maskCommand]))
    XCTAssertTrue(QuitShortcut.isPlainCommand([.maskCommand, .maskAlphaShift]))
    XCTAssertFalse(QuitShortcut.isPlainCommand([.maskCommand, .maskControl]))
    XCTAssertFalse(QuitShortcut.isPlainCommand([.maskCommand, .maskShift]))
    XCTAssertFalse(QuitShortcut.isPlainCommand([.maskCommand, .maskAlternate]))
    XCTAssertFalse(QuitShortcut.isPlainCommand([]))
  }

  func testLogicalQClassifierUsesEventCharactersInsteadOfPhysicalKey() throws {
    let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
    let event = try XCTUnwrap(
      CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    )
    var q = Array("Q".utf16)
    q.withUnsafeMutableBufferPointer {
      event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
    }

    XCTAssertTrue(QuitShortcut.representsLogicalQ(event))

    var w = Array("w".utf16)
    w.withUnsafeMutableBufferPointer {
      event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
    }
    XCTAssertFalse(QuitShortcut.representsLogicalQ(event))
  }

  private func session(
    from transition: HoldToQuitStateMachine.Transition
  ) -> HoldToQuitStateMachine.Session? {
    for effect in transition.effects {
      if case .showOverlay(let session) = effect {
        return session
      }
    }
    return nil
  }
}

final class DisplayGeometryTests: XCTestCase {
  private let displays = [
    DisplayGeometry.Display(
      id: 1,
      bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    ),
    DisplayGeometry.Display(
      id: 2,
      bounds: CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    ),
    DisplayGeometry.Display(
      id: 3,
      bounds: CGRect(x: -1280, y: 120, width: 1280, height: 1024)
    ),
  ]

  func testWindowOnSecondaryDisplaySelectsSecondaryDisplay() {
    let window = CGRect(x: 2200, y: 180, width: 900, height: 700)

    XCTAssertEqual(DisplayGeometry.displayID(forWindow: window, displays: displays), 2)
  }

  func testWindowOnNegativeOriginDisplaySelectsThatDisplay() {
    let window = CGRect(x: -1100, y: 250, width: 800, height: 600)

    XCTAssertEqual(DisplayGeometry.displayID(forWindow: window, displays: displays), 3)
  }

  func testSpanningWindowUsesDisplayWithLargestOverlap() {
    let window = CGRect(x: 1700, y: 100, width: 1200, height: 800)

    XCTAssertEqual(DisplayGeometry.displayID(forWindow: window, displays: displays), 2)
  }

  func testWindowOutsideAllDisplaysReturnsNil() {
    let window = CGRect(x: 8_000, y: 8_000, width: 500, height: 500)

    XCTAssertNil(DisplayGeometry.displayID(forWindow: window, displays: displays))
  }

  func testEqualOverlapUsesStableDisplayIDTieBreak() {
    let window = CGRect(x: 1_420, y: 100, width: 1_000, height: 600)

    XCTAssertEqual(DisplayGeometry.displayID(forWindow: window, displays: displays), 1)
  }
}

final class AppSettingsTests: XCTestCase {
  func testOutOfRangeAssignmentIsClampedPersistedAndSnapshotted() throws {
    let suiteName = "QuitDelayTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)

    settings.holdDuration = 99

    XCTAssertEqual(settings.holdDuration, AppSettings.holdDurationRange.upperBound)
    XCTAssertEqual(
      settings.snapshotHoldDuration(),
      AppSettings.holdDurationRange.upperBound
    )
    XCTAssertEqual(
      defaults.double(forKey: "holdDuration"),
      AppSettings.holdDurationRange.upperBound
    )
  }

  func testNonFiniteStoredDurationUsesDefault() throws {
    let suiteName = "QuitDelayTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Double.nan, forKey: "holdDuration")

    let settings = AppSettings(defaults: defaults)

    XCTAssertEqual(settings.holdDuration, AppSettings.defaultHoldDuration)
    XCTAssertEqual(settings.snapshotHoldDuration(), AppSettings.defaultHoldDuration)
  }
}
