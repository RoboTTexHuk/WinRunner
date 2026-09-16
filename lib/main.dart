import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
    MethodChannel,
    SystemChrome,
    SystemUiOverlayStyle,
    MethodCall,
    VoidCallback;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;
import 'package:winrunner/pushRunner.dart';

import 'Game.dart';
import 'Load.dart';

// ============================================================================
// Константы
// ============================================================================

const String wrLoadedOnceKey = 'loaded_once';
const String wrStatEndpoint = 'https://appdata.winurban.club/stat';
const String wrCachedFcmKey = 'cached_fcm';
const String wrCachedDeepKey = 'cached_deep_push_uri';

const Set<String> wrBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> wrBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// OneLink / AppsFlyer домены — НЕ открывать во внешнем браузере
// ============================================================================

const Set<String> wrOneLinkDomains = {
  'onelink.me',
  'app.appsflyer.com',
  'appsflyer.com',
  'af-link.com',
};

/// Проверяет, является ли URL ссылкой OneLink / AppsFlyer
bool WrIsOneLinkUrl(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String domain in wrOneLinkDomains) {
    final String d = domain.toLowerCase();
    if (host == d || host.endsWith('.$d')) {
      return true;
    }
  }
  return false;
}

// ============================================================================
// Лёгкие сервисы
// ============================================================================

class WrLoggerService {
  static final WrLoggerService SharedInstance =
  WrLoggerService._InternalConstructor();

  WrLoggerService._InternalConstructor();

  factory WrLoggerService() => SharedInstance;

  final Connectivity WrConnectivity = Connectivity();

  void WrLogInfo(Object message) => print('[I] $message');
  void WrLogWarn(Object message) => print('[W] $message');
  void WrLogError(Object message) => print('[E] $message');
}

class WrNetworkService {
  final WrLoggerService WrLogger = WrLoggerService();

  Future<void> WrPostJson(
      String url,
      Map<String, dynamic> data,
      ) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (error) {
      WrLogger.WrLogError('postJson error: $error');
    }
  }
}

// ============================================================================
// Утилита: одновременное сохранение JSON в localStorage и SharedPreferences
// ============================================================================

Future<void> WrSaveJsonToLocalStorageAndPrefs({
  required InAppWebViewController? controller,
  required String key,
  required Map<String, dynamic> data,
}) async {
  final String jsonString = jsonEncode(data);

  if (controller != null) {
    try {
      await controller.evaluateJavascript(
        source: "localStorage.setItem('$key', JSON.stringify($jsonString));",
      );
    } catch (e, st) {
      WrLoggerService()
          .WrLogError('WrSaveJsonToLocalStorageAndPrefs localStorage error: $e\n$st');
    }
  }

  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonString);
  } catch (e, st) {
    WrLoggerService()
        .WrLogError('WrSaveJsonToLocalStorageAndPrefs prefs error: $e\n$st');
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================

class WrDeviceProfile {
  String? WrDeviceId;
  String? WrSessionId = '';
  String? WrPlatformName;
  String? WrOsVersion;
  String? WrAppVersion;
  String? WrLanguageCode;
  String? WrTimezoneName;
  bool WrPushEnabled = false;

  bool WrSafeAreaEnabled = false;
  String? WrSafeAreaColor;

  bool safecasher = false;

  String? WrBaseUserAgent;

  Map<String, dynamic>? WrLastPushData;

  Map<String, dynamic>? WrSavels;

  Future<void> WrInitialize() async {
    final DeviceInfoPlugin wrDeviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo wrAndroidInfo = await wrDeviceInfoPlugin.androidInfo;
      WrDeviceId = wrAndroidInfo.id;
      WrPlatformName = 'android';
      WrOsVersion = wrAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo wrIosInfo = await wrDeviceInfoPlugin.iosInfo;
      WrDeviceId = wrIosInfo.identifierForVendor;
      WrPlatformName = 'ios';
      WrOsVersion = wrIosInfo.systemVersion;
    }

    final PackageInfo wrPackageInfo = await PackageInfo.fromPlatform();
    WrAppVersion = wrPackageInfo.version;
    WrLanguageCode = Platform.localeName.split('_').first;
    WrTimezoneName = tz_zone.local.name;
    WrSessionId = 'test-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> WrToMap({String? fcmToken}) => <String, dynamic>{
    'fcm_token': fcmToken ?? 'missing_token',
    'device_id': WrDeviceId ?? 'missing_id',
    'app_name': 'winurban',
    'instance_id': WrSessionId ?? 'missing_session',
    'platform': WrPlatformName ?? 'missing_system',
    'os_version': WrOsVersion ?? 'missing_build',
    'app_version': '1.4.3' ?? 'missing_app',
    'language': WrLanguageCode ?? 'en',
    'timezone': WrTimezoneName ?? 'UTC',
    'push_enabled': WrPushEnabled,
    'safe_area_native': WrSafeAreaEnabled,
    'useragent': WrBaseUserAgent ?? 'unknown_useragent',
    'savels': WrSavels ?? <String, dynamic>{},
    'fpscashier': safecasher,
  };
}

// ============================================================================
// AppsFlyer Spy
// ============================================================================

class WrAnalyticsSpyService {
  appsflyer_core.AppsFlyerOptions? WrAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? WrAppsFlyerSdk;

  String WrAppsFlyerUid = '';
  String WrAppsFlyerData = '';

  Map<String, dynamic>? WrAppsFlyerOneLinkData;

  void WrStartTracking({VoidCallback? onUpdate}) {
    final appsflyer_core.AppsFlyerOptions wrConfig =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6812799848',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    WrAppsFlyerOptions = wrConfig;
    WrAppsFlyerSdk = appsflyer_core.AppsflyerSdk(wrConfig);

    WrAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    WrAppsFlyerSdk?.startSDK(
      onSuccess: () =>
          WrLoggerService().WrLogInfo('RetroCarAnalyticsSpy started'),
      onError: (int code, String msg) =>
          WrLoggerService().WrLogError('RetroCarAnalyticsSpy error $code: $msg'),
    );

    WrAppsFlyerSdk?.onInstallConversionData((dynamic value) {
      WrAppsFlyerData = value.toString();
      onUpdate?.call();
    });

    WrAppsFlyerSdk?.getAppsFlyerUID().then((dynamic value) {
      WrAppsFlyerUid = value.toString();
      onUpdate?.call();
    });
  }

  void WrSetOneLinkData(Map<String, dynamic> data) {
    WrAppsFlyerOneLinkData = data;
    WrLoggerService()
        .WrLogInfo('WrAnalyticsSpyService: OneLink data updated: $data');
  }
}

// ============================================================================
// FCM фон
// ============================================================================

@pragma('vm:entry-point')
Future<void> WrFcmBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  WrLoggerService().WrLogInfo('bg-fcm: ${message.messageId}');
  WrLoggerService().WrLogInfo('bg-data: ${message.data}');

  final dynamic wrLink = message.data['uri'];
  if (wrLink != null) {
    try {
      final SharedPreferences wrPrefs = await SharedPreferences.getInstance();
      await wrPrefs.setString(
        wrCachedDeepKey,
        wrLink.toString(),
      );
    } catch (e) {
      WrLoggerService().WrLogError('bg-fcm save deep failed: $e');
    }
  }
}

// ============================================================================
// FCM Bridge — токен
// ============================================================================

class WrFcmBridge {
  final WrLoggerService WrLogger = WrLoggerService();

  static const MethodChannel _tokenChannel =
  MethodChannel('com.example.fcm/token');

  String? WrToken;
  final List<void Function(String)> WrTokenWaiters =
  <void Function(String)>[];

  String? get WrFcmToken => WrToken;

  Timer? _requestTimer;
  int _requestAttempts = 0;
  final int _maxAttempts = 10;

  WrFcmBridge() {
    _tokenChannel.setMethodCallHandler((MethodCall WrCall) async {
      if (WrCall.method == 'setToken') {
        final String WrTokenString = WrCall.arguments as String;
        WrLogger.WrLogInfo(
            'WrFcmBridge: got token from native channel = $WrTokenString');
        if (WrTokenString.isNotEmpty) {
          WrSetToken(WrTokenString);
        }
      }
    });

    WrRestoreToken();
    _requestNativeToken();
    _startRequestTimer();
  }

  Future<void> _requestNativeToken() async {
    try {
      WrLogger.WrLogInfo('WrFcmBridge: request native getToken()');
      final String? token =
      await _tokenChannel.invokeMethod<String>('getToken');
      if (token != null && token.isNotEmpty) {
        WrLogger.WrLogInfo('WrFcmBridge: native getToken() returns $token');
        WrSetToken(token);
      } else {
        WrLogger.WrLogWarn('WrFcmBridge: native getToken() returned empty');
      }
    } catch (e) {
      WrLogger.WrLogWarn('WrFcmBridge: getToken invoke error: $e');
    }
  }

  void _startRequestTimer() {
    _requestTimer?.cancel();
    _requestAttempts = 0;

    _requestTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      if ((WrToken ?? '').isNotEmpty) {
        WrLogger.WrLogInfo(
            'WrFcmBridge: token already set, stop request timer');
        t.cancel();
        return;
      }

      if (_requestAttempts >= _maxAttempts) {
        WrLogger.WrLogWarn(
            'WrFcmBridge: max getToken attempts reached, stop timer');
        t.cancel();
        return;
      }

      _requestAttempts++;
      WrLogger.WrLogInfo(
          'WrFcmBridge: retry getToken() attempt #$_requestAttempts');
      await _requestNativeToken();
    });
  }

  Future<void> WrRestoreToken() async {
    try {
      final SharedPreferences wrPrefs = await SharedPreferences.getInstance();
      final String? wrCachedToken = wrPrefs.getString(wrCachedFcmKey);
      if (wrCachedToken != null && wrCachedToken.isNotEmpty) {
        WrLogger.WrLogInfo(
            'WrFcmBridge: restored cached token = $wrCachedToken');
        WrSetToken(wrCachedToken, notify: false);
      }
    } catch (e) {
      WrLogger.WrLogError('WrRestoreToken error: $e');
    }
  }

  Future<void> WrPersistToken(String newToken) async {
    try {
      final SharedPreferences wrPrefs = await SharedPreferences.getInstance();
      await wrPrefs.setString(wrCachedFcmKey, newToken);
    } catch (e) {
      WrLogger.WrLogError('WrPersistToken error: $e');
    }
  }

  void WrSetToken(
      String newToken, {
        bool notify = true,
      }) {
    WrToken = newToken;
    WrPersistToken(newToken);

    if (notify) {
      for (final void Function(String) wrCallback
      in List<void Function(String)>.from(WrTokenWaiters)) {
        try {
          wrCallback(newToken);
        } catch (error) {
          WrLogger.WrLogWarn('fcm waiter error: $error');
        }
      }
      WrTokenWaiters.clear();
    }
  }

  Future<void> WrWaitForToken(
      Function(String token) wrOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((WrToken ?? '').isNotEmpty) {
        wrOnToken(WrToken!);
        return;
      }

      WrTokenWaiters.add(wrOnToken);
    } catch (error) {
      WrLogger.WrLogError('WrWaitForToken error: $error');
    }
  }

  void dispose() {
    _requestTimer?.cancel();
  }
}

// ============================================================================
// Splash / Hall
// ============================================================================

class WrHall extends StatefulWidget {
  const WrHall({Key? key}) : super(key: key);

  @override
  State<WrHall> createState() => _WrHallState();
}

class _WrHallState extends State<WrHall> {
  final WrFcmBridge WrFcmBridgeInstance = WrFcmBridge();
  bool WrNavigatedOnce = false;
  Timer? WrFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    WrFcmBridgeInstance.WrWaitForToken((String wrToken) {
      WrGoToHarbor(wrToken);
    });

    WrFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => WrGoToHarbor(''),
    );
  }

  void WrGoToHarbor(String wrSignal) {
    if (WrNavigatedOnce) return;
    WrNavigatedOnce = true;
    WrFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext context) => WrHarbor(WrSignal: wrSignal),
      ),
    );
  }

  @override
  void dispose() {
    WrFallbackTimer?.cancel();
    WrFcmBridgeInstance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: WinRunnerLoadingScreen(
            backgroundAsset: 'assets/bg_city.png',
            logoAsset: 'assets/logo_winrunner.png',
            loadingText: 'Loading...',
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class WrBosunViewModel {
  final WrDeviceProfile WrDeviceProfileInstance;
  final WrAnalyticsSpyService WrAnalyticsSpyInstance;

  WrBosunViewModel({
    required this.WrDeviceProfileInstance,
    required this.WrAnalyticsSpyInstance,
  });

  Map<String, dynamic> WrDeviceMap(String? fcmToken) =>
      WrDeviceProfileInstance.WrToMap(fcmToken: fcmToken);

  Map<String, dynamic> WrAppsFlyerPayload(
      String? token, {
        String? deepLink,
      }) {
    final Map<String, dynamic> onelinkData =
        WrAnalyticsSpyInstance.WrAppsFlyerOneLinkData ?? <String, dynamic>{};

    return <String, dynamic>{
      'content': <String, dynamic>{
        'af_data': WrAnalyticsSpyInstance.WrAppsFlyerData,
        'af_id': WrAnalyticsSpyInstance.WrAppsFlyerUid,
        'fb_app_name': 'winurban',
        'app_name': 'winurban',
        'onelink': onelinkData,
        'bundle_identifier': 'com.winrunner.winraunner.winrunner',
        'app_version': '1.4.3',
        'apple_id': '6812799848',
        'fcm_token': token ?? 'no_token',
        'device_id': WrDeviceProfileInstance.WrDeviceId ?? 'no_device',
        'instance_id': WrDeviceProfileInstance.WrSessionId ?? 'no_instance',
        'platform': WrDeviceProfileInstance.WrPlatformName ?? 'no_type',
        'os_version': WrDeviceProfileInstance.WrOsVersion ?? 'no_os',
        'language': WrDeviceProfileInstance.WrLanguageCode ?? 'en',
        'timezone': WrDeviceProfileInstance.WrTimezoneName ?? 'UTC',
        'push_enabled': WrDeviceProfileInstance.WrPushEnabled,
        'useruid': WrAnalyticsSpyInstance.WrAppsFlyerUid,
        'safearea': WrDeviceProfileInstance.WrSafeAreaEnabled,
        'safearea_color': WrDeviceProfileInstance.WrSafeAreaColor ?? '',
        'useragent':
        WrDeviceProfileInstance.WrBaseUserAgent ?? 'unknown_useragent',
        'push': WrDeviceProfileInstance.WrLastPushData ?? <String, dynamic>{},
        'deep': deepLink,
        'fpscashier': WrDeviceProfileInstance.safecasher,
      },
    };
  }
}

class WrCourierService {
  final WrBosunViewModel WrBosun;
  final InAppWebViewController? Function() WrGetWebViewController;

  WrCourierService({
    required this.WrBosun,
    required this.WrGetWebViewController,
  });

  Future<InAppWebViewController?> _waitForController({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final WrLoggerService logger = WrLoggerService();
    final DateTime start = DateTime.now();

    while (DateTime.now().difference(start) < timeout) {
      final InAppWebViewController? c = WrGetWebViewController();
      if (c != null) {
        return c;
      }
      await Future<void>.delayed(interval);
    }

    logger.WrLogWarn('_waitForController: timeout, controller is still null');
    return null;
  }

  Future<void> WrPutDeviceToLocalStorage(String? token) async {
    final InAppWebViewController? wrController = await _waitForController();
    if (wrController == null) return;

    final Map<String, dynamic> wrMap = WrBosun.WrDeviceMap(token);
    WrLoggerService().WrLogInfo("applocal (${jsonEncode(wrMap)});");

    await WrSaveJsonToLocalStorageAndPrefs(
      controller: wrController,
      key: 'app_data',
      data: wrMap,
    );
  }

  Future<void> WrSendRawToPage(
      String? token, {
        String? deepLink,
      }) async {
    final InAppWebViewController? wrController = await _waitForController();
    if (wrController == null) return;

    final Map<String, dynamic> wrPayload =
    WrBosun.WrAppsFlyerPayload(token, deepLink: deepLink);

    final String wrJsonString = jsonEncode(wrPayload);

    WrLoggerService().WrLogInfo('SendRawData: $wrJsonString');

    final String jsSafeJson = jsonEncode(wrJsonString);
    final String jsCode = 'sendRawData($jsSafeJson);';

    try {
      await wrController.evaluateJavascript(source: jsCode);
    } catch (e, st) {
      WrLoggerService()
          .WrLogError('WrSendRawToPage evaluateJavascript error: $e\n$st');
    }
  }
}

// ============================================================================
// Статистика
// ============================================================================

Future<String> WrResolveFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient wrHttpClient = HttpClient();

  try {
    Uri wrCurrentUri = Uri.parse(startUrl);

    for (int wrIndex = 0; wrIndex < maxHops; wrIndex++) {
      final HttpClientRequest wrRequest = await wrHttpClient.getUrl(wrCurrentUri);
      wrRequest.followRedirects = false;
      final HttpClientResponse wrResponse = await wrRequest.close();

      if (wrResponse.isRedirect) {
        final String? wrLocationHeader =
        wrResponse.headers.value(HttpHeaders.locationHeader);
        if (wrLocationHeader == null || wrLocationHeader.isEmpty) {
          break;
        }

        final Uri wrNextUri = Uri.parse(wrLocationHeader);
        wrCurrentUri =
        wrNextUri.hasScheme ? wrNextUri : wrCurrentUri.resolveUri(wrNextUri);
        continue;
      }

      return wrCurrentUri.toString();
    }

    return wrCurrentUri.toString();
  } catch (error) {
    print('goldenLuxuryResolveFinalUrl error: $error');
    return startUrl;
  } finally {
    wrHttpClient.close(force: true);
  }
}

Future<void> WrPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final String wrResolvedUrl = await WrResolveFinalUrl(url);

    final Map<String, dynamic> wrPayload = <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': wrResolvedUrl,
      'appleID': '6812799848',
      'open_count': '$appSid/$timeStart',
    };

    print('goldenLuxuryStat $wrPayload');

    final http.Response wrResponse = await http.post(
      Uri.parse('$wrStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(wrPayload),
    );

    print(
        'goldenLuxuryStat resp=${wrResponse.statusCode} body=${wrResponse.body}');
  } catch (error) {
    print('goldenLuxuryPostStat error: $error');
  }
}

// ============================================================================
// Принудительный https для любых http-ссылок
// ============================================================================

bool WrShouldForceHttps(Uri uri) {
  return uri.scheme == 'http';
}

Uri WrForceHttps(Uri uri) => uri.replace(scheme: 'https');

// ============================================================================
// Открытие неизвестных кастомных схем (otpauth, otpauth-migration и т.п.)
// во внешнем приложении
// ============================================================================

Future<bool> WrTryOpenUnknownSchemeExternally(Uri uri) async {
  try {
    final bool can = await canLaunchUrl(uri);
    if (!can) {
      print('WrTryOpenUnknownSchemeExternally: no handler for $uri');
      return false;
    }
    final bool ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    print('WrTryOpenUnknownSchemeExternally: launched=$ok uri=$uri');
    return ok;
  } catch (e) {
    print('WrTryOpenUnknownSchemeExternally error: $e; uri=$uri');
    return false;
  }
}

bool WrIsCancelledLoadError({String? description, dynamic type}) {
  final String desc = (description ?? '').toLowerCase();
  final String typeString = (type?.toString() ?? '').toLowerCase();
  return desc.contains('-999') ||
      desc.contains('cancelled') ||
      desc.contains('canceled') ||
      typeString.contains('cancelled') ||
      typeString.contains('canceled');
}

// ============================================================================
// Банковские утилиты
// ============================================================================

bool WrIsBankScheme(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  return wrBankSchemes.contains(scheme);
}

bool WrIsBankDomain(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String bank in wrBankDomains) {
    final String bankHost = bank.toLowerCase();
    if (host == bankHost || host.endsWith('.$bankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> WrOpenBank(Uri uri) async {
  try {
    if (WrIsBankScheme(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        WrIsBankDomain(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }
  } catch (e) {
    print('WrOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// Главный WebView — Harbor
// ============================================================================

class WrHarbor extends StatefulWidget {
  final String? WrSignal;

  const WrHarbor({super.key, required this.WrSignal});

  @override
  State<WrHarbor> createState() => _WrHarborState();
}

class _WrHarborState extends State<WrHarbor> with WidgetsBindingObserver {
  InAppWebViewController? WrWebViewController;

  InAppWebViewController? WrPopupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;

  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  bool _isOpeningExternalNewTab = false;
  final Set<String> _handledNewTabUrls = <String>{};

  Timer? _parentInstallTimer;
  Timer? _popupInstallTimer;

  final String WrHomeUrl = 'https://appdata.winurban.club/';

  int WrWebViewKeyCounter = 0;
  DateTime? WrSleepAt;
  bool WrVeilVisible = false;
  double WrWarmProgress = 0.0;
  late Timer WrWarmTimer;
  final int WrWarmSeconds = 6;
  bool WrCoverVisible = true;

  bool WrLoadedOnceSent = false;
  int? WrFirstPageTimestamp;

  WrCourierService? WrCourier;
  WrBosunViewModel? WrBosunInstance;

  String WrCurrentUrl = '';
  int WrStartLoadTimestamp = 0;

  final WrDeviceProfile WrDeviceProfileInstance = WrDeviceProfile();
  final WrAnalyticsSpyService WrAnalyticsSpyInstance = WrAnalyticsSpyService();

  final Set<String> WrSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  final Set<String> WrExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  String? WrDeepLinkFromPush;

  // FCM-токен, полученный ТОЛЬКО через канал com.example.fcm/push
  // (AppDelegate.sendTokenToFlutter -> fcmPushDataChannel setPushData).
  // Именно это значение используется для записи в SendRawData и в
  // локальное хранилище — канал com.example.fcm/token для этого больше
  // не используется.
  String? _pushChannelToken;

  String? _baseUserAgent;
  String _currentUserAgent = "";
  String? _currentUrl;

  String? _serverUserAgent;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = const Color(0xFF000000);

  bool _startupSendRawDone = false;

  String? _pendingLoadedJs;

  bool _loadedJsExecutedOnce = false;

  bool _isInGoogleAuth = false;

  List<String> _buttonWhitelist = <String>[];
  bool _showBackButton = false;

  bool _backButtonHiddenAfterTap = false;

  bool _isCurrentlyOnGoogle = false;

  static const MethodChannel _appsFlyerDeepLinkChannel =
  MethodChannel('appsflyer_deeplink_channel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WrFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;
    _currentUrl = WrHomeUrl;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          WrCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        WrVeilVisible = true;
      });
    });

    _bindPushChannelFromAppDelegate();
    _bindAppsFlyerDeepLinkChannel();
    WrBootHarbor();
  }

  bool _isAboutBlankUrl(String? value) {
    final String u = (value ?? '').trim().toLowerCase();
    return u.isEmpty || u == 'about:blank' || u.startsWith('about:blank');
  }

  bool _isAboutBlankUri(Uri? uri) => _isAboutBlankUrl(uri?.toString());

  void _bindAppsFlyerDeepLinkChannel() {
    _appsFlyerDeepLinkChannel.setMethodCallHandler(
          (MethodCall call) async {
        if (call.method == 'onDeepLink') {
          try {
            final dynamic args = call.arguments;

            Map<String, dynamic> payload;

            print(" Data Deepl link ${args.toString()}");
            if (args is Map) {
              payload = Map<String, dynamic>.from(args as Map);
            } else if (args is String) {
              payload = jsonDecode(args) as Map<String, dynamic>;
            } else {
              payload = <String, dynamic>{'raw': args.toString()};
            }

            WrLoggerService().WrLogInfo(
              'AppsFlyer onDeepLink from iOS: $payload',
            );

            final dynamic raw = payload['raw'];
            if (raw is Map) {
              final Map<String, dynamic> normalized =
              Map<String, dynamic>.from(raw as Map);

              print("One Link Data $normalized");
              WrAnalyticsSpyInstance.WrSetOneLinkData(normalized);

              // === OneLink: извлекаем deep_link_value и навигируем внутри ===
              _handleOneLinkDeepNavigation(normalized);
            } else {
              WrAnalyticsSpyInstance.WrSetOneLinkData(payload);
              _handleOneLinkDeepNavigation(payload);
            }
          } catch (e, st) {
            WrLoggerService().WrLogError('Error in onDeepLink handler: $e\n$st');
          }
        }
      },
    );
  }

  /// Обработка OneLink deep link — навигация внутри WebView, а не во внешний браузер
  void _handleOneLinkDeepNavigation(Map<String, dynamic> data) {
    try {
      // Пытаемся извлечь URL для навигации из OneLink данных
      String? targetUrl;

      // deep_link_value — стандартное поле AppsFlyer OneLink
      if (data.containsKey('deep_link_value') &&
          data['deep_link_value'] != null) {
        final String dlv = data['deep_link_value'].toString().trim();
        if (dlv.startsWith('http://') || dlv.startsWith('https://')) {
          targetUrl = dlv;
        }
      }

      // af_dp — ещё одно стандартное поле
      if (targetUrl == null && data.containsKey('af_dp') && data['af_dp'] != null) {
        final String afDp = data['af_dp'].toString().trim();
        if (afDp.startsWith('http://') || afDp.startsWith('https://')) {
          targetUrl = afDp;
        }
      }

      // link — может быть финальным URL
      if (targetUrl == null && data.containsKey('link') && data['link'] != null) {
        final String link = data['link'].toString().trim();
        if (link.startsWith('http://') || link.startsWith('https://')) {
          targetUrl = link;
        }
      }

      // clickURL
      if (targetUrl == null &&
          data.containsKey('clickURL') &&
          data['clickURL'] != null) {
        final String clickUrl = data['clickURL'].toString().trim();
        if (clickUrl.startsWith('http://') || clickUrl.startsWith('https://')) {
          targetUrl = clickUrl;
        }
      }

      if (targetUrl != null && targetUrl.isNotEmpty) {
        WrLoggerService()
            .WrLogInfo('OneLink deep navigation: loading $targetUrl in WebView');
        WrDeepLinkFromPush = targetUrl;

        // Навигируем внутри WebView
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          WrNavigateToUri(targetUrl!);
        });
      } else {
        WrLoggerService().WrLogInfo(
            'OneLink deep navigation: no target URL found in data, '
                'sending data to page via sendRawData');
      }
    } catch (e, st) {
      WrLoggerService().WrLogError('_handleOneLinkDeepNavigation error: $e\n$st');
    }
  }

  void _bindPushChannelFromAppDelegate() {
    // ВАЖНО: сам MethodChannel('com.example.fcm/push') слушается ГЛОБАЛЬНО —
    // через gWrBindPushChannel(), вызванный один раз в main(), ещё до
    // runApp(). Установка здесь СВОЕГО обработчика на этом же канале —
    // опасная ошибка: setMethodCallHandler на канале с тем же именем просто
    // вытесняет предыдущий обработчик, а если этот экран (WrHarbor) ещё не
    // успел смонтироваться, самый ранний вызов из AppDelegate (например,
    // токен при холодном старте) потеряется, т.к. на канале ещё не было
    // вообще никакого обработчика.
    //
    // Поэтому здесь мы только подписываемся на колбэки глобального моста и
    // подхватываем то, что могло прийти раньше, чем этот экран появился.
    if (gWrLastPushData != null) {
      WrDeviceProfileInstance.WrLastPushData = gWrLastPushData;
    }

    final String? cachedUri =
        (gWrLastPushData?['uri'] ?? gWrLastPushData?['deep_link'])?.toString();
    if (cachedUri != null && cachedUri.isNotEmpty) {
      WrDeepLinkFromPush = cachedUri;
    }

    gWrOnPushToken = (String token) {
      if (!mounted) return;
      _pushChannelToken = token;
      WrLoggerService().WrLogInfo(
          'WrHarbor: применяем FCM-токен из com.example.fcm/push: $token');

      // Токен пришёл через com.example.fcm/push — это единственный
      // источник для SendRawData и локального хранилища.
      WrPushDeviceInfo();
      WrPushAppsFlyerData();
    };

    gWrOnPushUri = (String uri) async {
      WrDeepLinkFromPush = uri;
      await WrSaveCachedDeep(uri);
    };

    // Токен уже мог прийти ДО того, как этот экран смонтировался —
    // подхватываем его сразу, не дожидаясь следующего push.
    if (gWrPushToken != null && gWrPushToken!.isNotEmpty) {
      _pushChannelToken = gWrPushToken;
      WrPushDeviceInfo();
      WrPushAppsFlyerData();
    }
  }

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google.com') ||
        full.contains('accounts.google.') ||
        full.contains('googleusercontent.com') ||
        full.contains('gstatic.com');
  }

  Future<void> _applyGoogleUserAgent() async {
    if (WrWebViewController == null) return;

    const String googleUa = 'random';

    if (_currentUserAgent == googleUa) {
      WrLoggerService().WrLogInfo('[UA] Already set to "random" for Google, skip');
      return;
    }

    WrLoggerService()
        .WrLogInfo('[UA] Applying GOOGLE User-Agent: $googleUa');

    try {
      await WrWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      _currentUserAgent = googleUa;
      _isCurrentlyOnGoogle = true;
      print('[UA] GOOGLE WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      WrLoggerService().WrLogError('Error setting Google User-Agent: $e');
    }
  }

  Future<void> _applyGoogleUserAgentForPopup() async {
    if (WrPopupWebViewController == null) return;

    const String googleUa = 'random';

    WrLoggerService()
        .WrLogInfo('[UA] Applying GOOGLE User-Agent to POPUP: $googleUa');

    try {
      await WrPopupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      print('[UA] GOOGLE POPUP USER AGENT: $googleUa');
    } catch (e) {
      WrLoggerService()
          .WrLogError('Error setting Google User-Agent for popup: $e');
    }
  }

  Future<void> _updateUserAgentFromServerPayload(
      Map<dynamic, dynamic> root) async {
    String? fullua;
    String? uatail;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['fullua'] != null &&
          content['fullua'].toString().trim().isNotEmpty) {
        fullua = content['fullua'].toString().trim();
      }
      if (content['uatail'] != null &&
          content['uatail'].toString().trim().isNotEmpty) {
        uatail = content['uatail'].toString().trim();
      }
    }

    if (fullua == null &&
        root['fullua'] != null &&
        root['fullua'].toString().trim().isNotEmpty) {
      fullua = root['fullua'].toString().trim();
    }
    if (uatail == null &&
        root['uatail'] != null &&
        root['uatail'].toString().trim().isNotEmpty) {
      uatail = root['uatail'].toString().trim();
    }

    if (uatail == null) {
      final dynamic adata = root['adata'];
      if (adata is Map &&
          adata['uatail'] != null &&
          adata['uatail'].toString().trim().isNotEmpty) {
        uatail = adata['uatail'].toString().trim();
      }
    }

    await _applyUserAgent(fullua: fullua, uatail: uatail);
  }

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (WrWebViewController == null) return;

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await WrWebViewController!.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          WrDeviceProfileInstance.WrBaseUserAgent = _baseUserAgent;
          WrLoggerService()
              .WrLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        WrLoggerService()
            .WrLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      WrLoggerService()
          .WrLogWarn('Base User-Agent is still null/empty, skip UA update');
      return;
    }

    WrLoggerService().WrLogInfo(
        'Server UA payload: fullua="$fullua", uatail="$uatail", base="$_baseUserAgent"');

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = "${_baseUserAgent!}";
    }

    _serverUserAgent = newUa;
    WrLoggerService()
        .WrLogInfo('Server UA calculated and stored: $_serverUserAgent');
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (WrWebViewController == null) return;

    if (_isCurrentlyOnGoogle) {
      WrLoggerService()
          .WrLogInfo('[UA] Currently on Google page, keeping "random" UA');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) {
      WrLoggerService()
          .WrLogInfo('Normal UA unchanged, keeping: $_currentUserAgent');
      return;
    }

    WrLoggerService()
        .WrLogInfo('Applying NORMAL WebView User-Agent: $targetUa');

    try {
      await WrWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      print('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      WrLoggerService().WrLogError(
          'Error while setting normal User-Agent "$targetUa": $e');
    }
  }

  Future<void> _switchUserAgentForUrl(Uri? uri) async {
    if (uri == null) return;

    if (_isGoogleUrl(uri)) {
      _isCurrentlyOnGoogle = true;
      await _applyGoogleUserAgent();
    } else {
      if (_isCurrentlyOnGoogle) {
        _isCurrentlyOnGoogle = false;
      }
      await _applyNormalUserAgentIfNeeded();
    }
  }

  Future<void> printJsUserAgent() async {
    if (WrWebViewController == null) return;

    try {
      final ua = await WrWebViewController!.evaluateJavascript(
        source: "navigator.userAgent",
      );

      if (ua is String) {
        print('[JS UA] navigator.userAgent = $ua');
      } else {
        print('[JS UA] navigator.userAgent (non-string) = $ua');
      }
    } catch (e, st) {
      print('Error reading navigator.userAgent: $e\n$st');
    }
  }

  Future<void> debugPrintCurrentUserAgent() async {
    WrLoggerService()
        .WrLogInfo('[STATE UA] _currentUserAgent = $_currentUserAgent');
    await printJsUserAgent();
  }

  Future<void> WrLoadLoadedFlag() async {
    final SharedPreferences wrPrefs = await SharedPreferences.getInstance();
    WrLoadedOnceSent = wrPrefs.getBool(wrLoadedOnceKey) ?? false;
  }

  Future<void> WrSaveLoadedFlag() async {
    final SharedPreferences wrPrefs = await SharedPreferences.getInstance();
    await wrPrefs.setBool(wrLoadedOnceKey, true);
    WrLoadedOnceSent = true;
  }

  Future<void> WrLoadCachedDeep() async {
    try {
      final SharedPreferences wrPrefs = await SharedPreferences.getInstance();
      final String? wrCached = wrPrefs.getString(wrCachedDeepKey);
      if ((wrCached ?? '').isNotEmpty) {
        WrDeepLinkFromPush = wrCached;
      }
    } catch (_) {}
  }

  Future<void> WrSaveCachedDeep(String uri) async {
    try {
      final SharedPreferences wrPrefs = await SharedPreferences.getInstance();
      await wrPrefs.setString(wrCachedDeepKey, uri);
    } catch (_) {}
  }

  Future<void> WrSendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (WrLoadedOnceSent) return;

    final int wrNow = DateTime.now().millisecondsSinceEpoch;

    await WrPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: wrNow,
      url: url,
      appSid: WrAnalyticsSpyInstance.WrAppsFlyerUid,
      firstPageLoadTs: WrFirstPageTimestamp,
    );

    await WrSaveLoadedFlag();
  }

  void WrBootHarbor() {
    WrStartWarmProgress();
    WrWireFcmHandlers();
    WrAnalyticsSpyInstance.WrStartTracking(
      onUpdate: () => setState(() {}),
    );
    WrBindNotificationTap();
    WrPrepareDeviceProfile();
  }

  void WrWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage wrMessage) async {
      final dynamic wrLink = wrMessage.data['uri'];
      if (wrLink != null) {
        final String wrUri = wrLink.toString();
        WrDeepLinkFromPush = wrUri;
        await WrSaveCachedDeep(wrUri);
      } else {
        WrResetHomeAfterDelay();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage wrMessage) async {
      final dynamic wrLink = wrMessage.data['uri'];
      if (wrLink != null) {
        final String wrUri = wrLink.toString();
        WrDeepLinkFromPush = wrUri;
        await WrSaveCachedDeep(wrUri);

        WrNavigateToUri(wrUri);

        await WrPushDeviceInfo();
        await WrPushAppsFlyerData();
      } else {
        WrResetHomeAfterDelay();
      }
    });
  }

  void WrBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> wrPayload =
        Map<String, dynamic>.from(call.arguments);
        final String? wrUriRaw = wrPayload['uri']?.toString();

        if (wrUriRaw != null &&
            wrUriRaw.isNotEmpty &&
            !wrUriRaw.contains('Нет URI')) {
          final String wrUri = wrUriRaw;
          WrDeepLinkFromPush = wrUri;
          await WrSaveCachedDeep(wrUri);

          if (!context.mounted) return;

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) => NcupTableView(wrUri),
            ),
                (Route<dynamic> route) => false,
          );

          await WrPushDeviceInfo();
          await WrPushAppsFlyerData();
        }
      }
    });
  }

  Future<void> WrPrepareDeviceProfile() async {
    try {
      await WrDeviceProfileInstance.WrInitialize();

      final FirebaseMessaging wrMessaging = FirebaseMessaging.instance;
      final NotificationSettings wrSettings =
      await wrMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      WrDeviceProfileInstance.WrPushEnabled =
          wrSettings.authorizationStatus == AuthorizationStatus.authorized ||
              wrSettings.authorizationStatus ==
                  AuthorizationStatus.provisional;

      await WrLoadLoadedFlag();
      await WrLoadCachedDeep();

      WrBosunInstance = WrBosunViewModel(
        WrDeviceProfileInstance: WrDeviceProfileInstance,
        WrAnalyticsSpyInstance: WrAnalyticsSpyInstance,
      );

      WrCourier = WrCourierService(
        WrBosun: WrBosunInstance!,
        WrGetWebViewController: () => WrWebViewController,
      );
    } catch (error) {
      WrLoggerService().WrLogError('prepareDeviceProfile fail: $error');
    }
  }

  void WrNavigateToUri(String link) async {
    try {
      await WrWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(link)),
      );
    } catch (error) {
      WrLoggerService().WrLogError('navigate error: $error');
    }
  }

  void WrResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        WrWebViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(WrHomeUrl)),
        );
      } catch (_) {}
    });
  }

  String? _resolveTokenForShip() {
    // Источник токена для SendRawData / локального хранилища — ТОЛЬКО
    // данные, пришедшие через com.example.fcm/push из AppDelegate
    // (см. _bindPushChannelFromAppDelegate). widget.WrSignal (канал
    // com.example.fcm/token) больше не используется как источник.
    if (_pushChannelToken != null && _pushChannelToken!.isNotEmpty) {
      return _pushChannelToken;
    }
    return null;
  }

  Future<void> _sendAllDataToPageTwice() async {
    await WrPushDeviceInfo();

    Future<void>.delayed(const Duration(seconds: 6), () async {
      await WrPushDeviceInfo();
      await WrPushAppsFlyerData();
    });
  }

  Future<void> WrPushDeviceInfo() async {
    final String? wrToken = _resolveTokenForShip();

    try {
      await WrCourier?.WrPutDeviceToLocalStorage(wrToken);
    } catch (error) {
      WrLoggerService().WrLogError('pushDeviceInfo error: $error');
    }
  }

  Future<void> WrPushAppsFlyerData() async {
    final String? wrToken = _resolveTokenForShip();

    try {
      await WrCourier?.WrSendRawToPage(
        wrToken,
        deepLink: WrDeepLinkFromPush,
      );
    } catch (error) {
      WrLoggerService().WrLogError('pushAppsFlyerData error: $error');
    }
  }

  void WrStartWarmProgress() {
    int wrTick = 0;
    WrWarmProgress = 0.0;

    WrWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
          if (!mounted) return;

          setState(() {
            wrTick++;
            WrWarmProgress = wrTick / (WrWarmSeconds * 10);

            if (WrWarmProgress >= 1.0) {
              WrWarmProgress = 1.0;
              WrWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      WrSleepAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && WrSleepAt != null) {
        final DateTime wrNow = DateTime.now();
        final Duration wrDrift = wrNow.difference(WrSleepAt!);

        if (wrDrift > const Duration(minutes: 25)) {
          WrReboardHarbor();
        }
      }
      WrSleepAt = null;
    }
  }

  void WrReboardHarbor() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) => WrHarbor(WrSignal: widget.WrSignal),
        ),
            (Route<dynamic> route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WrWarmTimer.cancel();

    _parentInstallTimer?.cancel();
    _popupInstallTimer?.cancel();

    // Отписываемся от глобального моста com.example.fcm/push, чтобы не
    // держать колбэки на уничтоженный State.
    gWrOnPushToken = null;
    gWrOnPushUri = null;

    WrWebViewController = null;
    WrPopupWebViewController = null;

    super.dispose();
  }

  bool WrIsBareEmail(Uri uri) {
    final String wrScheme = uri.scheme;
    if (wrScheme.isNotEmpty) return false;
    final String wrRaw = uri.toString();
    return wrRaw.contains('@') && !wrRaw.contains(' ');
  }

  Uri WrToMailto(Uri uri) {
    final String wrFull = uri.toString();
    final List<String> wrParts = wrFull.split('?');
    final String wrEmail = wrParts.first;
    final Map<String, String> wrQueryParams =
    wrParts.length > 1 ? Uri.splitQueryString(wrParts[1]) : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: wrEmail,
      queryParameters: wrQueryParams.isEmpty ? null : wrQueryParams,
    );
  }

  Future<bool> WrOpenMailExternal(Uri mailto) async {
    try {
      final String scheme = mailto.scheme.toLowerCase();
      final String path = mailto.path.toLowerCase();

      WrLoggerService()
          .WrLogInfo('WrOpenMailExternal: scheme=$scheme path=$path uri=$mailto');

      if (scheme != 'mailto') {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        WrLoggerService()
            .WrLogInfo('WrOpenMailExternal: non-mailto result=$ok');
        return ok;
      }

      final bool can = await canLaunchUrl(mailto);
      WrLoggerService()
          .WrLogInfo('WrOpenMailExternal: canLaunchUrl(mailto) = $can');

      if (can) {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        WrLoggerService()
            .WrLogInfo('WrOpenMailExternal: externalApplication result=$ok');
        if (ok) return true;
      }

      WrLoggerService().WrLogWarn(
          'WrOpenMailExternal: no native handler for mailto, fallback to Gmail Web');
      final Uri gmailUri = WrGmailizeMailto(mailto);
      final bool webOk = await WrOpenWeb(gmailUri);
      WrLoggerService()
          .WrLogInfo('WrOpenMailExternal: Gmail Web fallback result=$webOk');
      return webOk;
    } catch (e, st) {
      WrLoggerService()
          .WrLogError('WrOpenMailExternal error: $e\n$st; url=$mailto');
      return false;
    }
  }

  Future<bool> WrOpenMailWeb(Uri mailto) async {
    final Uri wrGmailUri = WrGmailizeMailto(mailto);
    return WrOpenWeb(wrGmailUri);
  }

  Uri WrGmailizeMailto(Uri mailUri) {
    final Map<String, String> wrQueryParams = mailUri.queryParameters;

    final Map<String, String> wrParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((wrQueryParams['subject'] ?? '').isNotEmpty)
        'su': wrQueryParams['subject']!,
      if ((wrQueryParams['body'] ?? '').isNotEmpty)
        'body': wrQueryParams['body']!,
      if ((wrQueryParams['cc'] ?? '').isNotEmpty)
        'cc': wrQueryParams['cc']!,
      if ((wrQueryParams['bcc'] ?? '').isNotEmpty)
        'bcc': wrQueryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', wrParams);
  }

  bool WrIsPlatformLink(Uri uri) {
    final String wrScheme = uri.scheme.toLowerCase();
    if (WrSpecialSchemes.contains(wrScheme)) {
      return true;
    }

    if (wrScheme == 'http' || wrScheme == 'https') {
      final String wrHost = uri.host.toLowerCase();

      if (WrExternalHosts.contains(wrHost)) {
        return true;
      }

      if (wrHost.endsWith('t.me')) return true;
      if (wrHost.endsWith('wa.me')) return true;
      if (wrHost.endsWith('m.me')) return true;
      if (wrHost.endsWith('signal.me')) return true;
      if (wrHost.endsWith('facebook.com')) return true;
      if (wrHost.endsWith('instagram.com')) return true;
      if (wrHost.endsWith('twitter.com')) return true;
      if (wrHost.endsWith('x.com')) return true;
    }

    return false;
  }

  String WrDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri WrHttpizePlatformUri(Uri uri) {
    final String wrScheme = uri.scheme.toLowerCase();

    if (wrScheme == 'tg' || wrScheme == 'telegram') {
      final Map<String, String> wrQp = uri.queryParameters;
      final String? wrDomain = wrQp['domain'];

      if (wrDomain != null && wrDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$wrDomain',
          <String, String>{
            if (wrQp['start'] != null) 'start': wrQp['start']!,
          },
        );
      }

      final String wrPath = uri.path.isNotEmpty ? uri.path : '';

      return Uri.https(
        't.me',
        '/$wrPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if ((wrScheme == 'http' || wrScheme == 'https') &&
        uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (wrScheme == 'viber') {
      return uri;
    }

    if (wrScheme == 'whatsapp') {
      final Map<String, String> wrQp = uri.queryParameters;
      final String? wrPhone = wrQp['phone'];
      final String? wrText = wrQp['text'];

      if (wrPhone != null && wrPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${WrDigitsOnly(wrPhone)}',
          <String, String>{
            if (wrText != null && wrText.isNotEmpty) 'text': wrText,
          },
        );
      }

      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (wrText != null && wrText.isNotEmpty) 'text': wrText,
        },
      );
    }

    if ((wrScheme == 'http' || wrScheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') ||
            uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (wrScheme == 'skype') {
      return uri;
    }

    if (wrScheme == 'fb-messenger') {
      final String wrPath =
      uri.pathSegments.isNotEmpty ? uri.pathSegments.join('/') : '';
      final Map<String, String> wrQp = uri.queryParameters;

      final String wrId = wrQp['id'] ?? wrQp['user'] ?? wrPath;

      if (wrId.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$wrId',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (wrScheme == 'sgnl') {
      final Map<String, String> wrQp = uri.queryParameters;
      final String? wrPhone = wrQp['phone'];
      final String? wrUsername = wrQp['username'];

      if (wrPhone != null && wrPhone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${WrDigitsOnly(wrPhone)}',
        );
      }

      if (wrUsername != null && wrUsername.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$wrUsername',
        );
      }

      final String wrPath = uri.pathSegments.join('/');
      if (wrPath.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$wrPath',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return uri;
    }

    if (wrScheme == 'tel') {
      return Uri.parse('tel:${WrDigitsOnly(uri.path)}');
    }

    if (wrScheme == 'mailto') {
      return uri;
    }

    if (wrScheme == 'bnl') {
      final String wrNewPath = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        'bnl.com',
        '/$wrNewPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    return uri;
  }

  Future<bool> WrOpenWeb(Uri uri) async {
    try {
      if (await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }

      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      try {
        return await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> WrOpenExternal(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      return false;
    }
  }

  void WrHandleServerSavedata(String savedata) {
    print('onServerResponse savedata: $savedata');

    if(savedata=='false'){
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => WinRunnerWebView(initialUrl: 'https://gamedata.winurban.club/', backgroundAsset: '', logoAsset: '',),
        ),
      );
    }
  }

  Color _parseHexColor(String hex) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) {
      value = 'FF$value';
    }
    final intColor = int.tryParse(value, radix: 16) ?? 0xFF000000;
    return Color(intColor);
  }

  Future<void> _updateAppDataInLocalStorageFromProfile() async {
    final InAppWebViewController? controller = WrWebViewController;
    if (controller == null) return;

    final String? token = _resolveTokenForShip();
    final Map<String, dynamic> map =
    WrDeviceProfileInstance.WrToMap(fcmToken: token);

    WrLoggerService()
        .WrLogInfo('updateAppDataFromProfile: ${jsonEncode(map)}');

    await WrSaveJsonToLocalStorageAndPrefs(
      controller: controller,
      key: 'app_data',
      data: map,
    );
  }

  void _updateExtraDataFromServerPayload(Map<dynamic, dynamic> root) {
    try {
      final dynamic adataRaw = root['adata'];
      if (adataRaw is Map) {
        final Map adata = adataRaw;

        final dynamic buttonswlRaw = adata['buttonswl'];
        if (buttonswlRaw is List) {
          final List<String> list = buttonswlRaw
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          setState(() {
            _buttonWhitelist = list;
          });
          WrLoggerService()
              .WrLogInfo('buttonswl updated: $_buttonWhitelist');
          _updateBackButtonVisibility();
        }

        if (adata.containsKey('fpscashier')) {
          final dynamic fpsRaw = adata['fpscashier'];
          bool? fpsValue;

          if (fpsRaw is bool) {
            fpsValue = fpsRaw;
          } else if (fpsRaw is num) {
            fpsValue = fpsRaw != 0;
          } else if (fpsRaw is String) {
            final String v = fpsRaw.toLowerCase().trim();
            if (v == 'true' || v == '1' || v == 'yes') fpsValue = true;
            if (v == 'false' || v == '0' || v == 'no') fpsValue = false;
          }

          if (fpsValue != null) {
            final bool old = WrDeviceProfileInstance.safecasher;
            WrDeviceProfileInstance.safecasher = fpsValue;
            WrLoggerService().WrLogInfo(
                'fpscashier updated from server payload: $fpsValue');

            _updateAppDataInLocalStorageFromProfile();

            if (!old && fpsValue && WrWebViewController != null) {
              WrLoggerService().WrLogInfo(
                  'fpscashier switched to true, installing JS hooks now');
              _scheduleSafeInstall(WrWebViewController!, label: 'parent');
            }
          }
        }

        final dynamic savelsRaw = adata['savels'];
        if (savelsRaw is Map) {
          WrDeviceProfileInstance.WrSavels =
          Map<String, dynamic>.from(savelsRaw);
          WrLoggerService().WrLogInfo(
              'savels stored in profile: ${WrDeviceProfileInstance.WrSavels}');
          _updateAppDataInLocalStorageFromProfile();
        }
      }
    } catch (e, st) {
      WrLoggerService()
          .WrLogError('Error in _updateExtraDataFromServerPayload: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    WrLoggerService()
        .WrLogInfo('SAFEAREA RAW PAYLOAD: ${jsonEncode(root)}');

    bool? safearea;
    String? bgLightHex;
    String? bgDarkHex;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['safearea'] != null) {
        final dynamic raw = content['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (content['safearea_color'] != null &&
          content['safearea_color'].toString().trim().isNotEmpty) {
        bgLightHex = content['safearea_color'].toString().trim();
        bgDarkHex = bgLightHex;
      }
    }

    final dynamic adata = root['adata'];
    if (adata is Map) {
      if (safearea == null && adata['safearea'] != null) {
        final dynamic raw = adata['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (adata['bgsareaw'] != null &&
          adata['bgsareaw'].toString().trim().isNotEmpty) {
        bgLightHex = adata['bgsareaw'].toString().trim();
      }
      if (adata['bgsareab'] != null &&
          adata['bgsareab'].toString().trim().isNotEmpty) {
        bgDarkHex = adata['bgsareab'].toString().trim();
      }
    }

    if (safearea == null && root['safearea'] != null) {
      final dynamic raw = root['safearea'];
      if (raw is bool) {
        safearea = raw;
      } else if (raw is String) {
        final String v = raw.toLowerCase().trim();
        if (v == 'true' || v == '1' || v == 'yes') safearea = true;
        if (v == 'false' || v == '0' || v == 'no') safearea = false;
      } else if (raw is num) {
        safearea = raw != 0;
      }
    }

    WrLoggerService().WrLogInfo(
        'SAFEAREA PARSED: enabled=$safearea, light=$bgLightHex, dark=$bgDarkHex');

    if (safearea == null) {
      return;
    }

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    final bool enabled = safearea;
    Color background =
    enabled ? const Color(0xFF1A1A22) : const Color(0xFF000000);

    if (enabled && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex);
    }

    setState(() {
      _safeAreaEnabled = enabled;
      _safeAreaBackgroundColor = background;
      WrDeviceProfileInstance.WrSafeAreaEnabled = enabled;
      WrDeviceProfileInstance.WrSafeAreaColor =
      enabled ? (chosenHex ?? '#1A1A22') : '';
    });

    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool('safearea_enabled', enabled);
        await prefs.setString(
          'safearea_color',
          WrDeviceProfileInstance.WrSafeAreaColor ?? '',
        );
        WrLoggerService().WrLogInfo(
          'SafeArea saved to prefs: enabled=$enabled, color="${WrDeviceProfileInstance.WrSafeAreaColor}"',
        );
      } catch (e, st) {
        WrLoggerService()
            .WrLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();

    WrLoggerService().WrLogInfo(
        'SAFEAREA STATE UPDATED: enabled=$_safeAreaEnabled, color=$_safeAreaBackgroundColor (brightness=$platformBrightness)');
  }

  bool _matchesButtonWhitelist(String url) {
    if (url.isEmpty) return false;
    if (_buttonWhitelist.isEmpty) return false;
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }

    final String host = uri.host.toLowerCase();
    final String full = uri.toString();

    for (final String item in _buttonWhitelist) {
      final String trimmed = item.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        if (full.startsWith(trimmed)) return true;
      } else {
        final String domain = trimmed.toLowerCase();
        if (host == domain || host.endsWith('.$domain')) return true;
      }
    }

    return false;
  }

  Future<void> _updateBackButtonVisibility() async {
    final String current = _currentUrl ?? WrCurrentUrl;
    final bool shouldShow = _matchesButtonWhitelist(current);

    if (_backButtonHiddenAfterTap) {
      _backButtonHiddenAfterTap = false;
    }

    if (shouldShow != _showBackButton) {
      if (mounted) {
        setState(() {
          _showBackButton = shouldShow;
        });
      } else {
        _showBackButton = shouldShow;
      }
    }
  }

  Future<void> _handleBackButtonPressed() async {
    if (mounted) {
      setState(() {
        _backButtonHiddenAfterTap = true;
        _showBackButton = false;
      });
    } else {
      _backButtonHiddenAfterTap = true;
      _showBackButton = false;
    }

    if (_isPopupVisible) {
      await _handlePopupBackPressed();
      return;
    }

    if (WrWebViewController == null) return;
    try {
      if (await WrWebViewController!.canGoBack()) {
        await WrWebViewController!.goBack();
      } else {
        await WrWebViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri(WrHomeUrl)),
        );
      }
    } catch (e, st) {
      WrLoggerService().WrLogError('Error on back button pressed: $e\n$st');
    }
  }

  InAppWebViewSettings _mainWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  InAppWebViewSettings _popupWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  Future<void> _safeEvaluateJavascript(
      InAppWebViewController? controller, {
        required String source,
        String debugName = 'js',
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      print('WERLOG: safeEvaluateJavascript error [$debugName]: $e');
    }
  }

  Future<void> _installJsErrorLogger(InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installJsErrorLogger',
      source: r'''
        (function() {
          if (window.__ncupJsLoggerInstalled) return;
          window.__ncupJsLoggerInstalled = true;

          function serializeError(err) {
            try {
              if (!err) return null;
              var plain = {};
              Object.getOwnPropertyNames(err).forEach(function(key) {
                plain[key] = err[key];
              });
              return plain;
            } catch (_) {
              return { message: String(err) };
            }
          }

          window.onerror = function(message, source, lineno, colno, error) {
            try {
              var payload = {
                type: 'onerror',
                message: String(message || ''),
                source: String(source || ''),
                lineno: lineno || 0,
                colno: colno || 0,
                error: serializeError(error)
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger onerror inner fail', e);
            }
          };

          window.addEventListener('unhandledrejection', function(event) {
            try {
              var reason = event.reason;
              var payload = {
                type: 'unhandledrejection',
                reason: serializeError(reason) || { message: String(reason || '') }
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger unhandledrejection inner fail', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installPostMessageBridge(
      InAppWebViewController controller, {
        required String label,
      }) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installPostMessageBridge-$label',
      source: '''
        (function() {
          if (window.__ncupPostMessageBridgeInstalled_$label) return;
          window.__ncupPostMessageBridgeInstalled_$label = true;

          window.addEventListener('message', function(event) {
            try {
              var dataRaw = event.data;
              var dataString;
              try {
                dataString = JSON.stringify(dataRaw);
              } catch (e) {
                dataString = String(dataRaw);
              }

              var hasBridge = !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);

              var payload = {
                label: '$label',
                origin: String(event.origin || ''),
                data: dataString,
                href: String(window.location.href || '')
              };

              if (hasBridge) {
                window.flutter_inappwebview.callHandler('NcupPostMessage', payload);
              }

              try {
                var parsed = dataRaw;
                if (typeof parsed === 'string') {
                  parsed = JSON.parse(parsed);
                }
                if (parsed && parsed.type === 'newTab' && parsed.url) {
                  if (hasBridge) {
                    window.flutter_inappwebview.callHandler('NcupCheckoutAction', parsed);
                  }
                }
              } catch (parseErr) {}
            } catch (e) {}
          });
        })();
      ''',
    );
  }

  Future<void> _installCheckoutInterceptor(
      InAppWebViewController controller,
      ) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installCheckoutInterceptor',
      source: r'''
        (function() {
          if (window.__ncupCheckoutInterceptorInstalled) return;
          window.__ncupCheckoutInterceptorInstalled = true;

          function sendToFlutter(data) {
            try {
              if (!data || typeof data !== 'object') return;
              if (data.type === 'newTab' && data.url) {
                console.log('[NCUP checkout interceptor] newTab:', data.url);
                if (
                  window.flutter_inappwebview &&
                  window.flutter_inappwebview.callHandler
                ) {
                  window.flutter_inappwebview.callHandler(
                    'NcupCheckoutAction',
                    data
                  );
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] send error', e);
            }
          }

          function tryParseMaybeJson(value) {
            try {
              if (!value) return null;
              if (typeof value === 'object') {
                return value;
              }
              if (typeof value === 'string') {
                return JSON.parse(value);
              }
              return null;
            } catch (e) {
              return null;
            }
          }

          function tryHandlePayload(payload) {
            try {
              var data = tryParseMaybeJson(payload);
              if (!data) return;

              if (Array.isArray(data)) {
                data.forEach(function(item) {
                  if (item && item.type === 'newTab' && item.url) {
                    sendToFlutter(item);
                  }
                });
                return;
              }

              if (data.type === 'newTab' && data.url) {
                sendToFlutter(data);
                return;
              }

              if (data.savedata) {
                var saved = tryParseMaybeJson(data.savedata);
                if (saved && saved.type === 'newTab' && saved.url) {
                  sendToFlutter(saved);
                  return;
                }
              }

              if (data.data) {
                var nested = tryParseMaybeJson(data.data);
                if (nested && nested.type === 'newTab' && nested.url) {
                  sendToFlutter(nested);
                  return;
                }
              }

              if (data.content) {
                var content = tryParseMaybeJson(data.content);
                if (content && content.type === 'newTab' && content.url) {
                  sendToFlutter(content);
                  return;
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] handle error', e);
            }
          }

          var originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function() {
              return originalFetch.apply(this, arguments).then(function(response) {
                try {
                  var cloned = response.clone();
                  cloned.text().then(function(text) {
                    tryHandlePayload(text);
                  }).catch(function() {});
                } catch (e) {}
                return response;
              });
            };
          }

          var OriginalXHR = window.XMLHttpRequest;
          if (OriginalXHR) {
            window.XMLHttpRequest = function() {
              var xhr = new OriginalXHR();
              var originalOpen = xhr.open;
              var originalSend = xhr.send;

              xhr.open = function() {
                return originalOpen.apply(xhr, arguments);
              };

              xhr.send = function() {
                xhr.addEventListener('load', function() {
                  try {
                    tryHandlePayload(xhr.responseText);
                  } catch (e) {}
                });
                return originalSend.apply(xhr, arguments);
              };

              return xhr;
            };
          }

          var originalOpen = window.open;
          window.open = function(url, target, features) {
            try {
              console.log('[NCUP window.open intercepted]', url, target, features);
            } catch (e) {}

            if (originalOpen) {
              return originalOpen.apply(window, arguments);
            }
            return null;
          };
        })();
      ''',
    );
  }

  Future<void> _installLocalStorageHook(
      InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installLocalStorageHook',
      source: r'''
        (function() {
          if (window.__ncupLocalStorageHookInstalled) return;
          window.__ncupLocalStorageHookInstalled = true;

          try {
            var originalSetItem = window.localStorage.setItem;
            window.localStorage.setItem = function(key, value) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler('NcupLocalStorageSetItem', {
                    key: String(key),
                    value: String(value)
                  });
                }
              } catch (e) {
                console.log('Ncup localStorage hook error', e);
              }
              return originalSetItem.apply(this, arguments);
            };
          } catch (e) {
            console.log('Ncup localStorage hook init error', e);
          }
        })();
      ''',
    );
  }

  Future<void> _safeInstallAll(
      InAppWebViewController? controller, {
        required String label,
      }) async {
    if (controller == null) return;
    if (!mounted) return;
    if (!WrDeviceProfileInstance.safecasher) {
      print('WERLOG: safeInstallAll skipped ($label) because fpscashier=false');
      return;
    }

    try {
      await _installJsErrorLogger(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installPostMessageBridge(controller, label: label);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installCheckoutInterceptor(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installLocalStorageHook(controller);
    } catch (e) {
      print('WERLOG: safeInstallAll error label=$label error=$e');
    }
  }

  void _scheduleSafeInstall(
      InAppWebViewController controller, {
        required String label,
      }) {
    if (label == 'popup') {
      _popupInstallTimer?.cancel();
      _popupInstallTimer = Timer(const Duration(milliseconds: 450), () async {
        if (!mounted) return;
        await _safeInstallAll(controller, label: label);
      });
    } else {
      _parentInstallTimer?.cancel();
      _parentInstallTimer = Timer(const Duration(milliseconds: 250), () async {
        if (!mounted) return;
        await _safeInstallAll(controller, label: label);
      });
    }
  }

  Map<String, dynamic>? _tryDecodeMap(dynamic value) {
    try {
      if (value == null) return null;
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is String) {
        final String trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        final dynamic decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _openExternalForJsonNewTab(Uri uri) async {
    if (_isAboutBlankUri(uri)) return false;

    final String url = uri.toString();

    if (_handledNewTabUrls.contains(url)) {
      print('WERLOG: duplicate JSON newTab ignored url=$url');
      return true;
    }

    _handledNewTabUrls.add(url);

    if (_isOpeningExternalNewTab) {
      print('WERLOG: external newTab already opening, ignored url=$url');
      return false;
    }

    _isOpeningExternalNewTab = true;

    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print('WERLOG: JSON newTab external launched=$launched url=$url');
      return launched;
    } catch (e) {
      print('WERLOG: JSON newTab external error=$e url=$url');
      return false;
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        _isOpeningExternalNewTab = false;
      });
    }
  }

  Future<bool> _handleCheckoutAction(dynamic rawPayload) async {
    try {
      Map<String, dynamic>? data = _tryDecodeMap(rawPayload);
      if (data == null) return false;

      if (data.containsKey('savedata')) {
        final Map<String, dynamic>? savedataMap =
        _tryDecodeMap(data['savedata']);
        if (savedataMap != null) {
          data = savedataMap;
        }
      }

      if (data.containsKey('data')) {
        final Map<String, dynamic>? dataMap = _tryDecodeMap(data['data']);
        if (dataMap != null &&
            dataMap['type']?.toString() == 'newTab' &&
            (dataMap['url']?.toString() ?? '').isNotEmpty) {
          data = dataMap;
        }
      }

      if (data.containsKey('content')) {
        final Map<String, dynamic>? contentMap =
        _tryDecodeMap(data['content']);
        if (contentMap != null &&
            contentMap['type']?.toString() == 'newTab' &&
            (contentMap['url']?.toString() ?? '').isNotEmpty) {
          data = contentMap;
        }
      }

      final String type = data['type']?.toString() ?? '';
      final String url = data['url']?.toString() ?? '';

      if (type == 'newTab' && url.isNotEmpty) {
        final Uri? uri = Uri.tryParse(url);
        if (uri == null || _isAboutBlankUri(uri)) {
          print('WERLOG: invalid JSON newTab uri=$url');
          return false;
        }

        // === OneLink: НЕ открываем во внешнем браузере ===
        if (WrIsOneLinkUrl(uri)) {
          WrLoggerService()
              .WrLogInfo('OneLink newTab detected, loading in WebView: $url');
          WrNavigateToUri(url);
          return true;
        }

        print('WERLOG: handle JSON newTab url=$url');
        await _openExternalForJsonNewTab(uri);
        return true;
      }

      return false;
    } catch (e) {
      print('WERLOG: handleCheckoutAction error: $e');
      return false;
    }
  }

  Future<bool> _onCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction request,
      ) async {
    final Uri? wrUri = request.request.url;
    final String urlString = wrUri?.toString() ?? '';

    print(
      'WERLOG: MAIN onCreateWindow '
          'windowId=${request.windowId} '
          'url=$urlString '
          'isDialog=${request.isDialog} '
          'hasGesture=${request.hasGesture}',
    );

    if (wrUri != null) {
      if (WrShouldForceHttps(wrUri)) {
        final Uri httpsUri = WrForceHttps(wrUri);
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(httpsUri.toString())),
        );
        return false;
      }

      _currentUrl = wrUri.toString();
      await _updateBackButtonVisibility();

      // === OneLink: загружаем внутри WebView, не открываем внешний браузер ===
      if (WrIsOneLinkUrl(wrUri)) {
        WrLoggerService().WrLogInfo(
            'OneLink onCreateWindow: loading in main WebView: $wrUri');
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(wrUri.toString())),
        );
        return false;
      }

      if (_isGoogleUrl(wrUri)) {}

      if (WrIsBankScheme(wrUri) ||
          ((wrUri.scheme == 'http' || wrUri.scheme == 'https') &&
              WrIsBankDomain(wrUri))) {
        await WrOpenBank(wrUri);
        return false;
      }

      if (WrIsBareEmail(wrUri)) {
        final Uri wrMailto = WrToMailto(wrUri);
        await WrOpenMailExternal(wrMailto);
        return false;
      }

      final String wrScheme = wrUri.scheme.toLowerCase();

      if (wrScheme == 'mailto') {
        await WrOpenMailExternal(wrUri);
        return false;
      }

      if (wrScheme == 'tel') {
        await launchUrl(wrUri, mode: LaunchMode.externalApplication);
        return false;
      }

      final String host = wrUri.host.toLowerCase();
      final bool wrIsSocial = host.endsWith('facebook.com') ||
          host.endsWith('instagram.com') ||
          host.endsWith('twitter.com') ||
          host.endsWith('x.com');

      if (wrIsSocial) {
        await WrOpenExternal(wrUri);
        return false;
      }

      if (WrIsPlatformLink(wrUri)) {
        final Uri wrWebUri = WrHttpizePlatformUri(wrUri);
        await WrOpenExternal(wrWebUri);
        return false;
      }
    }

    if (!mounted) return false;

    setState(() {
      _popupCreateAction = request;
      _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
          ? urlString
          : null;
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });

    return true;
  }

  Future<bool> _onPopupCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction createWindowAction,
      ) async {
    final Uri? uri = createWindowAction.request.url;
    final String urlString = uri?.toString() ?? '';

    print(
      'WERLOG: POPUP onCreateWindow '
          'windowId=${createWindowAction.windowId} '
          'url=$urlString',
    );

    if (uri != null && WrShouldForceHttps(uri)) {
      final Uri httpsUri = WrForceHttps(uri);
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(httpsUri.toString())),
      );
      return false;
    }

    // === OneLink в popup: загружаем в popup WebView ===
    if (uri != null && WrIsOneLinkUrl(uri)) {
      WrLoggerService()
          .WrLogInfo('OneLink popup onCreateWindow: loading in popup WebView: $uri');
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(uri.toString())),
      );
      return false;
    }

    if (!mounted) return false;

    if (createWindowAction.windowId != null) {
      setState(() {
        _popupCreateAction = createWindowAction;
        _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
            ? urlString
            : _popupUrl;
        _popupCurrentUrl = _popupUrl;
        _isPopupVisible = true;
      });
      return true;
    }

    if (urlString.isNotEmpty && !_isAboutBlankUrl(urlString)) {
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(urlString)),
        );
      } catch (e) {
        print(
            'WERLOG: popup inner window.open load error: $e url=$urlString');
      }
    }

    return false;
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      WrPopupWebViewController = null;
    });
  }

  Future<void> _closePopupAndNotifyParent({
    String reason = 'closed_by_user',
  }) async {
    try {
      await WrWebViewController?.evaluateJavascript(
        source: '''
          try {
            window.dispatchEvent(new MessageEvent('message', {
              data: ${jsonEncode({
          'type': 'ncup_popup_closed',
          'reason': reason,
        })},
              origin: window.location.origin
            }));
          } catch(e) {
            console.log('ncup popup close notify failed', e);
          }
        ''',
      );
    } catch (e) {
      print('WERLOG: closePopup notify parent error: $e');
    }
    _closePopup();
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = WrPopupWebViewController;
    if (c == null) {
      if (_popupCanGoBack && mounted) {
        setState(() {
          _popupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool can = await c.canGoBack();
      if (!mounted) return;
      if (can != _popupCanGoBack) {
        setState(() {
          _popupCanGoBack = can;
        });
      }
    } catch (e) {
      print('WERLOG: _refreshPopupCanGoBack error: $e');
    }
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = WrPopupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          _refreshPopupCanGoBack();
        });
      } else {
        await _closePopupAndNotifyParent(reason: 'popup_back_no_history');
      }
    } catch (e) {
      print('WERLOG: _handlePopupBackPressed error: $e');
      _closePopup();
    }
  }

  bool _isCurrentPopupInWhitelist() {
    if (!_isPopupVisible) return false;
    final String popupUrlForCheck = _popupCurrentUrl ?? _popupUrl ?? '';
    return _matchesButtonWhitelist(popupUrlForCheck);
  }

  Widget _buildPopupWebView() {
    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool showBackArrow = !popupInWhitelist && _popupCanGoBack;
    final bool showCloseButton = !popupInWhitelist && !_popupCanGoBack;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            if (!popupInWhitelist) ...[
              SafeArea(
                bottom: false,
                child: Container(
                  color: Colors.black,
                  child: Row(
                    children: [
                      if (showBackArrow)
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          onPressed: _handlePopupBackPressed,
                        )
                      else if (showCloseButton)
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () {
                            _closePopupAndNotifyParent(reason: 'close_button');
                          },
                        ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
            ],
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null) && _popupUrl != null
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupWebViewSettings(),
                onWebViewCreated:
                    (InAppWebViewController popupController) async {
                  WrPopupWebViewController = popupController;

                  print(
                    'WERLOG: popup created '
                        'windowId=${_popupCreateAction?.windowId} '
                        'initialUrl=${_popupUrl ?? _popupCreateAction?.request.url}',
                  );

                  final String popupInitUrl =
                      _popupUrl ?? _popupCreateAction?.request.url?.toString() ?? '';
                  if (popupInitUrl.isNotEmpty) {
                    final Uri? popupUri = Uri.tryParse(popupInitUrl);
                    if (popupUri != null && _isGoogleUrl(popupUri)) {
                      await _applyGoogleUserAgentForPopup();
                    }
                  }

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupLocalStorageSetItem',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic raw = args.first;
                        if (raw is Map) {
                          final String key = raw['key']?.toString() ?? '';
                          final String value = raw['value']?.toString() ?? '';
                          if (key.isNotEmpty) {
                            final SharedPreferences prefs =
                            await SharedPreferences.getInstance();
                            await prefs.setString(key, value);
                            WrLoggerService().WrLogInfo(
                                'NcupLocalStorageSetItem (popup): saved key="$key" len=${value.length}');
                          }
                        }
                      } catch (e, st) {
                        WrLoggerService().WrLogError(
                            'NcupLocalStorageSetItem popup handler error: $e\n$st');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupCheckoutAction',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupCheckoutAction args=$args');
                      if (args.isNotEmpty) {
                        await _handleCheckoutAction(args.first);
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupPostMessage',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic first = args.first;
                        final dynamic dataToHandle =
                        (first is Map && first['data'] != null)
                            ? first['data']
                            : first;
                        await _handleCheckoutAction(dataToHandle);
                      } catch (e) {
                        print(
                            'WERLOG: POPUP NcupPostMessage handler error: $e');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupJSLogger',
                    callback: (List<dynamic> args) {
                      print('WERLOG: POPUP JS error payload: $args');
                      return null;
                    },
                  );
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStart: (controller, uri) async {
                  print('WERLOG: popup onLoadStart url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (_isGoogleUrl(uri)) {
                      await _applyGoogleUserAgentForPopup();
                    }

                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onLoadStop: (controller, uri) async {
                  print('WERLOG: popup onLoadStop url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                      });
                    }
                  }
                  if (!_isAboutBlankUri(uri)) {
                    _scheduleSafeInstall(controller, label: 'popup');
                  }
                  _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  if (url != null && !_isAboutBlankUri(url)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = url.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onCreateWindow: _onPopupCreateWindowHandler,
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction navigationAction,
                    ) async {
                  final Uri? uri = navigationAction.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isAboutBlankUri(uri)) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (WrShouldForceHttps(uri)) {
                    final Uri httpsUri = WrForceHttps(uri);
                    await controller.loadUrl(
                      urlRequest:
                      URLRequest(url: WebUri(httpsUri.toString())),
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  // === OneLink: разрешаем навигацию внутри popup ===
                  if (WrIsOneLinkUrl(uri)) {
                    WrLoggerService().WrLogInfo(
                        'OneLink popup shouldOverride: ALLOW in popup: $uri');
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isGoogleUrl(uri)) {
                    await _applyGoogleUserAgentForPopup();
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (WrIsBareEmail(uri)) {
                    final Uri mailto = WrToMailto(uri);
                    await WrOpenMailExternal(mailto);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await WrOpenMailExternal(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (WrIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          WrIsBankDomain(uri))) {
                    await WrOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    print(
                      'WERLOG: popup non-http/https scheme=$scheme url=$uri, trying external app',
                    );
                    await WrTryOpenUnknownSchemeExternally(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  print('WERLOG: popup onCloseWindow');
                  _closePopup();
                },
                onLoadError: (controller, uri, code, message) async {
                  print(
                    'WERLOG: popup onLoadError url=$uri code=$code msg=$message',
                  );
                },
                onReceivedError: (controller, request, error) async {
                  print(
                    'WERLOG: popup onReceivedError '
                        'url=${request.url} '
                        'type=${error.type} '
                        'desc=${error.description}',
                  );
                },
                onReceivedHttpError:
                    (controller, request, errorResponse) async {
                  print(
                    'WERLOG: popup onReceivedHttpError '
                        'url=${request.url} '
                        'status=${errorResponse.statusCode} '
                        'reason=${errorResponse.reasonPhrase}',
                  );
                },
                onConsoleMessage: (controller, consoleMessage) {
                  print(
                    'WERLOG: popup console: '
                        '${consoleMessage.messageLevel} ${consoleMessage.message}',
                  );
                },
                onDownloadStartRequest: (controller, req) async {
                  print(
                      'WERLOG: popup download for url=${req.url}, opening external');
                  await WrOpenExternal(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    WrBindNotificationTap();

    final Color bgColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget webView = Stack(
      children: <Widget>[
        if (WrCoverVisible)
          const Center(child: WinRunnerLoadingScreen(
            backgroundAsset: 'assets/bg_city.png',
            logoAsset: 'assets/logo_winrunner.png',
            loadingText: 'Loading...',
          )
          )else
          Container(
            color: bgColor,
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  key: ValueKey<int>(WrWebViewKeyCounter),
                  initialSettings: _mainWebViewSettings(),
                  initialUrlRequest: URLRequest(
                    url: WebUri(WrHomeUrl),
                  ),
                  onWebViewCreated:
                      (InAppWebViewController controller) async {
                    WrWebViewController = controller;
                    _currentUrl = WrHomeUrl;

                    WrBosunInstance ??= WrBosunViewModel(
                      WrDeviceProfileInstance: WrDeviceProfileInstance,
                      WrAnalyticsSpyInstance: WrAnalyticsSpyInstance,
                    );

                    WrCourier ??= WrCourierService(
                      WrBosun: WrBosunInstance!,
                      WrGetWebViewController: () => WrWebViewController,
                    );

                    try {
                      final ua = await controller.evaluateJavascript(
                        source: "navigator.userAgent",
                      );
                      if (ua is String && ua.trim().isNotEmpty) {
                        _baseUserAgent = ua.trim();
                        _currentUserAgent = _baseUserAgent!;
                        WrDeviceProfileInstance.WrBaseUserAgent =
                            _baseUserAgent;
                        WrLoggerService().WrLogInfo(
                            'Initial WebView User-Agent: $_baseUserAgent');
                        print(
                            '[UA] INITIAL WEBVIEW USER AGENT: $_baseUserAgent');
                      }
                    } catch (e) {
                      WrLoggerService().WrLogWarn(
                          'Failed to read navigator.userAgent on create: $e');
                    }

                    await _applyNormalUserAgentIfNeeded();

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupLocalStorageSetItem',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic raw = args.first;
                          if (raw is Map) {
                            final String key =
                                raw['key']?.toString() ?? '';
                            final String value =
                                raw['value']?.toString() ?? '';
                            if (key.isNotEmpty) {
                              final SharedPreferences prefs =
                              await SharedPreferences.getInstance();
                              await prefs.setString(key, value);
                              WrLoggerService().WrLogInfo(
                                  'NcupLocalStorageSetItem (main): saved key="$key" len=${value.length}');
                            }
                          }
                        } catch (e, st) {
                          WrLoggerService().WrLogError(
                              'NcupLocalStorageSetItem main handler error: $e\n$st');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'onServerResponse',
                      callback: (List<dynamic> args) async {
                        if (args.isEmpty) return null;

                        print("Get Data server $args");

                        try {
                          dynamic first = args[0];

                          if (first is List && first.isNotEmpty) {
                            first = first.first;
                          }

                          final bool handled =
                          await _handleCheckoutAction(first);
                          if (handled) {}

                          if (first is Map) {
                            final Map<dynamic, dynamic> root = first;

                            if (root['savedata'] != null) {
                              WrHandleServerSavedata(
                                  root['savedata'].toString());
                              await _handleCheckoutAction(root['savedata']);
                            }

                            _updateExtraDataFromServerPayload(root);
                            _updateSafeAreaFromServerPayload(root);
                            await _updateUserAgentFromServerPayload(root);

                            await _applyNormalUserAgentIfNeeded();

                            try {
                              if (!_loadedJsExecutedOnce) {
                                final dynamic adataRaw = root['adata'];
                                if (adataRaw is Map) {
                                  final Map adata = adataRaw;
                                  final dynamic loadedJsRaw =
                                  adata['loadedjs'];
                                  if (loadedJsRaw != null) {
                                    final String loadedJs =
                                    loadedJsRaw.toString().trim();
                                    if (loadedJs.isNotEmpty) {
                                      _pendingLoadedJs = loadedJs;
                                      WrLoggerService().WrLogInfo(
                                        'loadedjs received, will execute ONCE after 6 seconds',
                                      );

                                      Future<void>.delayed(
                                        const Duration(seconds: 6),
                                            () async {
                                          if (!mounted) return;
                                          if (_loadedJsExecutedOnce) {
                                            WrLoggerService().WrLogInfo(
                                                'Skipping loadedjs: already executed once');
                                            return;
                                          }
                                          if (WrWebViewController == null) {
                                            WrLoggerService().WrLogWarn(
                                                'Skipping loadedjs execution: controller is null');
                                            return;
                                          }
                                          final String? jsToRun =
                                              _pendingLoadedJs;
                                          if (jsToRun == null ||
                                              jsToRun.isEmpty) {
                                            return;
                                          }
                                          WrLoggerService().WrLogInfo(
                                              'Executing loadedjs from server payload (ONCE, delayed 6s)');
                                          try {
                                            await WrWebViewController
                                                ?.evaluateJavascript(
                                              source: jsToRun,
                                            );
                                            _loadedJsExecutedOnce = true;
                                          } catch (e, st) {
                                            WrLoggerService().WrLogError(
                                                'Error executing delayed loadedjs: $e\n$st');
                                          }
                                        },
                                      );
                                    }
                                  }
                                }
                              } else {
                                WrLoggerService().WrLogInfo(
                                    'loadedjs ignored: already executed once earlier');
                              }
                            } catch (e, st) {
                              WrLoggerService().WrLogError(
                                  'Error scheduling loadedjs: $e\n$st');
                            }
                          }
                        } catch (e, st) {
                          print('onServerResponse error: $e\n$st');
                        }

                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupCheckoutAction',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupCheckoutAction args=$args');
                          if (args.isNotEmpty) {
                            await _handleCheckoutAction(args.first);
                          }
                        } catch (e) {
                          print(
                              'WERLOG: MAIN NcupCheckoutAction error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupJSLogger',
                      callback: (List<dynamic> args) {
                        try {
                          final dynamic payload =
                          args.isNotEmpty ? args.first : null;
                          print('WERLOG: MAIN JS error payload: $payload');
                        } catch (e) {
                          print('WERLOG: NcupJSLogger handler error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupPostMessage',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic first = args.first;
                          final dynamic dataToHandle =
                          (first is Map && first['data'] != null)
                              ? first['data']
                              : first;
                          await _handleCheckoutAction(dataToHandle);
                        } catch (e) {
                          print(
                              'WERLOG: MAIN NcupPostMessage handler error: $e');
                        }
                        return null;
                      },
                    );
                  },
                  onPermissionRequest: (controller, request) async {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.GRANT,
                    );
                  },
                  onLoadStart:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      WrStartLoadTimestamp =
                          DateTime.now().millisecondsSinceEpoch;
                    });

                    final Uri? wrViewUri = uri;
                    if (wrViewUri != null) {
                      _currentUrl = wrViewUri.toString();

                      await _switchUserAgentForUrl(wrViewUri);

                      await _updateBackButtonVisibility();

                      if (WrIsBareEmail(wrViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        final Uri wrMailto = WrToMailto(wrViewUri);
                        await WrOpenMailExternal(wrMailto);
                        return;
                      }

                      final String wrScheme = wrViewUri.scheme.toLowerCase();

                      if (wrScheme == 'mailto') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await WrOpenMailExternal(wrViewUri);
                        return;
                      }

                      if (WrIsBankScheme(wrViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await WrOpenBank(wrViewUri);
                        return;
                      }

                      if (wrScheme != 'http' && wrScheme != 'https') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await WrTryOpenUnknownSchemeExternally(wrViewUri);
                      }
                    }
                  },
                  onLoadError: (
                      InAppWebViewController controller,
                      Uri? uri,
                      int code,
                      String message,
                      ) async {
                    if (WrIsCancelledLoadError(description: message)) {
                      print(
                          'WERLOG: ignoring cancelled load (code=$code, url=$uri)');
                      return;
                    }

                    final int wrNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String wrEvent =
                        'InAppWebViewError(code=$code, message=$message)';

                    await WrPostStat(
                      event: wrEvent,
                      timeStart: wrNow,
                      timeFinish: wrNow,
                      url: uri?.toString() ?? '',
                      appSid: WrAnalyticsSpyInstance.WrAppsFlyerUid,
                      firstPageLoadTs: WrFirstPageTimestamp,
                    );
                  },
                  onReceivedError: (
                      InAppWebViewController controller,
                      WebResourceRequest request,
                      WebResourceError error,
                      ) async {
                    final String wrDescription =
                    (error.description ?? '').toString();

                    if (WrIsCancelledLoadError(
                        description: wrDescription, type: error.type)) {
                      print(
                          'WERLOG: ignoring cancelled load (type=${error.type}, url=${request.url})');
                      return;
                    }

                    final int wrNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String wrEvent =
                        'WebResourceError(code=$error, message=$wrDescription)';

                    await WrPostStat(
                      event: wrEvent,
                      timeStart: wrNow,
                      timeFinish: wrNow,
                      url: request.url?.toString() ?? '',
                      appSid: WrAnalyticsSpyInstance.WrAppsFlyerUid,
                      firstPageLoadTs: WrFirstPageTimestamp,
                    );
                  },
                  onLoadStop:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      WrCurrentUrl = uri.toString();
                      _currentUrl = WrCurrentUrl;
                    });

                    if (uri != null) {
                      await _switchUserAgentForUrl(uri);
                    }

                    if (!_isAboutBlankUri(uri)) {
                      _scheduleSafeInstall(controller, label: 'parent');
                    }

                    await debugPrintCurrentUserAgent();

                    await _sendAllDataToPageTwice();
                    await _updateBackButtonVisibility();

                    Future<void>.delayed(
                      const Duration(seconds: 20),
                          () {
                        WrSendLoadedOnce(
                          url: WrCurrentUrl.toString(),
                          timestart: WrStartLoadTimestamp,
                        );
                      },
                    );
                  },
                  onUpdateVisitedHistory:
                      (controller, url, isReload) async {
                    if (url != null && !_isAboutBlankUri(url)) {
                      _currentUrl = url.toString();
                      await _updateBackButtonVisibility();
                      await _switchUserAgentForUrl(url);
                    }
                  },
                  shouldOverrideUrlLoading:
                      (InAppWebViewController controller,
                      NavigationAction action) async {
                    final Uri? wrUri = action.request.url;
                    if (wrUri == null) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    _currentUrl = wrUri.toString();
                    await _updateBackButtonVisibility();

                    if (_isAboutBlankUri(wrUri)) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    if (WrShouldForceHttps(wrUri)) {
                      final Uri httpsUri = WrForceHttps(wrUri);
                      await controller.loadUrl(
                        urlRequest:
                        URLRequest(url: WebUri(httpsUri.toString())),
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    // === OneLink: ВСЕГДА разрешаем навигацию внутри WebView ===
                    if (WrIsOneLinkUrl(wrUri)) {
                      WrLoggerService().WrLogInfo(
                          'OneLink shouldOverride: ALLOW in WebView: $wrUri');
                      return NavigationActionPolicy.ALLOW;
                    }

                    if (_isGoogleUrl(wrUri)) {
                      _isCurrentlyOnGoogle = true;
                      await _applyGoogleUserAgent();
                      return NavigationActionPolicy.ALLOW;
                    } else {
                      if (_isCurrentlyOnGoogle) {
                        _isCurrentlyOnGoogle = false;
                      }
                      await _applyNormalUserAgentIfNeeded();
                    }

                    if (WrIsBareEmail(wrUri)) {
                      final Uri wrMailto = WrToMailto(wrUri);
                      await WrOpenMailExternal(wrMailto);
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String wrScheme = wrUri.scheme.toLowerCase();

                    if (wrScheme == 'mailto') {
                      await WrOpenMailExternal(wrUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (WrIsBankScheme(wrUri)) {
                      await WrOpenBank(wrUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if ((wrScheme == 'http' || wrScheme == 'https') &&
                        WrIsBankDomain(wrUri)) {
                      await WrOpenBank(wrUri);

                      if (_isAdobeRedirect(wrUri)) {
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  WrAdobeRedirectScreen(uri: wrUri),
                            ),
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (wrScheme == 'tel') {
                      await launchUrl(
                        wrUri,
                        mode: LaunchMode.externalApplication,
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String host = wrUri.host.toLowerCase();
                    final bool wrIsSocial =
                        host.endsWith('facebook.com') ||
                            host.endsWith('instagram.com') ||
                            host.endsWith('twitter.com') ||
                            host.endsWith('x.com');

                    if (wrIsSocial) {
                      await WrOpenExternal(wrUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (WrIsPlatformLink(wrUri)) {
                      final Uri wrWebUri = WrHttpizePlatformUri(wrUri);
                      await WrOpenExternal(wrWebUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (wrScheme != 'http' && wrScheme != 'https') {
                      await WrTryOpenUnknownSchemeExternally(wrUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    return NavigationActionPolicy.ALLOW;
                  },
                  onCreateWindow: _onCreateWindowHandler,
                  onCloseWindow: (controller) {
                    print('WERLOG: MAIN onCloseWindow');
                  },
                  onDownloadStartRequest: (
                      InAppWebViewController controller,
                      DownloadStartRequest req,
                      ) async {
                    await WrOpenExternal(req.url);
                  },
                  onConsoleMessage: (controller, consoleMessage) {
                    print(
                      'WERLOG: MAIN console: '
                          '${consoleMessage.messageLevel} ${consoleMessage.message}',
                    );
                  },
                ),
                Visibility(
                  visible: !WrVeilVisible,
                  child:  Center(child: WinRunnerLoadingScreen(
    backgroundAsset: 'assets/bg_city.png',
    logoAsset: 'assets/logo_winrunner.png',
    loadingText: 'Loading...',
    ),
                )),
                if (_isPopupVisible &&
                    (_popupUrl != null || _popupCreateAction != null))
                  _buildPopupWebView(),
              ],
            ),
          ),
      ],
    );

    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool whitelistMatch =
        (!_isPopupVisible && _showBackButton) || popupInWhitelist;

    final bool shouldShowTopBackBar =
        whitelistMatch && !_backButtonHiddenAfterTap;

    final Color topBarColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget topBackBar = shouldShowTopBackBar
        ? Container(
      color: topBarColor,
      padding: const EdgeInsets.only(left: 4, right: 4),
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBackButtonPressed,
          ),
        ],
      ),
    )
        : const SizedBox.shrink();

    final Widget fullScreen = Column(
      children: [
        topBackBar,
        Expanded(child: webView),
      ],
    );

    final Widget body = _safeAreaEnabled
        ? SafeArea(
      child: fullScreen,
    )
        : fullScreen;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: bgColor,
        body: SizedBox.expand(
          child: ColoredBox(
            color: bgColor,
            child: body,
          ),
        ),
      ),
    );
  }

  bool _isAdobeRedirect(Uri uri) {
    final String host = uri.host.toLowerCase();
    return host == 'c00.adobe.com';
  }
}

// ---------------------- Экран для c00.adobe.com ----------------------

class WrAdobeRedirectScreen extends StatelessWidget {
  final Uri uri;

  const WrAdobeRedirectScreen({super.key, required this.uri});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF111111),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Go to the App Store and download the app.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Глобальный мост для com.example.fcm/push
// ============================================================================
//
// Регистрируется ОДИН раз в main(), ещё до первого runApp(), потому что
// нативная сторона (AppDelegate) может прислать FCM-токен через этот канал
// очень рано — до того, как экран WrHarbor (единственное место, где раньше
// стоял обработчик этого канала) вообще будет создан. Если в этот момент
// на канале ещё нет обработчика, native invokeMethod просто теряется.
// Поэтому обработчик живёт здесь, на уровне файла, и просто запоминает
// последние данные + уведомляет текущий активный WrHarbor (если он уже
// смонтирован) через колбэки gWrOnPushToken/gWrOnPushUri.
String? gWrPushToken;
String? gWrAttStatus;
Map<String, dynamic>? gWrLastPushData;
void Function(String token)? gWrOnPushToken;
void Function(String uri)? gWrOnPushUri;
bool _gWrPushChannelBound = false;

void gWrBindPushChannel() {
  if (_gWrPushChannelBound) return;
  _gWrPushChannelBound = true;

  const MethodChannel pushChannel = MethodChannel('com.example.fcm/push');

  pushChannel.setMethodCallHandler((MethodCall call) async {
    if (call.method != 'setPushData') return;
    try {
      Map<String, dynamic> pushData;
      if (call.arguments is Map) {
        pushData = Map<String, dynamic>.from(call.arguments as Map);
        print("Get Push Data $pushData");
      } else if (call.arguments is String) {
        pushData =
        jsonDecode(call.arguments as String) as Map<String, dynamic>;
      } else {
        pushData = <String, dynamic>{'raw': call.arguments.toString()};
      }

      WrLoggerService().WrLogInfo('Got push data from AppDelegate: $pushData');

      gWrLastPushData = pushData;

      final dynamic tokenRaw = pushData['token'];
      if (tokenRaw != null && tokenRaw.toString().isNotEmpty) {
        gWrPushToken = tokenRaw.toString();
        WrLoggerService()
            .WrLogInfo('Got FCM token via com.example.fcm/push: $gWrPushToken');
        gWrOnPushToken?.call(gWrPushToken!);
      }

      final dynamic uriRaw = pushData['uri'] ?? pushData['deep_link'];
      if (uriRaw != null && uriRaw.toString().isNotEmpty) {
        gWrOnPushUri?.call(uriRaw.toString());
      }

      final dynamic attStatusRaw = pushData['att_status'];
      if (attStatusRaw != null && attStatusRaw.toString().isNotEmpty) {
        gWrAttStatus = attStatusRaw.toString();
        WrLoggerService()
            .WrLogInfo('ATT status from AppDelegate: $gWrAttStatus');
      }
    } catch (e, st) {
      WrLoggerService().WrLogError('gWrBindPushChannel handler error: $e\n$st');
    }
  });
}

// ============================================================================
// main()
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Регистрируем канал com.example.fcm/push как можно раньше — ещё до
  // Firebase.initializeApp() и runApp() — чтобы не потерять FCM-токен,
  // если AppDelegate пришлёт его совсем рано (см. gWrBindPushChannel).
  gWrBindPushChannel();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(WrFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WrHall(),
    ),
  );
}