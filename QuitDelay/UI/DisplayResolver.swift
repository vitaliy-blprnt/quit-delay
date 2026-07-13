import AppKit
import CoreGraphics

struct DisplayResolver {
  func screenForFrontmostWindow(of targetPID: pid_t) -> NSScreen? {
    if let windowBounds = frontmostWindowBounds(of: targetPID),
      let screen = screenWithLargestIntersection(withQuartzRect: windowBounds)
    {
      return screen
    }

    if let mainScreen = NSScreen.main {
      return mainScreen
    }

    let mouseLocation = NSEvent.mouseLocation
    if let pointerScreen = NSScreen.screens.first(where: {
      NSMouseInRect(mouseLocation, $0.frame, false)
    }) {
      return pointerScreen
    }

    return NSScreen.screens.first
  }

  private func frontmostWindowBounds(of targetPID: pid_t) -> CGRect? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
      let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]]
    else {
      return nil
    }

    for window in windowList {
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == targetPID,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
        let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(
          dictionaryRepresentation: boundsDictionary as CFDictionary
        ),
        bounds.width > 1,
        bounds.height > 1
      else {
        continue
      }
      return bounds
    }

    return nil
  }

  private func screenWithLargestIntersection(withQuartzRect rect: CGRect) -> NSScreen? {
    let screensByID = NSScreen.screens.compactMap { screen in
      screen.displayID.map { ($0, screen) }
    }
    let displays = screensByID.map { pair in
      DisplayGeometry.Display(id: pair.0, bounds: CGDisplayBounds(pair.0))
    }

    guard
      let displayID = DisplayGeometry.displayID(
        forWindow: rect,
        displays: displays
      )
    else {
      return nil
    }
    return screensByID.first(where: { $0.0 == displayID })?.1
  }
}

enum DisplayGeometry {
  struct Display: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
  }

  static func displayID(
    forWindow windowBounds: CGRect,
    displays: [Display]
  ) -> CGDirectDisplayID? {
    var bestMatch: (id: CGDirectDisplayID, area: CGFloat)?

    for display in displays {
      let intersection = windowBounds.intersection(display.bounds)
      let area = intersection.isNull ? 0 : intersection.width * intersection.height

      if let currentBest = bestMatch {
        if area > currentBest.area
          || (area == currentBest.area && display.id < currentBest.id)
        {
          bestMatch = (display.id, area)
        }
      } else {
        bestMatch = (display.id, area)
      }
    }

    guard let bestMatch, bestMatch.area > 0 else { return nil }
    return bestMatch.id
  }
}

extension NSScreen {
  fileprivate var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
      .map { CGDirectDisplayID($0.uint32Value) }
  }
}
