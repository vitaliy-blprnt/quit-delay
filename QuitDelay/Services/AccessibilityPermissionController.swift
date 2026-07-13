import AppKit
import CoreGraphics

final class AccessibilityPermissionController: ObservableObject {
  @Published private(set) var canListenToEvents = false
  @Published private(set) var canPostEvents = false
  @Published private(set) var runtimeError: String?

  var isReady: Bool {
    canListenToEvents && canPostEvents && runtimeError == nil
  }

  init() {
    refresh()
  }

  func refresh() {
    canListenToEvents = CGPreflightListenEventAccess()
    canPostEvents = CGPreflightPostEventAccess()
  }

  func requestRequiredAccess() {
    runtimeError = nil
    if !CGPreflightPostEventAccess() {
      _ = CGRequestPostEventAccess()
      refresh()
      return
    } else if !CGPreflightListenEventAccess() {
      _ = CGRequestListenEventAccess()
    }
    refresh()
  }

  func reportOperationalFailure(_ message: String) {
    refresh()
    runtimeError = message
  }

  func openRelevantSystemSettings() {
    let pane =
      canPostEvents && runtimeError == nil
      ? "Privacy_ListenEvent"
      : "Privacy_Accessibility"
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }
}
