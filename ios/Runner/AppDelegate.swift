import Flutter
import UIKit
import UserNotifications
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PulsePathRemoteActions") {
      PulsePathRemoteActions.register(with: registrar)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if info["type"] as? String == "chat",
       response.actionIdentifier == "reply" || response.actionIdentifier == "read" {
      PulsePathRemoteActions.enqueue(response, completion: completionHandler)
      return
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }
}

/// APNs responses have a different payload from local notifications. Keep them
/// until Dart restores the authenticated session, including a cold launch.
final class PulsePathRemoteActions: NSObject, FlutterPlugin {
  private static let storageKey = "pulsepath.remoteChatActions"
  private static var channel: FlutterMethodChannel?
  private static var completions: [String: () -> Void] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PulsePathRemoteActions()
    let channel = FlutterMethodChannel(name: "pulsepath/remote_notification_actions", binaryMessenger: registrar.messenger())
    self.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  static func enqueue(_ response: UNNotificationResponse, completion: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo
    guard let sender = info["senderId"] as? String,
          let receiver = info["receiverId"] as? String,
          let message = info["messageId"] as? String else { completion(); return }
    let key = UUID().uuidString
    var events = UserDefaults.standard.array(forKey: storageKey) as? [[String: String]] ?? []
    events.append(["key": key, "senderId": sender, "receiverId": receiver,
      "messageId": message, "actionId": response.actionIdentifier,
      "input": (response as? UNTextInputNotificationResponse)?.userText ?? "",
      "requestId": response.notification.request.identifier])
    UserDefaults.standard.set(events, forKey: storageKey)
    completions[key] = completion
    channel?.invokeMethod("pendingActions", arguments: nil)
    // The OS gives background actions limited execution time. The durable event
    // remains queued if Flutter has not restored the session within that window.
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
      completions.removeValue(forKey: key)?()
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "pending" {
      result(UserDefaults.standard.array(forKey: Self.storageKey) ?? [])
    } else if call.method == "complete", let key = call.arguments as? String {
      var events = UserDefaults.standard.array(forKey: Self.storageKey) as? [[String: String]] ?? []
      if let event = events.first(where: { $0["key"] == key }), let request = event["requestId"] {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request])
      }
      events.removeAll { $0["key"] == key }
      UserDefaults.standard.set(events, forKey: Self.storageKey)
      Self.completions.removeValue(forKey: key)?()
      result(nil)
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}
