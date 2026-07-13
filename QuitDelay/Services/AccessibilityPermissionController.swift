import AppKit
import ApplicationServices

final class AccessibilityPermissionController: ObservableObject {
  @Published private(set) var isAccessibilityGranted = false
  @Published private(set) var runtimeError: String?

  private let preflightAccessibilityAccess: () -> Bool
  private let requestAccessibilityAccess: () -> Bool

  var isReady: Bool {
    isAccessibilityGranted && runtimeError == nil
  }

  init(
    preflightAccessibilityAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
    requestAccessibilityAccess: @escaping () -> Bool = {
      let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
      ] as CFDictionary
      return AXIsProcessTrustedWithOptions(options)
    }
  ) {
    self.preflightAccessibilityAccess = preflightAccessibilityAccess
    self.requestAccessibilityAccess = requestAccessibilityAccess
    refresh()
  }

  func refresh() {
    let previouslyAllowed = isAccessibilityGranted
    isAccessibilityGranted = preflightAccessibilityAccess()

    if !previouslyAllowed && isAccessibilityGranted {
      runtimeError = nil
    }
  }

  func requestRequiredAccess() {
    runtimeError = nil
    if !preflightAccessibilityAccess() {
      _ = requestAccessibilityAccess()
    }
    refresh()
  }

  func reportOperationalFailure(_ message: String) {
    refresh()
    runtimeError = message
  }

  func openRelevantSystemSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }
}
