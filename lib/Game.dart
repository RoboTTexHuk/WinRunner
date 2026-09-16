import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'Load.dart';



/// WebView-экран с базовыми настройками InAppWebView и лоадером
/// WinRunner (фон + лого + круговой градиентный индикатор) поверх
/// страницы, пока она грузится.
///
/// Зависимость в pubspec.yaml:
/// ```yaml
/// dependencies:
///   flutter_inappwebview: ^6.1.5
/// ```
///
/// Использование:
/// ```dart
/// WinRunnerWebView(
///   initialUrl: 'https://example.com',
///   backgroundAsset: 'assets/images/bg_city.png',
///   logoAsset: 'assets/images/logo_winrunner.png',
///   loadingText: 'Загрузка...',
/// )
/// ```
class WinRunnerWebView extends StatefulWidget {
  const WinRunnerWebView({
    super.key,
    required this.initialUrl,
    required this.backgroundAsset,
    required this.logoAsset,
    this.loadingText,
  });

  final String initialUrl;
  final String backgroundAsset;
  final String logoAsset;
  final String? loadingText;

  @override
  State<WinRunnerWebView> createState() => _WinRunnerWebViewState();
}

class _WinRunnerWebViewState extends State<WinRunnerWebView> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // Экран с WebView открывается только в горизонтальной ориентации.
    _lockLandscapeOrientation();
  }

  Future<void> _lockLandscapeOrientation() async {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    // Возвращаем поддержку всех ориентаций для остальной части приложения.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // Базовые настройки WebView.
  final InAppWebViewSettings _settings = InAppWebViewSettings(
    // Общие
    javaScriptEnabled: true,
    domStorageEnabled: true,
    cacheEnabled: true,
    supportZoom: false,
    transparentBackground: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    disableContextMenu: true,
    // Android
    useHybridComposition: true,
    // iOS
    allowsBackForwardNavigationGestures: true,
    isInspectable: kDebugMode,
  );

  Future<bool> _onWillPop() async {
    if (_webViewController != null && await _webViewController!.canGoBack()) {
      _webViewController!.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onWillPop() && context.mounted) {
          Navigator.of(context).maybePop();
        }
      },
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
              initialSettings: _settings,
              onWebViewCreated: (controller) {
                _webViewController = controller;
              },
              onLoadStart: (controller, url) {
                if (!mounted) return;
                setState(() => _isLoading = true);
              },
              onLoadStop: (controller, url) async {
                if (!mounted) return;
                setState(() => _isLoading = false);
              },
              onReceivedError: (controller, request, error) {
                if (!mounted) return;
                setState(() => _isLoading = false);
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                if (!mounted) return;
                setState(() => _isLoading = false);
              },
            ),
            // Лоадер поверх WebView, пока страница грузится.
            IgnorePointer(
              ignoring: !_isLoading,
              child: AnimatedOpacity(
                opacity: _isLoading ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                child: WinRunnerLoadingScreen(
                  backgroundAsset: 'assets/bg_city.png',
                  logoAsset: 'assets/logo_winrunner.png',
                  loadingText: 'Loading...',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
