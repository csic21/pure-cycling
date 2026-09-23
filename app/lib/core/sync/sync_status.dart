/// Where a locally stored record stands relative to Supabase.
///
/// `localOnly` is the normal state of anything recorded while signed out — it
/// is not an error. Local storage is the source of truth: a record only
/// travels when the sync queue says so, and a failed upload never removes it.
enum SyncStatus {
  localOnly('local_only'),
  pendingUpload('pending_upload'),
  syncing('syncing'),
  synced('synced'),
  syncFailed('sync_failed');

  const SyncStatus(this.id);

  final String id;

  static SyncStatus fromId(String? id) => SyncStatus.values.firstWhere(
        (s) => s.id == id,
        orElse: () => SyncStatus.localOnly,
      );

  bool get isPending =>
      this == SyncStatus.pendingUpload || this == SyncStatus.syncFailed;

  /// Whether the cloud copy is authoritative. Never true — kept explicit so a
  /// future multi-device merge has a single place to change.
  bool get isCloudAuthoritative => false;

  String get label => switch (this) {
        SyncStatus.localOnly => '仅本地',
        SyncStatus.pendingUpload => '待上传',
        SyncStatus.syncing => '同步中',
        SyncStatus.synced => '已同步',
        SyncStatus.syncFailed => '同步失败',
      };
}

/// Kind of record tracked by the sync queue.
enum SyncEntityType {
  ride('ride'),
  route('route'),
  settings('settings');

  const SyncEntityType(this.id);

  final String id;

  static SyncEntityType fromId(String? id) => SyncEntityType.values.firstWhere(
        (t) => t.id == id,
        orElse: () => SyncEntityType.ride,
      );
}

enum SyncOperation {
  upsert('UPSERT'),
  delete('DELETE');

  const SyncOperation(this.id);

  final String id;

  static SyncOperation fromId(String? id) => SyncOperation.values.firstWhere(
        (o) => o.id == id,
        orElse: () => SyncOperation.upsert,
      );
}
