import AppKit
import CoreGraphics
import OSLog

final class QuitInterceptionController {
  private let settings: AppSettings
  private let overlayController: HoldOverlayController
  private let operationalFailureHandler: (String) -> Void
  private let lifecycleLock = NSLock()
  private var worker: EventTapWorker?
  private var desiredRunning = false
  private var restartWhenStopped = false

  init(
    settings: AppSettings,
    overlayController: HoldOverlayController,
    operationalFailureHandler: @escaping (String) -> Void
  ) {
    self.settings = settings
    self.overlayController = overlayController
    self.operationalFailureHandler = operationalFailureHandler
  }

  func startIfNeeded() {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    let wasDesiredRunning = desiredRunning
    desiredRunning = true
    guard worker == nil else {
      if !wasDesiredRunning {
        restartWhenStopped = true
      }
      return
    }

    let worker = EventTapWorker(
      durationProvider: { [weak settings] in
        settings?.snapshotHoldDuration() ?? AppSettings.defaultHoldDuration
      },
      showOverlay: { [weak overlayController] session, deadlineUptime in
        DispatchQueue.main.async {
          overlayController?.show(
            targetPID: session.targetPID,
            generation: session.generation,
            duration: session.duration,
            deadlineUptime: deadlineUptime
          )
        }
      },
      hideOverlay: { [weak overlayController] generation in
        DispatchQueue.main.async {
          overlayController?.hide(generation: generation)
        }
      },
      operationalFailure: { [operationalFailureHandler] message in
        DispatchQueue.main.async {
          operationalFailureHandler(message)
        }
      },
      didStop: { [weak self] workerID in
        DispatchQueue.main.async {
          self?.removeWorker(withID: workerID)
        }
      }
    )
    self.worker = worker
    worker.start()
  }

  func stop() {
    lifecycleLock.lock()
    let currentWorker = worker
    desiredRunning = false
    restartWhenStopped = false
    lifecycleLock.unlock()
    currentWorker?.stop()
  }

  func restart() {
    lifecycleLock.lock()
    desiredRunning = true
    let currentWorker = worker
    restartWhenStopped = currentWorker != nil
    lifecycleLock.unlock()

    if let currentWorker {
      currentWorker.stop()
    } else {
      startIfNeeded()
    }
  }

  func cancelCurrentHold() {
    lifecycleLock.lock()
    let currentWorker = worker
    lifecycleLock.unlock()
    currentWorker?.cancelCurrentHold()
  }

  private func removeWorker(withID workerID: UUID) {
    lifecycleLock.lock()
    var shouldRestart = false
    if worker?.id == workerID {
      worker = nil
      shouldRestart = desiredRunning && restartWhenStopped
      restartWhenStopped = false
    }
    lifecycleLock.unlock()

    if shouldRestart {
      startIfNeeded()
    }
  }
}

private final class EventTapWorker {
  typealias Session = HoldToQuitStateMachine.Session

  private static let logger = Logger(
    subsystem: "com.supagoku.QuitDelay",
    category: "Interception"
  )

  let id = UUID()

  private let durationProvider: () -> TimeInterval
  private let showOverlay: (Session, TimeInterval) -> Void
  private let hideOverlay: (UInt64) -> Void
  private let operationalFailure: (String) -> Void
  private let didStop: (UUID) -> Void
  private let runLoopLock = NSLock()

  private var stateMachine = HoldToQuitStateMachine()
  private var chordTracker = QuitChordTracker()
  private var capturedQKeyCode: CGKeyCode?
  private var deadlineTimer: Timer?
  private var watchdogTimer: Timer?
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var workerRunLoop: CFRunLoop?
  private var stopRequested = false
  private var hasReportedOperationalFailure = false

  init(
    durationProvider: @escaping () -> TimeInterval,
    showOverlay: @escaping (Session, TimeInterval) -> Void,
    hideOverlay: @escaping (UInt64) -> Void,
    operationalFailure: @escaping (String) -> Void,
    didStop: @escaping (UUID) -> Void
  ) {
    self.durationProvider = durationProvider
    self.showOverlay = showOverlay
    self.hideOverlay = hideOverlay
    self.operationalFailure = operationalFailure
    self.didStop = didStop
  }

  func start() {
    let thread = Thread { [self] in
      run()
    }
    thread.name = "QuitDelay Event Tap"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  func stop() {
    runLoopLock.lock()
    stopRequested = true
    let runLoop = workerRunLoop
    runLoopLock.unlock()

    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
      apply(stateMachine.handle(.interrupted(qIsDown: chordTracker.qIsDown)))
      clearCapturedKeyIfIdle()
      tearDownEventTap()
      if let workerRunLoop {
        CFRunLoopStop(workerRunLoop)
      }
    }
    CFRunLoopWakeUp(runLoop)
  }

  func cancelCurrentHold() {
    performOnWorkerRunLoop { [weak self] in
      guard let self else { return }
      apply(stateMachine.handle(.interrupted(qIsDown: chordTracker.qIsDown)))
      clearCapturedKeyIfIdle()
    }
  }

  private func run() {
    autoreleasepool {
      defer {
        tearDownEventTap()
        clearRunLoop()
        didStop(id)
      }

      guard let runLoop = CFRunLoopGetCurrent() else {
        return
      }
      runLoopLock.lock()
      workerRunLoop = runLoop
      let shouldStop = stopRequested
      runLoopLock.unlock()

      guard !shouldStop else {
        return
      }

      guard installEventTap(on: runLoop) else {
        reportOperationalFailure(
          "QuitDelay could not start monitoring Command–Q. Retry system access or relaunch the app."
        )
        return
      }

      scheduleWatchdog()
      CFRunLoopRun()
    }
  }

  private func installEventTap(on runLoop: CFRunLoop) -> Bool {
    let eventMask = [
      CGEventType.keyDown,
      CGEventType.keyUp,
      CGEventType.flagsChanged,
    ].reduce(CGEventMask(0)) { mask, type in
      mask | (CGEventMask(1) << type.rawValue)
    }

    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgAnnotatedSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: eventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      return false
    }

    guard let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
      CFMachPortInvalidate(eventTap)
      return false
    }

    self.eventTap = eventTap
    self.runLoopSource = runLoopSource
    CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    return CGEvent.tapIsEnabled(tap: eventTap)
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      apply(stateMachine.handle(.interrupted(qIsDown: chordTracker.qIsDown)))
      clearCapturedKeyIfIdle()
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
        if !CGEvent.tapIsEnabled(tap: eventTap), let workerRunLoop {
          reportOperationalFailure(
            "macOS disabled QuitDelay’s keyboard monitor. Retry system access before continuing."
          )
          CFRunLoopStop(workerRunLoop)
        }
      }
      return Unmanaged.passUnretained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

    switch type {
    case .keyDown:
      let transition: HoldToQuitStateMachine.Transition
      let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

      if let capturedQKeyCode {
        guard keyCode == capturedQKeyCode else {
          return Unmanaged.passUnretained(event)
        }
        chordTracker.handleQDown(flags: event.flags)
        transition = stateMachine.handle(.qDown)
      } else if !isAutorepeat,
        QuitShortcut.isPlainCommand(event.flags),
        QuitShortcut.representsLogicalQ(event)
      {
        let annotatedTargetPID = Int32(
          event.getIntegerValueField(.eventTargetUnixProcessID)
        )
        let frontmostTargetPID = NSWorkspace.shared.frontmostApplication
          .map { Int32($0.processIdentifier) }
        guard
          let targetPID = QuitTargetResolver.resolve(
            frontmostPID: frontmostTargetPID,
            annotatedPID: annotatedTargetPID,
            ownPID: Int32(getpid())
          )
        else {
          return Unmanaged.passUnretained(event)
        }
        Self.logger.debug(
          "Hold started for PID \(targetPID, privacy: .public); frontmost=\(frontmostTargetPID ?? 0, privacy: .public), annotated=\(annotatedTargetPID, privacy: .public)"
        )
        self.capturedQKeyCode = keyCode
        chordTracker.handleQDown(flags: event.flags)
        transition = stateMachine.handle(
          .plainCommandQDown(
            targetPID: targetPID,
            duration: durationProvider()
          )
        )
      } else if isAutorepeat,
        QuitShortcut.isPlainCommand(event.flags),
        QuitShortcut.representsLogicalQ(event)
      {
        self.capturedQKeyCode = keyCode
        chordTracker.handleQDown(flags: event.flags)
        transition = stateMachine.handle(.qDown)
      } else {
        return Unmanaged.passUnretained(event)
      }

      apply(transition)
      clearCapturedKeyIfIdle()
      return transition.suppressEvent ? nil : Unmanaged.passUnretained(event)

    case .keyUp:
      guard keyCode == capturedQKeyCode else {
        return Unmanaged.passUnretained(event)
      }
      chordTracker.handleQUp(flags: event.flags)
      let transition = stateMachine.handle(.qUp)
      apply(transition)
      clearCapturedKeyIfIdle()
      return transition.suppressEvent ? nil : Unmanaged.passUnretained(event)

    case .flagsChanged:
      chordTracker.handleModifiersChanged(flags: event.flags)
      let transition = stateMachine.handle(
        .modifiersChanged(
          plainCommandIsHeld: chordTracker.plainCommandIsHeld,
          qIsDown: chordTracker.qIsDown
        )
      )
      apply(transition)
      clearCapturedKeyIfIdle()
      return Unmanaged.passUnretained(event)

    default:
      return Unmanaged.passUnretained(event)
    }
  }

  private func apply(_ transition: HoldToQuitStateMachine.Transition) {
    for effect in transition.effects {
      switch effect {
      case .showOverlay(let session):
        showOverlay(
          session,
          ProcessInfo.processInfo.systemUptime + session.duration
        )

      case .hideOverlay(let generation):
        hideOverlay(generation)

      case .scheduleDeadline(let session):
        scheduleDeadline(for: session)

      case .cancelDeadline:
        deadlineTimer?.invalidate()
        deadlineTimer = nil

      case .requestApplicationQuit(let targetPID):
        Self.logger.info(
          "Requesting normal termination for PID \(targetPID, privacy: .public)"
        )
        if !requestApplicationQuit(targetPID: targetPID) {
          Self.logger.error(
            "Normal termination request failed for PID \(targetPID, privacy: .public)"
          )
        }
      }
    }
  }

  private func scheduleDeadline(for session: Session) {
    deadlineTimer?.invalidate()

    let timer = Timer(timeInterval: session.duration, repeats: false) { [weak self] _ in
      self?.deadlineReached(for: session)
    }
    deadlineTimer = timer
    RunLoop.current.add(timer, forMode: .common)
  }

  private func scheduleWatchdog() {
    let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
      self?.verifyEventTapIsAlive()
    }
    watchdogTimer = timer
    RunLoop.current.add(timer, forMode: .common)
  }

  private func verifyEventTapIsAlive() {
    guard let eventTap, CFMachPortIsValid(eventTap) else {
      apply(stateMachine.handle(.interrupted(qIsDown: chordTracker.qIsDown)))
      clearCapturedKeyIfIdle()
      reportOperationalFailure(
        "QuitDelay’s keyboard monitor stopped responding. Retry system access before continuing."
      )
      if let workerRunLoop {
        CFRunLoopStop(workerRunLoop)
      }
      return
    }

    guard !CGEvent.tapIsEnabled(tap: eventTap) else { return }
    apply(stateMachine.handle(.interrupted(qIsDown: chordTracker.qIsDown)))
    clearCapturedKeyIfIdle()
    CGEvent.tapEnable(tap: eventTap, enable: true)

    if !CGEvent.tapIsEnabled(tap: eventTap), let workerRunLoop {
      reportOperationalFailure(
        "macOS disabled QuitDelay’s keyboard monitor. Retry system access before continuing."
      )
      CFRunLoopStop(workerRunLoop)
    }
  }

  private func deadlineReached(for session: Session) {
    let qIsDown = chordTracker.qIsDown
    let chordIsStillHeld = chordTracker.isHeld
    let targetApplication = NSRunningApplication(
      processIdentifier: pid_t(session.targetPID)
    )
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let targetIsStillActive =
      targetApplication?.isTerminated == false
      && frontmostPID == pid_t(session.targetPID)

    Self.logger.debug(
      "Hold deadline for PID \(session.targetPID, privacy: .public); qDown=\(qIsDown, privacy: .public), chordHeld=\(chordIsStillHeld, privacy: .public), targetActive=\(targetIsStillActive, privacy: .public), frontmost=\(frontmostPID ?? 0, privacy: .public)"
    )

    let transition = stateMachine.handle(
      .deadline(
        generation: session.generation,
        targetIsStillActive: targetIsStillActive,
        chordIsStillHeld: chordIsStillHeld,
        qIsDown: qIsDown
      )
    )
    apply(transition)
    clearCapturedKeyIfIdle()
  }

  private func requestApplicationQuit(targetPID: Int32) -> Bool {
    guard
      let application = NSRunningApplication(
        processIdentifier: pid_t(targetPID)
      ),
      !application.isTerminated
    else {
      return false
    }
    return application.terminate()
  }

  private func tearDownEventTap() {
    deadlineTimer?.invalidate()
    deadlineTimer = nil
    watchdogTimer?.invalidate()
    watchdogTimer = nil

    if let workerRunLoop, let runLoopSource {
      CFRunLoopRemoveSource(workerRunLoop, runLoopSource, .commonModes)
    }
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
    }

    runLoopSource = nil
    eventTap = nil
  }

  private func performOnWorkerRunLoop(_ block: @escaping () -> Void) {
    runLoopLock.lock()
    let runLoop = workerRunLoop
    runLoopLock.unlock()

    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(runLoop)
  }

  private func clearRunLoop() {
    runLoopLock.lock()
    workerRunLoop = nil
    runLoopLock.unlock()
  }

  private func reportOperationalFailure(_ message: String) {
    guard !hasReportedOperationalFailure else { return }
    hasReportedOperationalFailure = true
    operationalFailure(message)
  }

  private func clearCapturedKeyIfIdle() {
    if stateMachine.phase == .idle {
      capturedQKeyCode = nil
      chordTracker.reset()
    }
  }

}

struct QuitChordTracker {
  private(set) var qIsDown = false
  private(set) var plainCommandIsHeld = false

  var isHeld: Bool {
    qIsDown && plainCommandIsHeld
  }

  mutating func handleQDown(flags: CGEventFlags) {
    qIsDown = true
    plainCommandIsHeld = QuitShortcut.isPlainCommand(flags)
  }

  mutating func handleQUp(flags: CGEventFlags) {
    qIsDown = false
    plainCommandIsHeld = QuitShortcut.isPlainCommand(flags)
  }

  mutating func handleModifiersChanged(flags: CGEventFlags) {
    plainCommandIsHeld = QuitShortcut.isPlainCommand(flags)
  }

  mutating func reset() {
    qIsDown = false
    plainCommandIsHeld = false
  }
}

enum QuitTargetResolver {
  static func resolve(
    frontmostPID: Int32?,
    annotatedPID: Int32,
    ownPID: Int32
  ) -> Int32? {
    if annotatedPID > 0 {
      return annotatedPID == ownPID ? nil : annotatedPID
    }
    if let frontmostPID, frontmostPID > 0 {
      return frontmostPID == ownPID ? nil : frontmostPID
    }
    return nil
  }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }

  let worker = Unmanaged<EventTapWorker>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  return autoreleasepool {
    worker.handle(type: type, event: event)
  }
}
