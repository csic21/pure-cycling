import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A small append-only record of the things that went wrong, and of what the
/// app did about them.
///
/// The app has no crash reporting on purpose — a location trace is the most
/// sensitive data it holds, and an SDK that ships stack traces to a third
/// party is a decision nobody asked for. What it does have is this file: the
/// rider can hand it over when something misbehaves, and nothing leaves the
/// device until they do.
///
/// Recoveries belong here as much as failures do. A location stream that dies
/// mid-ride is *invisible* from the Dart side — see `RideRecorder`'s watchdog —
/// so the only account of it is the line that says the stream was rebuilt and
/// how long it had been quiet. Without it, a trace with a hole in it has no
/// explanation.
///
/// Two rules shape every method:
///
/// * **It never throws.** A log that can take down the thing it is describing
///   is worse than no log. Every failure — no plugin, no space, a read-only
///   volume — degrades to doing nothing.
/// * **It writes only what it is given.** Exception text, and events reduced
///   to durations and sources. No positions, no ride data, nothing sampled
///   from the app's own state.
class DiagnosticLog {
  DiagnosticLog({this.maxBytes = 256 * 1024, Directory? directory})
      : _directory = directory;

  /// When the file grows past this, the oldest half is dropped. A rider who
  /// has been using the app for a year should not be carrying a megabyte of
  /// stack traces in their backups.
  final int maxBytes;

  /// Injected by tests, which have no `path_provider` plugin. Production
  /// resolves the app support directory on first write.
  final Directory? _directory;

  File? _file;

  /// Resolves the log file eagerly.
  ///
  /// `main` calls this before the app is built so the directory exists and the
  /// first real error is a write rather than a write plus a `mkdir`. It is
  /// safe to skip: every method resolves lazily anyway.
  Future<void> init() => _fileOrNull();

  /// Resolves the log file, if it can be resolved at all.
  Future<File?> _fileOrNull() async {
    final existing = _file;
    if (existing != null) return existing;

    try {
      final base = _directory ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/diagnostics');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/diagnostic.log');
      _file = file;
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Records one failure. Never throws.
  Future<void> error(String source, Object error, StackTrace? stack) async {
    final file = await _fileOrNull();
    if (file == null) return;

    try {
      final entry = StringBuffer()
        ..writeln('${DateTime.now().toUtc().toIso8601String()}  [$source]')
        ..writeln(error);
      if (stack != null) {
        entry.writeln(stack);
      }
      entry.writeln('----');

      await file.writeAsString(
        entry.toString(),
        mode: FileMode.append,
        flush: true,
      );
      await _trim(file);
    } catch (_) {
      // Nothing useful to do about a log that cannot be written.
    }
  }

  /// Drops the oldest entries when the file has grown too large.
  Future<void> _trim(File file) async {
    try {
      final length = await file.length();
      if (length <= maxBytes) return;

      final content = await file.readAsString();
      var tail = content.substring(content.length - maxBytes ~/ 2);
      // Start at a line boundary, so no entry is cut in half.
      final firstBreak = tail.indexOf('\n');
      if (firstBreak > 0) tail = tail.substring(firstBreak + 1);

      await file.writeAsString(tail, flush: true);
    } catch (_) {
      // A file we cannot trim is still a file we can append to.
    }
  }

  /// The whole log, or an empty string when there is nothing to read.
  Future<String> read() async {
    final file = await _fileOrNull();
    if (file == null) return '';
    try {
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<int> sizeBytes() async {
    final file = await _fileOrNull();
    if (file == null) return 0;
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  /// Forgets everything recorded so far.
  Future<void> clear() async {
    final file = await _fileOrNull();
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Already gone.
    }
  }
}
