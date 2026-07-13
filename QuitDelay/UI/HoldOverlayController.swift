import AppKit
import SwiftUI

final class HoldOverlayController {
  private let displayResolver = DisplayResolver()
  private let model = HoldOverlayModel()
  private lazy var panel = makePanel()
  private var activeGeneration: UInt64?

  func show(
    targetPID: Int32,
    generation: UInt64,
    duration: TimeInterval,
    deadlineUptime: TimeInterval
  ) {
    let remainingDuration = max(
      0,
      deadlineUptime - ProcessInfo.processInfo.systemUptime
    )
    guard remainingDuration > 0 else { return }

    activeGeneration = generation

    let application = NSRunningApplication(processIdentifier: pid_t(targetPID))
    let appName = application?.localizedName ?? "this app"
    let appIcon =
      application?.icon
      ?? NSImage(systemSymbolName: "app", accessibilityDescription: appName)
      ?? NSImage()
    let targetScreen =
      displayResolver.screenForFrontmostWindow(of: pid_t(targetPID))
      ?? NSScreen.main
      ?? NSScreen.screens.first

    let initialProgress = min(max(1 - remainingDuration / duration, 0), 1)
    model.prepare(
      appName: appName,
      appIcon: appIcon,
      initialProgress: initialProgress
    )

    if let targetScreen {
      let overlaySize = panel.frame.size
      let visibleFrame = targetScreen.visibleFrame
      let origin = NSPoint(
        x: visibleFrame.midX - overlaySize.width / 2,
        y: visibleFrame.midY - overlaySize.height / 2
      )
      panel.setFrameOrigin(origin)
    }

    panel.orderFrontRegardless()
    model.animateProgress(duration: remainingDuration)
  }

  func hide(generation: UInt64) {
    guard activeGeneration == generation else { return }
    activeGeneration = nil
    panel.orderOut(nil)
    model.reset()
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 116),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    panel.contentView = NSHostingView(rootView: HoldOverlayView(model: model))
    return panel
  }
}

private final class HoldOverlayModel: ObservableObject {
  @Published var appName = ""
  @Published var appIcon = NSImage()
  @Published var progress = 0.0

  func prepare(appName: String, appIcon: NSImage, initialProgress: Double) {
    self.appName = appName
    self.appIcon = appIcon
    progress = initialProgress
  }

  func animateProgress(duration: TimeInterval) {
    withAnimation(.linear(duration: duration)) {
      progress = 1
    }
  }

  func reset() {
    progress = 0
  }
}

private struct HoldOverlayView: View {
  @ObservedObject var model: HoldOverlayModel

  var body: some View {
    HStack(spacing: 18) {
      ZStack {
        Circle()
          .stroke(Color.primary.opacity(0.13), lineWidth: 5)
        Circle()
          .trim(from: 0, to: model.progress)
          .stroke(
            Color.accentColor,
            style: StrokeStyle(lineWidth: 5, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
        Image(nsImage: model.appIcon)
          .resizable()
          .scaledToFit()
          .frame(width: 42, height: 42)
      }
      .frame(width: 64, height: 64)

      VStack(alignment: .leading, spacing: 7) {
        Text("Hold ⌘Q to Quit")
          .font(.system(size: 18, weight: .semibold))
        Text(model.appName)
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .lineLimit(1)

        ProgressView(value: model.progress)
          .progressViewStyle(.linear)
          .tint(.accentColor)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 18)
    .frame(width: 340, height: 116)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }
  }
}
