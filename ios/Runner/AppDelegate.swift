import UIKit
import Flutter
import Firebase
import FirebaseMessaging
import UserNotifications
import AppsFlyerLib
import AppTrackingTransparency
import AdSupport

@main
@objc class AppDelegate: FlutterAppDelegate, MessagingDelegate, AppsFlyerLibDelegate {
  
  // MARK: - AppsFlyer
  private let appsFlyerDevKey = "qsBLmy7dAXDQhowM8V3ca4"
  private let appleAppID = "6812799848"  // без "id"
  private let appsFlyerDeepLinkChannelName = "appsflyer_deeplink_channel"
  
  // MARK: - Channel Names (FCM)
  private enum ChannelName {
    static let app = "com.example.app"
    static let fcmToken = "com.example.fcm/token"
    static let fcmNotification = "com.example.fcm/notification"
    static let fcmPushData = "com.example.fcm/push" // полный userInfo пуша
  }
  
  // MARK: - Properties
  private var appMethodChannel: FlutterMethodChannel?
  private var fcmTokenChannel: FlutterMethodChannel?
  private var fcmNotificationChannel: FlutterMethodChannel?
  private var fcmPushDataChannel: FlutterMethodChannel?
  private var appsFlyerDeepLinkChannel: FlutterMethodChannel?

  // Реальный FlutterViewController, переданный из SceneDelegate.
  // ВАЖНО: под UIScene lifecycle своё окно (`window`) создаёт и хранит
  // SceneDelegate, а собственное свойство AppDelegate.window остаётся nil —
  // поэтому старое выражение `window?.rootViewController as? FlutterViewController`
  // здесь всегда возвращало nil, и все invokeMethod ниже молча ничего не
  // отправляли во Flutter. Используем вместо этого явно сохранённую ссылку.
  private var flutterViewController: FlutterViewController?

  // FCM-токен может прийти (Messaging didReceiveRegistrationToken /
  // .token{}) ДО того, как SceneDelegate успеет вызвать
  // setupMethodChannels(for:) и передать реальный FlutterViewController —
  // это обычная ситуация на холодном старте. В этом случае токен
  // сохраняется здесь и досылается во Flutter из setupMethodChannels(for:),
  // как только контроллер станет доступен.
  private var pendingToken: String?

  // По той же причине (SceneDelegate/FlutterViewController может быть ещё
  // не готов) кэшируем статус ATT, если он получен слишком рано.
  private var pendingAttStatus: String?

  // Чтобы не дёргать системный диалог ATT на каждый applicationDidBecomeActive
  // (при возврате из бэкграунда), запрашиваем его только один раз за жизнь
  // процесса.
  private var didRequestTrackingAuthorization = false
  
  // MARK: - UIApplicationDelegate
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
  ) -> Bool {
    
    // Firebase
    configureFirebase()
    
    // Уведомления
    configureUserNotifications(for: application)
    
    // Flutter + MethodChannels
    if let flutterViewController = flutterViewController {
      setupMethodChannels(for: flutterViewController)
    }
    
    // Регистрация плагинов Flutter теперь выполняется в SceneDelegate,
    // на реальном FlutterEngine (см. SceneDelegate.swift).
    
    // AppsFlyer инициализация
    configureAppsFlyer()
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  override func applicationDidBecomeActive(_ application: UIApplication) {
    guard !didRequestTrackingAuthorization else {
      // ATT уже запрашивали в этом запуске — просто стартуем AppsFlyer.
      AppsFlyerLib.shared().start()
      return
    }
    didRequestTrackingAuthorization = true

    requestTrackingAuthorization { [weak self] in
      // Старт AppsFlyer SDK — после того, как пользователь ответил на ATT
      // (или если ATT недоступен/не нужен на этой версии iOS).
      AppsFlyerLib.shared().start()
      _ = self
    }
  }

  // MARK: - App Tracking Transparency

  // Человекочитаемое имя статуса ATT вместо「голого」rawValue — и для
  // print() в Xcode, и для значения, которое уходит во Flutter.
  private func attStatusName(_ status: ATTrackingManager.AuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown(\(status.rawValue))"
    }
  }

  // Отправляем статус ATT во Flutter тем же способом и через тот же канал
  // (com.example.fcm/push), что и FCM-токен — единая точка вывода
  // нативных данных во Flutter.
  private func sendAttStatusToFlutter(status: String) {
    guard let controller = flutterViewController else {
      pendingAttStatus = status
      return
    }
    pendingAttStatus = nil

    if fcmPushDataChannel == nil {
      fcmPushDataChannel = FlutterMethodChannel(
        name: ChannelName.fcmPushData,
        binaryMessenger: controller.binaryMessenger
      )
    }

    print("[ATT] Отправляем статус во Flutter: \(status)")
    fcmPushDataChannel?.invokeMethod("setPushData", arguments: ["att_status": status])
  }

  private func requestTrackingAuthorization(completion: @escaping () -> Void) {
    guard #available(iOS 14, *) else {
      print("[ATT] ATT недоступен на этой версии iOS.")
      sendAttStatusToFlutter(status: "unavailable_ios_version")
      completion()
      return
    }

    let currentStatus = ATTrackingManager.trackingAuthorizationStatus
    let currentStatusName = attStatusName(currentStatus)
    print("[ATT] Текущий статус трекинга (native): \(currentStatusName)")
    sendAttStatusToFlutter(status: currentStatusName)

    guard currentStatus == .notDetermined else {
      completion()
      return
    }

    // Небольшая задержка помогает iOS корректно показать системный диалог
    // сразу после активации приложения.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      ATTrackingManager.requestTrackingAuthorization { [weak self] status in
        DispatchQueue.main.async {
          let statusName = self?.attStatusName(status) ?? "unknown(\(status.rawValue))"
          print("[ATT] Результат запроса разрешения (native): \(statusName)")
          self?.sendAttStatusToFlutter(status: statusName)
          completion()
        }
      }
    }
  }
  
  // MARK: - Universal Links (OneLink / AppsFlyer)
  //
  // ВАЖНО:
  //  - НИГДЕ не открываем браузер / не вызываем openURL.
  //  - Только прокидываем userActivity в Flutter и AppsFlyer.
  //  - Возврат в браузер происходит, как правило, из Flutter‑кода
  //    (launchUrl / WebView по самому OneLink‑URL). Там это и нужно отключить.
  
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    
    let url = userActivity.webpageURL
    print("UL received in AppDelegate: \(url?.absoluteString ?? "no url")")
    
    // 1. Даем шанс Flutter/плагинам
    let flutterHandled = super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
    print("Flutter handled UL: \(flutterHandled)")
    
    // 2. Передаём Universal Link в AppsFlyer
    AppsFlyerLib.shared().continue(userActivity, restorationHandler: nil)
    print("UL forwarded to AppsFlyer")
    
    // 3. Если это наш OneLink‑домен, явно говорим iOS, что обработали
    if let host = url?.host, host == "app.appdata.winurban.club" {
      // Даже если Flutter вернул false — считаем UL обработанным,
      // чтобы iOS не пыталась открыть что‑то ещё.
      return true
    }
    
    // Для остальных доменов возвращаем флаг Flutter
    return flutterHandled
  }
  
  // MARK: - Firebase / FCM
  
  private func configureFirebase() {
    FirebaseApp.configure()
    Messaging.messaging().delegate = self
  }
  
  // MARK: - Notifications
  
  private func configureUserNotifications(for application: UIApplication) {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    
    let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
    center.requestAuthorization(options: authOptions) { [weak self] granted, error in
      if let error = error {
        print("Ошибка при запросе разрешений: \(error.localizedDescription)")
        return
      }
      
      print("Разрешение на уведомления: \(granted)")
      
      guard granted else { return }
      
      DispatchQueue.main.async {
        application.registerForRemoteNotifications()
      }
      
      Messaging.messaging().token { token, error in
        if let error = error {
          print("Ошибка получения FCM токена: \(error.localizedDescription)")
        } else if let token = token {
          print("FCM токен: \(token)")
          self?.sendTokenToFlutter(token: token)
        }
      }
    }
  }
  
  // MARK: - Method Channels (Flutter)
  
  func setupMethodChannels(for controller: FlutterViewController) {
    self.flutterViewController = controller

    // Общий канал приложения
    appMethodChannel = FlutterMethodChannel(
      name: ChannelName.app,
      binaryMessenger: controller.binaryMessenger
    )
    
    appMethodChannel?.setMethodCallHandler { [weak self] call, result in
      // Пока ничего не обрабатываем на native‑стороне
      result(FlutterMethodNotImplemented)
      _ = self
    }
    
    // Канал FCM токена
    fcmTokenChannel = FlutterMethodChannel(
      name: ChannelName.fcmToken,
      binaryMessenger: controller.binaryMessenger
    )
    
    // Канал уведомлений (onMessage, onNotificationTap)
    fcmNotificationChannel = FlutterMethodChannel(
      name: ChannelName.fcmNotification,
      binaryMessenger: controller.binaryMessenger
    )
    
    // Канал "сырых" push‑данных
    fcmPushDataChannel = FlutterMethodChannel(
      name: ChannelName.fcmPushData,
      binaryMessenger: controller.binaryMessenger
    )
    
    // Канал диплинков AppsFlyer
    appsFlyerDeepLinkChannel = FlutterMethodChannel(
      name: appsFlyerDeepLinkChannelName,
      binaryMessenger: controller.binaryMessenger
    )

    // Если FCM-токен уже приходил раньше (до готовности контроллера),
    // отправляем его во Flutter сейчас, через com.example.fcm/push.
    if let token = pendingToken {
      sendTokenToFlutter(token: token)
    }

    // То же самое для статуса ATT, если он тоже пришёл раньше.
    if let attStatus = pendingAttStatus {
      sendAttStatusToFlutter(status: attStatus)
    }
  }
  
  // MARK: - FCM token
  
  private func sendTokenToFlutter(token: String) {
    guard let controller = flutterViewController else {
      // Контроллер ещё не готов — запомним токен и отправим его из
      // setupMethodChannels(for:), как только SceneDelegate его передаст.
      pendingToken = token
      return
    }
    pendingToken = nil

    // Токен отправляется во Flutter только через канал "сырых" push-данных
    // (com.example.fcm/push) — единая точка входа для SendRawData и
    // локального хранилища на стороне Flutter. Канал com.example.fcm/token
    // (setToken/getToken) больше не используется как источник токена.
    if fcmPushDataChannel == nil {
      fcmPushDataChannel = FlutterMethodChannel(
        name: ChannelName.fcmPushData,
        binaryMessenger: controller.binaryMessenger
      )
    }

    fcmPushDataChannel?.invokeMethod("setPushData", arguments: ["token": token])
  }
  
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    print("FCM токен обновлён: \(String(describing: fcmToken))")
    if let token = fcmToken {
      sendTokenToFlutter(token: token)
    }
  }
  
  // MARK: - APNs Token
  
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }
  
  // MARK: - Helper: отправка полного userInfo пуша во Flutter
  
  private func sendRawPushDataToFlutter(userInfo: [AnyHashable: Any]) {
    guard let controller = flutterViewController else {
      return
    }
    
    if fcmPushDataChannel == nil {
      fcmPushDataChannel = FlutterMethodChannel(
        name: ChannelName.fcmPushData,
        binaryMessenger: controller.binaryMessenger
      )
    }
    
    var normalized: [String: Any] = [:]
    for (key, value) in userInfo {
      let k = String(describing: key)
      normalized[k] = value
    }
    
    print("Отправляем полные push‑данные во Flutter: \(normalized)")
    fcmPushDataChannel?.invokeMethod("setPushData", arguments: normalized)
  }
  
  // MARK: - Foreground notification
  
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    print("Пуш в foreground: \(userInfo)")
    
    // только сохраняем данные во Flutter (для поля push), НИЧЕГО не открываем
    sendRawPushDataToFlutter(userInfo: userInfo)
    
    if let controller = flutterViewController {
      if fcmNotificationChannel == nil {
        fcmNotificationChannel = FlutterMethodChannel(
          name: ChannelName.fcmNotification,
          binaryMessenger: controller.binaryMessenger
        )
      }
      fcmNotificationChannel?.invokeMethod("onMessage", arguments: userInfo)
    }
    
    completionHandler([[.alert, .sound, .badge]])
  }
  
  // MARK: - Notification tap
  
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    print("Тап по пушу: \(userInfo)")
    
    // 1. Полная push‑data → Flutter, чтобы она попала в NcupLastPushData
    sendRawPushDataToFlutter(userInfo: userInfo)
    
    // 2. Извлекаем title/body/uri для onNotificationTap
    let aps = userInfo["aps"] as? [String: Any]
    let alert = aps?["alert"] as? [String: Any]
    let title = alert?["title"] as? String ?? "Без заголовка"
    let body = alert?["body"] as? String ?? "Без текста"
    let uri = userInfo["uri"] as? String ?? "Нет URI"
    
    let notificationData: [String: Any] = [
      "title": title,
      "body": body,
      "uri": uri,
      "data": userInfo
    ]
    
    if let controller = flutterViewController {
      if fcmNotificationChannel == nil {
        fcmNotificationChannel = FlutterMethodChannel(
          name: ChannelName.fcmNotification,
          binaryMessenger: controller.binaryMessenger
        )
      }
      
      // Во Flutter решается, что показывать, какие экраны/вебы открывать
      fcmNotificationChannel?.invokeMethod("onNotificationTap", arguments: notificationData)
    }
    
    completionHandler()
  }
  
  // MARK: - Background remote notification
  
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable : Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    print("Пуш в background (silent / content-available): \(userInfo)")
    
    // Только передаём данные во Flutter, ничего не открываем.
    sendRawPushDataToFlutter(userInfo: userInfo)
    
    guard let controller = flutterViewController else {
      completionHandler(.noData)
      return
    }
    
    if appMethodChannel == nil {
      appMethodChannel = FlutterMethodChannel(
        name: ChannelName.app,
        binaryMessenger: controller.binaryMessenger
      )
    }
    
    appMethodChannel?.invokeMethod(
      "handleMessageBackground",
      arguments: ["raw": userInfo]
    ) { _ in
      completionHandler(.newData)
    }
  }
  
  // MARK: - AppsFlyer: конфиг и делегаты
  
  private func configureAppsFlyer() {
    let af = AppsFlyerLib.shared()
    af.appsFlyerDevKey = appsFlyerDevKey
    af.appleAppID = appleAppID
    af.delegate = self
    af.isDebug = true    // выключи в релизе
  }
  
  // Установка/первый запуск, атрибуция
  func onConversionDataSuccess(_ conversionInfo: [AnyHashable : Any]) {
    debugPrint("AF conversion data: \(conversionInfo)")
    handleAppsFlyerDeepLinkData(conversionInfo)
  }
  
  func onConversionDataFail(_ error: Error) {
    debugPrint("AF conversion data error: \(error)")
  }
  
  // Открытие по OneLink, когда приложение уже установлено
  func onAppOpenAttribution(_ attributionData: [AnyHashable : Any]) {
    debugPrint("AF open attribution: \(attributionData)")
    handleAppsFlyerDeepLinkData(attributionData)
  }
  
  func onAppOpenAttributionFailure(_ error: Error) {
    debugPrint("AF open attribution error: \(error)")
  }
  
  // MARK: - Отправка диплинков AppsFlyer во Flutter
  
  private func handleAppsFlyerDeepLinkData(_ data: [AnyHashable: Any]) {
    // Основной ключ: deep_link_value (из OneLink шаблона)
    
    var payload: [String: Any] = [:]
    
    if let deepLinkValue = data["deep_link_value"] as? String {
      payload["deep_link_value"] = deepLinkValue
    }
    
    // Пробрасываем raw‑данные во Flutter (ключи в String)
    var normalized: [String: Any] = [:]
    for (key, value) in data {
      let k = String(describing: key)
      normalized[k] = value
    }
    payload["raw"] = normalized
    
    guard let controller = flutterViewController else {
      return
    }
    
    if appsFlyerDeepLinkChannel == nil {
      appsFlyerDeepLinkChannel = FlutterMethodChannel(
        name: appsFlyerDeepLinkChannelName,
        binaryMessenger: controller.binaryMessenger
      )
    }
    
    print("Sending AppsFlyer deep link payload to Flutter: \(payload)")
    appsFlyerDeepLinkChannel?.invokeMethod("onDeepLink", arguments: payload)
  }
}

