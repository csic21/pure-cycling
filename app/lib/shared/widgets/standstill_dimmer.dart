import 'dart:async';

import 'package:flutter/material.dart';

/// Dims the ride screen when the rider has been stopped for a while
/// (spec §7.3).
///
/// Two things happen together, and both matter:
///
/// * The content is dimmed. A red light is the single largest block of
///   continuous on-time in a city ride, and dimming through it is the biggest
///   power saving available without turning anything off.
/// * Non-essential values are hidden. Beyond the battery cost, a screen full
///   of numbers that nobody is reading is a distraction the moment the rider
///   looks down again.
///
/// The dim lifts the instant the wheels turn, not on a timer — the rider must
/// never have to wait to read their speed after pulling away.
class StandstillDimmer extends StatefulWidget {
  const StandstillDimmer({
    super.key,
    required this.speedMps,
    required this.child,
    this.enabled = true,
    this.speedThresholdMps = 1.0 / 3.6,
    this.triggerAfter = const Duration(seconds: 30),
    this.dimOpacity = 0.45,
  });

  final double speedMps;
  final Widget child;
  final bool enabled;

  /// Below this, the rider counts as stopped. 1 km/h, per the spec.
  final double speedThresholdMps;

  final Duration triggerAfter;
  final double dimOpacity;

  /// Whether the subtree is currently dimmed.
  ///
  /// Read through the context rather than passed down as an argument, so an
  /// ancestor can wrap a whole page and any descendant that wants to simplify
  /// itself while stopped can ask — without every widget in between having to
  /// thread the flag through.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_DimmedScope>()
          ?.dimmed ??
      false;

  @override
  State<StandstillDimmer> createState() => _StandstillDimmerState();
}

class _DimmedScope extends InheritedWidget {
  const _DimmedScope({required this.dimmed, required super.child});

  final bool dimmed;

  @override
  bool updateShouldNotify(_DimmedScope oldWidget) => oldWidget.dimmed != dimmed;
}

class _StandstillDimmerState extends State<StandstillDimmer> {
  Timer? _timer;
  bool _dimmed = false;

  @override
  void initState() {
    super.initState();
    _evaluate();
  }

  @override
  void didUpdateWidget(StandstillDimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.speedMps != widget.speedMps) {
      _evaluate();
    }
  }

  void _evaluate() {
    final stopped = widget.speedMps < widget.speedThresholdMps;

    if (!widget.enabled || !stopped) {
      _timer?.cancel();
      _timer = null;
      if (_dimmed) setState(() => _dimmed = false);
      return;
    }

    // Already counting down or already dimmed — nothing to restart.
    if (_timer != null || _dimmed) return;

    _timer = Timer(widget.triggerAfter, () {
      _timer = null;
      if (!mounted) return;
      setState(() => _dimmed = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _DimmedScope(
      dimmed: _dimmed,
      child: AnimatedOpacity(
        // Slow to dim, because arriving at a stop should not flash the screen;
        // instant to restore, because the rider is already moving.
        duration: _dimmed
            ? const Duration(milliseconds: 900)
            : const Duration(milliseconds: 120),
        opacity: _dimmed ? widget.dimOpacity : 1.0,
        child: widget.child,
      ),
    );
  }
}
