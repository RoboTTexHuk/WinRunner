import UIKit
import Flutter
import AppsFlyerLib

// Начиная с iOS SDK, используемого в этом проекте, UIScene lifecycle
// обязателен — без него приложение падает при запуске с ошибкой
// "Application failed to launch: UIScene life cycle is required...".
// Этот файл создаёт окно и FlutterViewController вручную (так же, как
// раньше это делал Main.storyboard при классическом, не-scene запуске),
// и один раз настраивает те же MethodChannel'ы, что и раньше в AppDelegate.
//
// ВАЖНО: движок Flutter (FlutterEngine) создаётся и запускается здесь же,
// и именно на НЁМ регистрируются плагины (GeneratedPluginRegistrant).
// Раньше регистрация шла на AppDelegate (GeneratedPluginRegistrant.register(with: self)),
// но под scene lifecycle это регистрировало плагины "в никуда" — реально
// запущенный движок (созданный по умолчанию внутри FlutterViewController())
// плагинов не получал, из-за чего все platform channel'ы (включая
// firebase_core) падали с "channel-error, Unable to establish connection".
@available(iOS 13, *)
@objc class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?
  var flutterEngine: FlutterEngine?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let engine = FlutterEngine(name: "io.flutter")
    engine.run()
    GeneratedPluginRegistrant.register(with: engine)
    self.flutterEngine = engine

    let flutterViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)

    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = flutterViewController
    self.window = window
    window.makeKeyAndVisible()

    // Та же настройка MethodChannel'ов, что раньше выполнялась
    // в AppDelegate.didFinishLaunchingWithOptions, но теперь — как
    // только реально появился FlutterViewController.
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.setupMethodChannels(for: flutterViewController)
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    // Перенесено из AppDelegate.applicationDidBecomeActive, чтобы
    // гарантированно срабатывать и при scene-based lifecycle.
    AppsFlyerLib.shared().start()
  }
}
