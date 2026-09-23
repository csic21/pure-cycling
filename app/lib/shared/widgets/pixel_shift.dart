import 'dart:async';

import 'package:flutter/material.dart';

/// Anti burn-in offset cycling (spec §7.2).
///
/// An OLED panel wears where a pixel stays lit. A bike computer is the worst
/// case imaginable: the same giant speed number, in the same place, for hours
/// at a time, several times a week. On a phone used this way the ghost of
/// "28.6" can become permanently visible within a year.
///
/// The mitigation is to nudge the whole layout around a small box on a slow
/// cycle. The offsets here walk the perimeter of a 5×5 grid in the order given
/// in the spec — right, down, left, up — rather than jumping randomly, because
/// a random placement occasionally revisits a corner and spends twice as long
/// there, while a rotation visits every position equally.
///
/// The step is deliberately ±2 px. Larger movement is visible as the layout
/// twitching while riding, which is worse than the burn-in it prevents; at
/// 2 px it reads as nothing at all and still moves every lit subpixel.
class PixelShift extends StatefulWidget {
  const PixelShift({
    super.key,
    required this.child,
    this.enabled = true,
    this.interval = const Duration(seconds: 45),
    this.range = 2,
  });

  final Widget child;
  final bool enabled;

  /// How long each offset is held. The spec allows 30–60 s; 45 s splits the
  /// difference and means a four-hour ride cycles the pattern 320 times.
  final Duration interval;

  /// Maximum displacement in logical pixels.
  final int range;

  @override
  State<PixelShift> createState() => _PixelShiftState();
}

class _PixelShiftState extends State<PixelShift> {
  static const List<Offset> _perimeter = [
    Offset(0, 0),
    Offset(1, 0),
    Offset(1, 1),
    Offset(0, 1),
    Offset(-1, 1),
    Offset(-1, 0),
    Offset(-1, -1),
    Offset(0, -1),
  ];

  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void didUpdateWidget(PixelShift oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.interval != widget.interval) {
      _restartTimer();
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    if (!widget.enabled) {
      // Snap back to centre when disabled, so turning the setting off leaves
      // the layout where the user expects rather than stuck at an offset.
      _step = 0;
      return;
    }
    _timer = Timer.periodic(widget.interval, (_) {
      if (!mounted) return;
      setState(() => _step = (_step + 1) % _perimeter.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final base = _perimeter[_step];
    final target = Offset(
      base.dx * widget.range,
      base.dy * widget.range,
    );

    return TweenAnimationBuilder<Offset>(
      // Longer than the interval would look laggy; much shorter would be a
      // visible snap. 1.2 s of easing across 2 px is imperceptible.
      duration: const Duration(milliseconds: 1200),
      curve: Curves.easeInOut,
      tween: Tween<Offset>(begin: Offset.zero, end: target),
      builder: (context, offset, child) =>
          Transform.translate(offset: offset, child: child),
      child: widget.child,
    );
  }
}

/// A screenshot-friendly note: the shift is applied to the *whole* ride
/// surface rather than to individual tiles, so nothing ends up overlapping or
/// clipping at the edges. The container that hosts this must therefore allow
/// the content to be a couple of pixels wider than its box, which
/// [Clip.none] in the ride scaffold ensures.
class PixelShiftScope extends StatelessWidget {
  const PixelShiftScope({super.key, required this.child, required this.enabled});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // `ClipRect` with `Clip.none` is explicitly a no-op — and that is the
    // point. It documents, at the call site, that the surrounding layout must
    // let content overhang its box by the shift range instead of cropping it.
    return ClipRect(
      clipBehavior: Clip.none,
      child: PixelShift(enabled: enabled, child: child),
    );
  }
}
