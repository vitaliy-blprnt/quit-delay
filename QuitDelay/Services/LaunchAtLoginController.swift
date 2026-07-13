import ServiceManagement

final class LaunchAtLoginController: ObservableObject {
  @Published private(set) var status: SMAppService.Status = .notRegistered
  @Published private(set) var lastError: String?

  var isRegistered: Bool {
    status == .enabled || status == .requiresApproval
  }

  var isEnabled: Bool {
    status == .enabled
  }

  var requiresApproval: Bool {
    status == .requiresApproval
  }

  init() {
    refresh()
  }

  func refresh() {
    status = SMAppService.mainApp.status
  }

  func setEnabled(_ enabled: Bool) {
    lastError = nil
    refresh()

    do {
      if enabled {
        guard status == .notRegistered || status == .notFound else { return }
        try SMAppService.mainApp.register()
      } else {
        guard status == .enabled || status == .requiresApproval else { return }
        try SMAppService.mainApp.unregister()
      }
    } catch {
      lastError = error.localizedDescription
    }

    refresh()
  }

  func openLoginItemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
