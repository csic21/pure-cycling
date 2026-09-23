import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../../dashboard/domain/dashboard_config.dart';
import '../../dashboard/domain/dashboard_field.dart';
import '../../dashboard/presentation/dashboard_view.dart';
import '../../ride/domain/ride.dart';

/// The dashboard editor (spec §6, §39).
///
/// V1 gives three fixed layouts and a field picker per slot, rather than free
/// drag-and-drop placement. That is a deliberate constraint: the layouts
/// encode the "hero number at least 20% of the screen" rule from §5.1, and a
/// free-form editor makes it possible to build a dashboard that is unusable at
/// arm's length on a moving bicycle.
class DashboardEditorScreen extends ConsumerStatefulWidget {
  const DashboardEditorScreen({super.key});

  @override
  ConsumerState<DashboardEditorScreen> createState() =>
      _DashboardEditorScreenState();
}

class _DashboardEditorScreenState extends ConsumerState<DashboardEditorScreen> {
  int _pageIndex = 0;

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(dashboardConfigProvider);
    final formatter = ref.watch(unitFormatterProvider);
    final notifier = ref.read(settingsProvider.notifier);

    if (_pageIndex >= config.pages.length) _pageIndex = 0;
    final page = config.pages[_pageIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('码表布局'),
        actions: [
          IconButton(
            tooltip: '添加页面',
            icon: const Icon(Icons.add),
            onPressed: () => _addPage(config, notifier),
          ),
          if (config.pages.length > 1)
            IconButton(
              tooltip: '删除当前页面',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _removePage(config, notifier),
            ),
        ],
      ),
      body: Column(
        children: [
          _PageTabs(
            pages: config.pages,
            selected: _pageIndex,
            onSelected: (index) => setState(() => _pageIndex = index),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                const _SectionLabel('布局'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      for (final layout in DashboardLayout.values)
                        _LayoutOption(
                          layout: layout,
                          selected: page.layout == layout,
                          onTap: () => _changeLayout(config, notifier, layout),
                        ),
                    ],
                  ),
                ),

                const _SectionLabel('预览'),
                _Preview(page: page, formatter: formatter),

                const _SectionLabel('数据字段'),
                for (var i = 0; i < page.layout.capacity; i++)
                  _FieldSlot(
                    index: i,
                    isHero: page.layout != DashboardLayout.grid6 && i == 0,
                    current: i < page.fields.length
                        ? page.fields[i]
                        : (page.fields.isEmpty
                            ? DashboardField.speed
                            : page.fields.last),
                    onChanged: (field) => _setField(config, notifier, i, field),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _changeLayout(
    DashboardConfig config,
    SettingsNotifier notifier,
    DashboardLayout layout,
  ) {
    notifier.mutate(
      (s) => s.copyWith(
        dashboard: config.copyWith(
          pages: [
            for (var i = 0; i < config.pages.length; i++)
              if (i == _pageIndex)
                // Keep the rider's chosen fields where the new layout has room
                // for them and backfill from the layout's sensible default,
                // rather than discarding their work for switching shape.
                DashboardPage(
                  layout: layout,
                  fields: [
                    ...config.pages[i].fields.take(layout.capacity),
                    ...DashboardPage.defaultFor(layout)
                        .fields
                        .skip(config.pages[i].fields.length),
                  ],
                )
              else
                config.pages[i],
          ],
        ),
      ),
    );
  }

  void _setField(
    DashboardConfig config,
    SettingsNotifier notifier,
    int slot,
    DashboardField field,
  ) {
    notifier.mutate(
      (s) => s.copyWith(
        dashboard: config.copyWith(
          pages: [
            for (var i = 0; i < config.pages.length; i++)
              if (i == _pageIndex)
                DashboardPage(
                  layout: config.pages[i].layout,
                  fields: [
                    for (var j = 0;
                        j < config.pages[i].layout.capacity;
                        j++)
                      j == slot
                          ? field
                          : (j < config.pages[i].fields.length
                              ? config.pages[i].fields[j]
                              : DashboardField.speed),
                  ],
                )
              else
                config.pages[i],
          ],
        ),
      ),
    );
  }

  void _addPage(DashboardConfig config, SettingsNotifier notifier) {
    if (config.pages.length >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多 5 个页面')),
      );
      return;
    }
    notifier.mutate(
      (s) => s.copyWith(
        dashboard: config.copyWith(
          pages: [
            ...config.pages,
            DashboardPage.defaultFor(DashboardLayout.grid6),
          ],
        ),
      ),
    );
    setState(() => _pageIndex = config.pages.length);
  }

  void _removePage(DashboardConfig config, SettingsNotifier notifier) {
    final pages = [...config.pages]..removeAt(_pageIndex);
    notifier.mutate(
      (s) => s.copyWith(dashboard: config.copyWith(pages: pages)),
    );
    setState(() => _pageIndex = (_pageIndex - 1).clamp(0, pages.length - 1));
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 10),
      child: Text(text, style: AppText.sectionTitle),
    );
  }
}

class _PageTabs extends StatelessWidget {
  const _PageTabs({
    required this.pages,
    required this.selected,
    required this.onSelected,
  });

  final List<DashboardPage> pages;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: pages.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: ChoiceChip(
            selected: index == selected,
            onSelected: (_) => onSelected(index),
            label: Text('页面 ${index + 1}'),
            labelStyle: AppText.label.copyWith(
              color: index == selected ? Colors.black : AppColors.textSecondary,
            ),
            backgroundColor: Colors.transparent,
            selectedColor: AppColors.accent,
            side: const BorderSide(color: AppColors.hairline),
            showCheckmark: false,
          ),
        ),
      ),
    );
  }
}

class _LayoutOption extends StatelessWidget {
  const _LayoutOption({
    required this.layout,
    required this.selected,
    required this.onTap,
  });

  final DashboardLayout layout;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? AppColors.accent : AppColors.hairline,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                _LayoutDiagram(layout: layout, selected: selected),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(layout.label, style: AppText.body),
                      const SizedBox(height: 2),
                      Text(
                        '${layout.capacity} 个字段',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(Icons.check, size: 20, color: AppColors.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tiny diagram of the layout, so the choice is recognisable at a glance.
class _LayoutDiagram extends StatelessWidget {
  const _LayoutDiagram({required this.layout, required this.selected});

  final DashboardLayout layout;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textTertiary;

    Widget block(double flex, {bool outlined = false}) => Expanded(
          flex: (flex * 10).round(),
          child: Container(
            margin: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              color: outlined ? Colors.transparent : color.withValues(alpha: 0.55),
              border: outlined ? Border.all(color: color, width: 1) : null,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );

    return SizedBox(
      width: 34,
      height: 46,
      child: switch (layout) {
        DashboardLayout.hero2 => Column(
            children: [
              block(6),
              Expanded(
                child: Row(children: [block(1, outlined: true), block(1, outlined: true)]),
              ),
            ],
          ),
        DashboardLayout.hero4 => Column(
            children: [
              block(6),
              Expanded(
                child: Row(children: [block(1, outlined: true), block(1, outlined: true)]),
              ),
              Expanded(
                child: Row(children: [block(1, outlined: true), block(1, outlined: true)]),
              ),
            ],
          ),
        DashboardLayout.grid6 => Column(
            children: [
              for (var row = 0; row < 3; row++)
                Expanded(
                  child: Row(
                    children: [block(1, outlined: true), block(1, outlined: true)],
                  ),
                ),
            ],
          ),
      },
    );
  }
}

/// A live preview of the page being edited.
class _Preview extends StatelessWidget {
  const _Preview({required this.page, required this.formatter});

  final DashboardPage page;
  final UnitFormatter formatter;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      height: 240,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.hairlineStrong),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.hardEdge,
      child: DashboardView(
        page: page,
        data: DashboardData(stats: _sampleStats, gpsAccuracyMeters: 6),
        formatter: formatter,
      ),
    );
  }
}

/// The same representative numbers the OLED preview uses.
const RideStats _sampleStats = RideStats(
  distanceMeters: 23820,
  elapsed: Duration(hours: 1, minutes: 2, seconds: 36),
  moving: Duration(hours: 1, minutes: 2, seconds: 36),
  currentSpeedMps: 7.944,
  avgSpeedMps: 6.361,
  maxSpeedMps: 10.722,
  altitudeMeters: 62,
  elevationGainMeters: 384,
  elevationLossMeters: 372,
  gradePercent: 1.8,
);

class _FieldSlot extends StatelessWidget {
  const _FieldSlot({
    required this.index,
    required this.isHero,
    required this.current,
    required this.onChanged,
  });

  final int index;
  final bool isHero;
  final DashboardField current;
  final ValueChanged<DashboardField> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(
        isHero ? '主字段（大字）' : '字段 ${index + 1}',
        style: AppText.caption,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () => _pick(context),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: Text(current.label),
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final field = await showModalBottomSheet<DashboardField>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                isHero ? '选择主字段' : '选择字段',
                style: AppText.title,
              ),
            ),
            Expanded(
              child: ListView(
                controller: controller,
                children: [
                  for (final field in DashboardField.values)
                    ListTile(
                      title: Text(field.label),
                      subtitle: _subtitleFor(field),
                      selected: field == current,
                      selectedTileColor: AppColors.accentMuted,
                      trailing: field == current
                          ? const Icon(Icons.check,
                              size: 20, color: AppColors.accent)
                          : null,
                      // A field that cannot be the big number is not offered
                      // for the hero slot, rather than being offered and then
                      // quietly demoted.
                      enabled: !isHero || field.heroCapable,
                      onTap: () => Navigator.pop(context, field),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (field != null) onChanged(field);
  }

  static Widget? _subtitleFor(DashboardField field) {
    if (field.requiresSensor) {
      return const Text('需要连接传感器');
    }
    if (field.requiresRoute) {
      return const Text('仅在导航时显示');
    }
    if (!field.heroCapable) {
      return const Text('不适合作为主字段');
    }
    return null;
  }
}
