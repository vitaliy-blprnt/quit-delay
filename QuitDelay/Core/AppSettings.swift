import Foundation

final class AppSettings: ObservableObject {
  static let defaultHoldDuration: TimeInterval = 1.5
  static let holdDurationRange: ClosedRange<TimeInterval> = 0.5...5.0
  static let holdDurationStep: TimeInterval = 0.25

  @Published var holdDuration: TimeInterval {
    didSet {
      let normalized = Self.normalize(holdDuration)
      if normalized != holdDuration {
        holdDuration = normalized
      }

      durationLock.lock()
      inputThreadDuration = normalized
      durationLock.unlock()
      defaults.set(normalized, forKey: Self.holdDurationKey)
    }
  }

  private static let holdDurationKey = "holdDuration"

  private let defaults: UserDefaults
  private let durationLock = NSLock()
  private var inputThreadDuration: TimeInterval

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    let storedDuration =
      defaults.object(forKey: Self.holdDurationKey) == nil
      ? Self.defaultHoldDuration
      : defaults.double(forKey: Self.holdDurationKey)
    let normalizedDuration = Self.normalize(storedDuration)

    holdDuration = normalizedDuration
    inputThreadDuration = normalizedDuration
  }

  func snapshotHoldDuration() -> TimeInterval {
    durationLock.lock()
    defer { durationLock.unlock() }
    return inputThreadDuration
  }

  private static func normalize(_ value: TimeInterval) -> TimeInterval {
    guard value.isFinite else { return defaultHoldDuration }
    return min(max(value, holdDurationRange.lowerBound), holdDurationRange.upperBound)
  }
}
