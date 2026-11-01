import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// 貝殼幣圖示：像發送鍵一樣跟著主題 accent 變色。
///
/// 原圖是 16×16 三色像素貝殼（金色主體、深色描邊、淺色高光）。
/// 這裡不用單色 srcIn（會把三色壓成一塊剪影），而是用亮度矩陣：
/// 主體亮度對準 accent，描邊整體暗一階、高光整體亮一階，保留像素明暗層次。
class ShellCoinIcon extends StatelessWidget {
  const ShellCoinIcon({super.key, this.size = 18, this.color});

  static const String assetPath = 'assets/images/shell_coin.png';

  /// 原圖主體色的相對亮度（242, 201, 109）。
  static const double _bodyLuminance = 0.797;

  /// 明暗層次強度：描邊約 -0.24、高光約 +0.2（0～1 色階）。
  static const double _contrast = 1.2;

  final double size;

  /// 不傳時用 [YanciTheme.accent]。注意：使用處不要加 const，
  /// 否則切換主題時這顆圖示不會跟著重建。
  final Color? color;

  static ColorFilter filterFor(Color tint) {
    const k = _contrast;
    const wr = 0.2126 * k;
    const wg = 0.7152 * k;
    const wb = 0.0722 * k;
    double offset(double channel) => 255 * (channel - k * _bodyLuminance);
    return ColorFilter.matrix(<double>[
      wr, wg, wb, 0, offset(tint.r), //
      wr, wg, wb, 0, offset(tint.g), //
      wr, wg, wb, 0, offset(tint.b), //
      0, 0, 0, 1, 0, //
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ColorFiltered(
      colorFilter: filterFor(color ?? YanciTheme.accent),
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        filterQuality: FilterQuality.none,
      ),
    );
  }
}
