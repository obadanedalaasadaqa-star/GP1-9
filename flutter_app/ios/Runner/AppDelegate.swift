import Flutter
import LocalAuthentication
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NexusBiometry") {
      let channel = FlutterMethodChannel(
        name: "nexus/biometry", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "status" else {
          result(FlutterMethodNotImplemented)
          return
        }
        result(AppDelegate.biometryStatus())
      }
    }
  }

  /// Why Face ID can or can't be used: the biometry type and the LAError code
  /// of the biometrics-only policy (no "error" key = usable). No prompt.
  static func biometryStatus() -> [String: Any] {
    let context = LAContext()
    var error: NSError?
    let ok = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    var status: [String: Any] = [:]
    switch context.biometryType {
    case .faceID: status["type"] = "face"
    case .touchID: status["type"] = "touch"
    default: status["type"] = "none"
    }
    if !ok { status["error"] = error?.code ?? -6 }
    return status
  }
}
