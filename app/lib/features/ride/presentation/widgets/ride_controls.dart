import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../domain/ride_engine.dart';

/// The ride controls (spec §5.1).
///
/// Three constraints drive every decision here, and they are the reason this
/// widget looks the way it does:
///
/// 1. **Gloves.** A winter glove is roughly a 12 mm contact patch and has no
///    fine control. Everything is at least 64 logical pixels tall and the hit
///    targets have no gaps between them where a tap can land harmlessly.
/// 2. **Riding.** The phone is mounted, vibrating, and often in the sun. The
///    controls are at the bottom where a thumb naturally falls, and nothing
///    requires a precise press.
/// 3. **Consequence.** Stopping is irreversible; pausing is not. So pause is
///    the large, obvious button and stop is smaller, text-only, and confirmed
///    by a dialog.
class RideControls extends StatelessWidget {
  const RideControls({
    super.key,
    required this.ride,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    this.onReroute,
  });

  final RideState ride;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;

  /// Manual reroute; only offered while navigating.
  final VoidCallback? onReroute;

  @override
  Widget build(BuildContext context) {
    final paused = ride.isPaused || ride.autoPaused;
    final canControl = ride.isRiding || ride.isPaused;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.hairline)),
      ),
      child: Row(
        children: [
          if (onReroute != null) ...[
            _SquareButton(
              icon: Icons.alt_route,
              label: '重算',
              onTap: onReroute!,
            ),
            const SizedBox(width: 10),
          ],

          Expanded(
            child: _PrimaryButton(
              // The auto-paused state is not something the rider chose, so the
              // button reads "继续" as an acknowledgement rather than as an
              // undo — tapping it resumes, which is what they want.
              label: paused ? '继续' : '暂停',
              icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              color: paused ? AppColors.accent : AppColors.surfaceRaised,
              foreground: paused ? Colors.black : AppColors.textPrimary,
              enabled: canControl,
              onTap: paused ? onResume : onPause,
            ),
          ),

          const SizedBox(width: 10),

          _SquareButton(
            icon: Icons.stop_rounded,
            label: '结束',
            onTap: canControl ? onStop : null,
            foreground: AppColors.danger,
            borderColor: canControl
                ? AppColors.danger.withValues(alpha: 0.4)
                : AppColors.hairline,
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.foreground,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color foreground;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Material(
        color: enabled ? color : AppColors.surfaceRaised.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: foreground),
              const SizedBox(width: 8),
              Text(
                label,
                style: AppText.button.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.foreground = AppColors.textSecondary,
    this.borderColor = AppColors.hairline,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color foreground;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return SizedBox(
      width: 76,
      height: 68,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: enabled ? foreground : AppColors.textTertiary,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: AppText.caption.copyWith(
                    color: enabled ? foreground : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
