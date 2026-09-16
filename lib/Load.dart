import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Полноэкранный лоадер: фон + лого по центру + круговой индикатор
/// в фирменных цветах (фиолетовый → голубой), как на арте WinRunner.
///
/// Использование:
/// ```dart
/// Navigator.of(context).pushReplacement(
///   MaterialPageRoute(
///     builder: (_) => const WinRunnerLoadingScreen(
///       backgroundAsset: 'assets/images/bg_city.png',
///       logoAsset: 'assets/images/logo_winrunner.png',
///     ),
///   ),
/// );
/// ```
///
/// Не забудьте прописать ассеты в pubspec.yaml:
/// ```yaml
/// flutter:
///   assets:
///     - assets/images/bg_city.png
///     - assets/images/logo_winrunner.png
/// ```
class WinRunnerLoadingScreen extends StatefulWidget {
  const WinRunnerLoadingScreen({
    super.key,
    required this.backgroundAsset,
    required this.logoAsset,
    this.loadingText,
    this.logoWidth = 260,
    this.loaderSize = 64,
    this.loaderStrokeWidth = 4,
    this.gradientColors = const [Color(0xFFB24BF3), Color(0xFF4BD0F3)],
    this.overlayColor = Colors.black,
    this.overlayOpacity = 0.45,
  });

  /// Путь к фоновому изображению (город).
  final String backgroundAsset;

  /// Путь к изображению логотипа/тайтла.
  final String logoAsset;

  /// Необязательный текст под лоадером (например, "Загрузка...").
  final String? loadingText;

  final double logoWidth;
  final double loaderSize;
  final double loaderStrokeWidth;

  /// Цвета градиента кругового лоадера.
  final List<Color> gradientColors;

  /// Затемняющий оверлей поверх фона для читаемости контента.
  final Color overlayColor;
  final double overlayOpacity;

  @override
  State<WinRunnerLoadingScreen> createState() =>
      _WinRunnerLoadingScreenState();
}

class _WinRunnerLoadingScreenState extends State<WinRunnerLoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Фон
          Image.asset(
            widget.backgroundAsset,
            fit: BoxFit.cover,
          ),
          // Затемнение для контраста
          Container(
            color: widget.overlayColor.withOpacity(widget.overlayOpacity),
          ),
          // Контент по центру
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  widget.logoAsset,
                  width: widget.logoWidth,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: widget.loaderSize,
                  height: widget.loaderSize,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _GradientRingPainter(
                          progress: _controller.value,
                          strokeWidth: widget.loaderStrokeWidth,
                          colors: widget.gradientColors,
                        ),
                      );
                    },
                  ),
                ),
                if (widget.loadingText != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    widget.loadingText!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Рисует вращающееся кольцо с градиентом (аналог CircularProgressIndicator,
/// но с плавным градиентным "хвостом" вместо однотонного цвета).
class _GradientRingPainter extends CustomPainter {
  _GradientRingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.colors,
  });

  final double progress;
  final double strokeWidth;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final rotation = progress * 2 * math.pi;

    final gradient = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      colors: [
        colors.first.withOpacity(0.0),
        ...colors,
        colors.first.withOpacity(0.0),
      ],
      stops: const [0.0, 0.15, 0.85, 1.0],
      transform: GradientRotation(rotation),
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = gradient.createShader(rect);

    canvas.drawArc(rect, 0, 2 * math.pi * 0.75, false, paint);
  }

  @override
  bool shouldRepaint(covariant _GradientRingPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
