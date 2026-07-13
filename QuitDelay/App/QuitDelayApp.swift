import AppKit

@main
struct QuitDelayApplication {
  static func main() {
    let application = NSApplication.shared
    let delegate: any NSApplicationDelegate =
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
      ? AppDelegate()
      : UnitTestAppDelegate()

    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

private final class UnitTestAppDelegate: NSObject, NSApplicationDelegate {}
