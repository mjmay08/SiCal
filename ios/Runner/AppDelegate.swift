import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "dev.mmay.sical/calendar_file"
  private var channel: FlutterMethodChannel?
  private var pendingCalendarTexts: [String] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let methodChannel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
      methodChannel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(nil)
          return
        }

        switch call.method {
        case "consumePendingCalendarFileText":
          if self.pendingCalendarTexts.isEmpty {
            result(nil)
          } else {
            result(self.pendingCalendarTexts.removeFirst())
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      channel = methodChannel
    }

    if let launchUrl = launchOptions?[.url] as? URL {
      enqueueCalendarText(from: launchUrl)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    enqueueCalendarText(from: url)
    return super.application(app, open: url, options: options)
  }

  private func enqueueCalendarText(from url: URL) {
    guard isSupportedCalendarURL(url) else { return }

    var calendarText: String?
    let startedAccess = url.startAccessingSecurityScopedResource()
    defer {
      if startedAccess { url.stopAccessingSecurityScopedResource() }
    }

    if let data = try? Data(contentsOf: url),
       let text = String(data: data, encoding: .utf8),
       !text.isEmpty {
      calendarText = text
    }

    guard let calendarText else { return }

    pendingCalendarTexts.append(calendarText)
    channel?.invokeMethod("onCalendarFileText", arguments: nil)
  }

  private func isSupportedCalendarURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "ics" || ext == "ical" || ext == "ifb" || ext == "vcs"
  }
}
