import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let settings = AppSettings()
  let launchAtLogin = LaunchAtLoginController()
  let permissions = AccessibilityPermissionController()

  private lazy var overlayController = HoldOverlayController()
  private lazy var interceptionController = QuitInterceptionController(
    settings: settings,
    overlayController: overlayController,
    operationalFailureHandler: { [weak self] message in
      self?.permissions.reportOperationalFailure(message)
      self?.updateInterceptionState()
    }
  )

  private var statusItem: NSStatusItem?
  private var launchOnBootMenuItem: NSMenuItem?
  private var settingsWindowController: SettingsWindowController?
  private var permissionPollTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !ProcessInfo.processInfo.isRunningUnitTests else { return }

    configureStatusItem()
    launchAtLogin.refresh()
    permissions.refresh()
    updateInterceptionState()

    if !permissions.isReady && !ProcessInfo.processInfo.permissionPromptsAreDisabled {
      permissions.requestRequiredAccess()
    }

    permissionPollTimer = Timer.scheduledTimer(
      timeInterval: 1.5,
      target: self,
      selector: #selector(refreshExternalState),
      userInfo: nil,
      repeats: true
    )
    if let permissionPollTimer {
      RunLoop.main.add(permissionPollTimer, forMode: .common)
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationBecameActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(sessionDidResignActive),
      name: NSWorkspace.sessionDidResignActiveNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(systemWillSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(systemDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard !ProcessInfo.processInfo.isRunningUnitTests else { return }

    permissionPollTimer?.invalidate()
    interceptionController.stop()
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  func menuWillOpen(_ menu: NSMenu) {
    launchAtLogin.refresh()
    updateLaunchOnBootMenuItem()
  }

  private func configureStatusItem() {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      let image = NSImage(
        systemSymbolName: "hourglass.circle",
        accessibilityDescription: "QuitDelay"
      )
      image?.isTemplate = true
      button.image = image
      button.toolTip = "QuitDelay"
    }

    let menu = NSMenu()
    menu.delegate = self

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(showSettings),
      keyEquivalent: ","
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    let launchItem = NSMenuItem(
      title: "Launch on Boot",
      action: #selector(toggleLaunchOnBoot),
      keyEquivalent: ""
    )
    launchItem.target = self
    menu.addItem(launchItem)
    launchOnBootMenuItem = launchItem

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit QuitDelay",
      action: #selector(quitQuitDelay),
      keyEquivalent: ""
    )
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem.menu = menu
    self.statusItem = statusItem
    updateLaunchOnBootMenuItem()
  }

  private func updateLaunchOnBootMenuItem() {
    switch launchAtLogin.status {
    case .enabled:
      launchOnBootMenuItem?.state = .on
      launchOnBootMenuItem?.isEnabled = true
    case .requiresApproval:
      launchOnBootMenuItem?.state = .mixed
      launchOnBootMenuItem?.isEnabled = true
    case .notRegistered:
      launchOnBootMenuItem?.state = .off
      launchOnBootMenuItem?.isEnabled = true
    case .notFound:
      launchOnBootMenuItem?.state = .off
      launchOnBootMenuItem?.isEnabled = false
    @unknown default:
      launchOnBootMenuItem?.state = .off
      launchOnBootMenuItem?.isEnabled = false
    }
  }

  private func updateInterceptionState() {
    if permissions.isReady {
      interceptionController.startIfNeeded()
    } else {
      interceptionController.stop()
    }
  }

  @objc private func refreshExternalState() {
    permissions.refresh()
    updateInterceptionState()
  }

  @objc private func applicationBecameActive() {
    launchAtLogin.refresh()
    permissions.refresh()
    updateInterceptionState()
  }

  @objc private func sessionDidResignActive() {
    interceptionController.cancelCurrentHold()
  }

  @objc private func systemWillSleep() {
    interceptionController.cancelCurrentHold()
  }

  @objc private func systemDidWake() {
    interceptionController.restart()
  }

  @objc private func showSettings() {
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        rootView: SettingsView(
          settings: settings,
          launchAtLogin: launchAtLogin,
          permissions: permissions,
          retryInterception: { [weak self] in
            self?.permissions.refresh()
            self?.updateInterceptionState()
          }
        )
      )
    }

    settingsWindowController?.show()
  }

  @objc private func toggleLaunchOnBoot() {
    switch launchAtLogin.status {
    case .enabled:
      launchAtLogin.setEnabled(false)
    case .notRegistered:
      launchAtLogin.setEnabled(true)
    case .requiresApproval:
      launchAtLogin.openLoginItemSettings()
    case .notFound:
      break
    @unknown default:
      break
    }
    updateLaunchOnBootMenuItem()

    if let errorMessage = launchAtLogin.lastError {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Couldn’t update Launch on Boot"
      alert.informativeText = errorMessage
      alert.runModal()
    }
  }

  @objc private func quitQuitDelay() {
    NSApp.terminate(nil)
  }
}

extension ProcessInfo {
  fileprivate var isRunningUnitTests: Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }

  fileprivate var permissionPromptsAreDisabled: Bool {
    environment["QUITDELAY_DISABLE_PERMISSION_PROMPTS"] == "1"
  }
}
