import SwiftUI

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @ObservedObject var permissions: AccessibilityPermissionController
  let retryInterception: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      GroupBox("Quit Delay") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Hold duration")
            Spacer()
            Text(durationLabel)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Slider(
            value: $settings.holdDuration,
            in: AppSettings.holdDurationRange,
            step: AppSettings.holdDurationStep
          )
          HStack {
            Text("0.5 sec")
            Spacer()
            Text("5 sec")
          }
          .font(.caption)
          .foregroundStyle(.tertiary)
        }
        .padding(6)
      }

      GroupBox("Startup") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Launch on Boot", isOn: launchOnBootBinding)
          Text("QuitDelay starts automatically after you sign in to macOS.")
            .font(.caption)
            .foregroundStyle(.secondary)

          if launchAtLogin.requiresApproval {
            HStack {
              Text("Approval is required in Login Items.")
                .font(.caption)
                .foregroundStyle(.orange)
              Spacer()
              Button("Open Login Items") {
                launchAtLogin.openLoginItemSettings()
              }
            }
          }

          if let error = launchAtLogin.lastError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(6)
      }

      GroupBox("System Access") {
        VStack(alignment: .leading, spacing: 10) {
          Label(
            permissions.isReady ? "QuitDelay is ready" : "Permission required",
            systemImage: permissions.isReady
              ? "checkmark.circle.fill"
              : "exclamationmark.triangle.fill"
          )
          .foregroundStyle(permissions.isReady ? .green : .orange)

          permissionRow(
            title: "Replay shortcuts",
            isAllowed: permissions.canPostEvents
          )
          permissionRow(
            title: "Monitor shortcuts",
            isAllowed: permissions.canListenToEvents
          )

          if !permissions.isReady {
            Text("macOS must allow QuitDelay to monitor and replay the Command–Q shortcut.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            if let runtimeError = permissions.runtimeError {
              Text(runtimeError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
              Button(permissionActionTitle) {
                permissions.requestRequiredAccess()
                retryInterception()
              }
              Button("Open System Settings") {
                permissions.openRelevantSystemSettings()
              }
            }
          }
        }
        .padding(6)
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  private var launchOnBootBinding: Binding<Bool> {
    Binding(
      get: { launchAtLogin.isEnabled },
      set: { newValue in
        if launchAtLogin.requiresApproval && newValue {
          launchAtLogin.openLoginItemSettings()
        } else {
          launchAtLogin.setEnabled(newValue)
        }
      }
    )
  }

  private var durationLabel: String {
    let value = settings.holdDuration
    if value.rounded() == value {
      return String(format: "%.0f sec", value)
    }
    return String(format: "%.2f sec", value)
  }

  private var permissionActionTitle: String {
    if permissions.runtimeError != nil {
      return "Retry"
    }
    return permissions.canPostEvents ? "Request Input Monitoring" : "Request Accessibility"
  }

  private func permissionRow(title: String, isAllowed: Bool) -> some View {
    HStack {
      Text(title)
        .font(.caption)
      Spacer()
      Label(
        isAllowed ? "Allowed" : "Needed",
        systemImage: isAllowed ? "checkmark.circle.fill" : "circle"
      )
      .font(.caption)
      .foregroundStyle(isAllowed ? .green : .secondary)
    }
  }
}
