import 'package:flutter/material.dart';

import '../theme.dart';

/// Dark glass card with a glowing gradient border.
class NeonCard extends StatelessWidget {
  final Widget child;
  final List<Color> colors;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final double radius;
  const NeonCard({
    super.key,
    required this.child,
    this.colors = PX.gBrand,
    this.padding = const EdgeInsets.all(14),
    this.margin = const EdgeInsets.only(bottom: 12),
    this.radius = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.first.withValues(alpha: 0.75),
            colors.last.withValues(alpha: 0.12),
            colors.first.withValues(alpha: 0.35),
          ],
        ),
        boxShadow: [
          BoxShadow(color: colors.first.withValues(alpha: 0.14), blurRadius: 14, spreadRadius: -4),
        ],
      ),
      padding: const EdgeInsets.all(1.2),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius - 1),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(PX.card, colors.first, 0.07)!,
              PX.card,
              Color.lerp(PX.card, colors.last, 0.05)!,
            ],
          ),
        ),
        // Content updates every few seconds; keep the glowing frame out of
        // those repaints.
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

/// Rounded square with a gradient and a white icon.
class IconBadge extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final double size;
  const IconBadge(this.icon, {super.key, this.colors = PX.gBrand, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: colors.first.withValues(alpha: 0.45), blurRadius: 10, spreadRadius: -2)],
      ),
      child: Icon(icon, size: size * 0.56, color: Colors.white),
    );
  }
}

/// Text painted with a gradient.
class GradientText extends StatelessWidget {
  final String text;
  final List<Color> colors;
  final TextStyle style;
  const GradientText(this.text, {super.key, required this.colors, required this.style});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => LinearGradient(colors: colors).createShader(r),
      child: Text(text, style: style),
    );
  }
}

/// Glowing dot that pulses while data is live.
class PulseDot extends StatefulWidget {
  final Color color;
  final double size;
  const PulseDot({super.key, this.color = PX.mint, this.size = 9});

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return RepaintBoundary(
     child: SizedBox(
      width: s * 2.4,
      height: s * 2.4,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(alignment: Alignment.center, children: [
          Container(
            width: s * (1 + 1.4 * _c.value),
            height: s * (1 + 1.4 * _c.value),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: s,
            height: s,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
          ),
        ]),
      ),
     ),
    );
  }
}

/// Small tinted chip with an icon.
class NeonChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const NeonChip(this.icon, this.text, {super.key, this.color = PX.neonPurple});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 11.5, color: Color.lerp(color, Colors.white, 0.55), fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Pill tab bar with a gradient highlight on the selected tab.
class NeonTabs extends StatelessWidget {
  final List<(IconData, String)> items;
  final int selected;
  final ValueChanged<int> onChanged;
  const NeonTabs({super.key, required this.items, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: PX.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PX.neonPurple.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        for (var i = 0; i < items.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: i == selected ? const LinearGradient(colors: PX.gBrand) : null,
                  boxShadow: i == selected
                      ? [BoxShadow(color: PX.neonPurple.withValues(alpha: 0.45), blurRadius: 12, spreadRadius: -3)]
                      : null,
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(items[i].$1, size: 16, color: i == selected ? Colors.white : PX.muted),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(items[i].$2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: i == selected ? Colors.white : PX.muted,
                        )),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Bar with a gradient fill (0-100 %).
class GradientBar extends StatelessWidget {
  final double percent;
  final List<Color> colors;
  final double height;
  const GradientBar({super.key, required this.percent, required this.colors, this.height = 6});

  @override
  Widget build(BuildContext context) {
    final f = (percent / 100).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Container(color: Colors.white.withValues(alpha: 0.06)),
          FractionallySizedBox(
            widthFactor: f,
            child: Container(
              decoration: BoxDecoration(gradient: LinearGradient(colors: colors)),
            ),
          ),
        ]),
      ),
    );
  }
}
