import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A titled group of settings rows.
///
/// The settings tree in the spec (§39) is a flat list of labelled groups; this
/// gives them a consistent shape without a per-screen layout decision.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.rows,
    this.footnote,
  });

  final String title;
  final List<Widget> rows;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child: Text(title, style: AppText.sectionTitle),
        ),
        ...rows,
        if (footnote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(footnote!, style: AppText.caption),
          ),
      ],
    );
  }
}

/// A settings row with a switch.
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: value,
      // A null callback disables the row, which is how a dependent setting is
      // greyed out rather than hidden — hiding it would make the parent toggle
      // look like it had no consequences.
      onChanged: enabled ? onChanged : null,
      title: Text(
        title,
        style: AppText.body.copyWith(
          color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: AppText.caption.copyWith(
                color: enabled ? AppColors.textTertiary : AppColors.hairline,
              ),
            ),
      activeThumbColor: Colors.black,
      activeTrackColor: AppColors.accent,
    );
  }
}

/// A settings row that opens a sub-screen or performs an action.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.trailingText,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? trailingText;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading,
      onTap: onTap,
      title: Text(
        title,
        style: AppText.body.copyWith(
          color: destructive ? AppColors.danger : AppColors.textPrimary,
        ),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing ??
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trailingText != null)
                Text(
                  trailingText!,
                  style: AppText.caption.copyWith(color: AppColors.textSecondary),
                ),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: AppColors.textTertiary,
                ),
              ],
            ],
          ),
    );
  }
}

/// A labelled choice rendered as a horizontal segmented control.
///
/// Used where there are three or four options and the choice should be visible
/// without opening anything — units, GPS accuracy, the start countdown.
class SettingsChoice<T> extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final T value;
  final List<({T value, String label})> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.body),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: AppText.caption),
          ],
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.hairline),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                for (var i = 0; i < options.length; i++)
                  Expanded(
                    child: _Segment(
                      label: options[i].label,
                      selected: options[i].value == value,
                      isFirst: i == 0,
                      isLast: i == options.length - 1,
                      onTap: () => onChanged(options[i].value),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : Colors.transparent,
      borderRadius: BorderRadius.horizontal(
        left: Radius.circular(isFirst ? 9 : 0),
        right: Radius.circular(isLast ? 9 : 0),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(isFirst ? 9 : 0),
          right: Radius.circular(isLast ? 9 : 0),
        ),
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              label,
              style: AppText.label.copyWith(
                color: selected ? Colors.black : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A numeric stepper for values like the auto-pause delay.
class SettingsStepper extends StatelessWidget {
  const SettingsStepper({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.suffix = '',
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final int value;
  final int min;
  final int max;
  final int step;
  final String suffix;

  /// Greys the row out without hiding it, for a value that is only meaningful
  /// while its parent toggle is on.
  final bool enabled;

  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.body.copyWith(
                    color: enabled
                        ? AppColors.textPrimary
                        : AppColors.textTertiary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: AppText.caption.copyWith(
                      color: enabled
                          ? AppColors.textTertiary
                          : AppColors.hairline,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _StepButton(
            icon: Icons.remove,
            onTap: !enabled || value - step < min
                ? null
                : () => onChanged(value - step),
          ),
          SizedBox(
            width: 64,
            child: Text(
              '$value$suffix',
              textAlign: TextAlign.center,
              style: AppText.value.copyWith(
                fontSize: 18,
                color: enabled
                    ? AppColors.textPrimary
                    : AppColors.textTertiary,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add,
            onTap: !enabled || value + step > max
                ? null
                : () => onChanged(value + step),
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(side: BorderSide(color: AppColors.hairline)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
          ),
        ),
      ),
    );
  }
}
