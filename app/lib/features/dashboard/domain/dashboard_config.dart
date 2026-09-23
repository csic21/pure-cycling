import 'dart:convert';

import 'dashboard_field.dart';

/// How a dashboard page arranges its fields.
///
/// V1 ships three fixed layouts (spec §6). Fully free-form placement is a V2
/// concern; these cover the hero-plus-supporting-numbers shape that a bike
/// computer actually needs, and they guarantee the hero number can never be
/// squeezed below the legibility floor.
enum DashboardLayout {
  /// One hero + two supporting values.
  hero2('hero_2', 3, '1 大 + 2 小'),

  /// One hero + four supporting values. The default.
  hero4('hero_4', 5, '1 大 + 4 小'),

  /// Six equal values in two columns. No hero.
  grid6('grid_6', 6, '2 × 3');

  const DashboardLayout(this.id, this.capacity, this.label);

  final String id;

  /// Exact number of fields this layout renders. Not a maximum: a page whose
  /// field list is short is padded with `--` tiles so the geometry stays put.
  final int capacity;

  final String label;

  static DashboardLayout fromId(String? id) => DashboardLayout.values.firstWhere(
        (l) => l.id == id,
        orElse: () => DashboardLayout.hero4,
      );
}

/// One swipeable page of the dashboard.
class DashboardPage {
  const DashboardPage({required this.layout, required this.fields});

  final DashboardLayout layout;
  final List<DashboardField> fields;

  /// Fields padded or trimmed to exactly [DashboardLayout.capacity] entries.
  ///
  /// Padding with the last field rather than a null keeps the renderer free of
  /// null handling; `isAvailable` already reports unavailable fields as `--`.
  List<DashboardField> resolvedFields() {
    final cap = layout.capacity;
    final out = <DashboardField>[];
    for (var i = 0; i < cap; i++) {
      out.add(i < fields.length ? fields[i] : DashboardField.speed);
    }
    return out;
  }

  /// The field rendered at hero size, or null for [DashboardLayout.grid6].
  DashboardField? get heroField {
    if (layout == DashboardLayout.grid6 || fields.isEmpty) return null;
    return fields.first.heroCapable ? fields.first : null;
  }

  /// Fields laid out beneath the hero (or all fields, for the grid layout).
  List<DashboardField> supportingFields() {
    if (layout == DashboardLayout.grid6) return resolvedFields();
    final heroCount = heroField == null ? 0 : 1;
    return resolvedFields().skip(heroCount).toList();
  }

  DashboardPage copyWith({DashboardLayout? layout, List<DashboardField>? fields}) =>
      DashboardPage(
        layout: layout ?? this.layout,
        fields: fields ?? this.fields,
      );

  Map<String, dynamic> toJson() => {
        'layout': layout.id,
        'fields': fields.map((f) => f.id).toList(),
      };

  static DashboardPage fromJson(Map<String, dynamic> json) {
    final layout = DashboardLayout.fromId(json['layout'] as String?);
    final raw = (json['fields'] as List?) ?? const [];
    final fields = <DashboardField>[];
    for (final entry in raw) {
      final f = DashboardField.fromId(entry.toString());
      if (f != null) fields.add(f);
    }
    return DashboardPage(
      layout: layout,
      fields: fields.isEmpty ? defaultFor(layout).fields : fields,
    );
  }

  static DashboardPage defaultFor(DashboardLayout layout) => switch (layout) {
        DashboardLayout.hero2 => const DashboardPage(
            layout: DashboardLayout.hero2,
            fields: [
              DashboardField.speed,
              DashboardField.distance,
              DashboardField.movingTime,
            ],
          ),
        DashboardLayout.hero4 => const DashboardPage(
            layout: DashboardLayout.hero4,
            fields: [
              DashboardField.speed,
              DashboardField.distance,
              DashboardField.movingTime,
              DashboardField.avgSpeed,
              DashboardField.elevationGain,
            ],
          ),
        DashboardLayout.grid6 => const DashboardPage(
            layout: DashboardLayout.grid6,
            fields: [
              DashboardField.speed,
              DashboardField.avgSpeed,
              DashboardField.distance,
              DashboardField.movingTime,
              DashboardField.altitude,
              DashboardField.elevationGain,
            ],
          ),
      };
}

/// The full multi-page dashboard definition.
class DashboardConfig {
  const DashboardConfig({required this.pages});

  final List<DashboardPage> pages;

  /// Page 1 — the default ride screen (spec §5.1).
  ///
  /// Speed is the hero, then the four numbers a rider checks most: how far,
  /// how long, how fast on average, how much climbing.
  static const DashboardConfig defaults = DashboardConfig(
    pages: [
      DashboardPage(
        layout: DashboardLayout.hero4,
        fields: [
          DashboardField.speed,
          DashboardField.distance,
          DashboardField.movingTime,
          DashboardField.avgSpeed,
          DashboardField.elevationGain,
        ],
      ),
      // Page 2 — terrain.
      DashboardPage(
        layout: DashboardLayout.hero4,
        fields: [
          DashboardField.altitude,
          DashboardField.grade,
          DashboardField.elevationGain,
          DashboardField.elevationLoss,
          DashboardField.maxSpeed,
        ],
      ),
      // Page 3 — sensors. Renders `--` throughout until a strap or meter is
      // paired, which is exactly the affordance we want.
      DashboardPage(
        layout: DashboardLayout.grid6,
        fields: [
          DashboardField.heartRate,
          DashboardField.cadence,
          DashboardField.power,
          DashboardField.avgHeartRate,
          DashboardField.avgCadence,
          DashboardField.avgPower,
        ],
      ),
    ],
  );

  DashboardConfig copyWith({List<DashboardPage>? pages}) =>
      DashboardConfig(pages: pages ?? this.pages);

  String encode() => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {
        'pages': pages.map((p) => p.toJson()).toList(),
      };

  static DashboardConfig decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return defaults;
      return fromJson(decoded);
    } on FormatException {
      // A corrupt config must not brick the ride screen. Fall back silently;
      // the user can still edit and re-save.
      return defaults;
    }
  }

  static DashboardConfig fromJson(Map<String, dynamic> json) {
    final rawPages = json['pages'];
    if (rawPages is! List || rawPages.isEmpty) return defaults;
    final pages = <DashboardPage>[];
    for (final p in rawPages) {
      if (p is Map<String, dynamic>) pages.add(DashboardPage.fromJson(p));
    }
    return pages.isEmpty ? defaults : DashboardConfig(pages: pages);
  }
}
