import CoreGraphics
import Foundation

enum QuitShortcut {
  static let relevantModifiers: CGEventFlags = [
    .maskCommand,
    .maskShift,
    .maskControl,
    .maskAlternate,
  ]

  static func isPlainCommand(_ flags: CGEventFlags) -> Bool {
    flags.intersection(relevantModifiers) == .maskCommand
  }

  static func representsLogicalQ(_ event: CGEvent) -> Bool {
    var characters = [UniChar](repeating: 0, count: 4)
    var actualLength = 0

    characters.withUnsafeMutableBufferPointer { buffer in
      event.keyboardGetUnicodeString(
        maxStringLength: buffer.count,
        actualStringLength: &actualLength,
        unicodeString: buffer.baseAddress!
      )
    }

    guard actualLength > 0 else { return false }
    let text = String(
      utf16CodeUnits: characters,
      count: min(actualLength, characters.count)
    )
    return text.lowercased(with: Locale(identifier: "en_US_POSIX")) == "q"
  }
}

struct HoldToQuitStateMachine {
  struct Session: Equatable {
    let generation: UInt64
    let targetPID: Int32
    let duration: TimeInterval
  }

  enum Phase: Equatable {
    case idle
    case holding(Session)
    case suppressingUntilQUp
  }

  enum Input: Equatable {
    case plainCommandQDown(targetPID: Int32, duration: TimeInterval)
    case qDown
    case qUp
    case modifiersChanged(plainCommandIsHeld: Bool, qIsDown: Bool)
    case deadline(
      generation: UInt64,
      targetIsStillActive: Bool,
      chordIsStillHeld: Bool,
      qIsDown: Bool
    )
    case interrupted(qIsDown: Bool)
  }

  enum Effect: Equatable {
    case showOverlay(Session)
    case hideOverlay(generation: UInt64)
    case scheduleDeadline(Session)
    case cancelDeadline
    case replayCommandQ(targetPID: Int32)
  }

  struct Transition: Equatable {
    let suppressEvent: Bool
    let effects: [Effect]
  }

  private(set) var phase: Phase = .idle
  private var nextGeneration: UInt64 = 0

  mutating func handle(_ input: Input) -> Transition {
    switch input {
    case .plainCommandQDown(let targetPID, let duration):
      switch phase {
      case .idle:
        guard targetPID > 0 else {
          return Transition(suppressEvent: false, effects: [])
        }

        nextGeneration &+= 1
        let session = Session(
          generation: nextGeneration,
          targetPID: targetPID,
          duration: duration
        )
        phase = .holding(session)
        return Transition(
          suppressEvent: true,
          effects: [.showOverlay(session), .scheduleDeadline(session)]
        )

      case .holding, .suppressingUntilQUp:
        return Transition(suppressEvent: true, effects: [])
      }

    case .qDown:
      switch phase {
      case .idle:
        phase = .suppressingUntilQUp
        return Transition(suppressEvent: true, effects: [])
      case .holding, .suppressingUntilQUp:
        return Transition(suppressEvent: true, effects: [])
      }

    case .qUp:
      switch phase {
      case .idle:
        return Transition(suppressEvent: false, effects: [])

      case .holding(let session):
        phase = .idle
        return Transition(
          suppressEvent: true,
          effects: [.cancelDeadline, .hideOverlay(generation: session.generation)]
        )

      case .suppressingUntilQUp:
        phase = .idle
        return Transition(suppressEvent: true, effects: [.cancelDeadline])
      }

    case .modifiersChanged(let plainCommandIsHeld, let qIsDown):
      guard case .holding(let session) = phase, !plainCommandIsHeld else {
        return Transition(suppressEvent: false, effects: [])
      }

      phase = qIsDown ? .suppressingUntilQUp : .idle
      return Transition(
        suppressEvent: false,
        effects: [.cancelDeadline, .hideOverlay(generation: session.generation)]
      )

    case .deadline(let generation, let targetIsStillActive, let chordIsStillHeld, let qIsDown):
      guard case .holding(let session) = phase,
        session.generation == generation
      else {
        return Transition(suppressEvent: false, effects: [])
      }

      let shouldReplay = targetIsStillActive && chordIsStillHeld && qIsDown
      phase = qIsDown ? .suppressingUntilQUp : .idle

      var effects: [Effect] = [
        .cancelDeadline,
        .hideOverlay(generation: session.generation),
      ]
      if shouldReplay {
        effects.append(.replayCommandQ(targetPID: session.targetPID))
      }

      return Transition(suppressEvent: false, effects: effects)

    case .interrupted(let qIsDown):
      switch phase {
      case .idle:
        return Transition(suppressEvent: false, effects: [.cancelDeadline])

      case .holding(let session):
        phase = qIsDown ? .suppressingUntilQUp : .idle
        return Transition(
          suppressEvent: false,
          effects: [.cancelDeadline, .hideOverlay(generation: session.generation)]
        )

      case .suppressingUntilQUp:
        phase = qIsDown ? .suppressingUntilQUp : .idle
        return Transition(suppressEvent: false, effects: [.cancelDeadline])
      }
    }
  }
}
