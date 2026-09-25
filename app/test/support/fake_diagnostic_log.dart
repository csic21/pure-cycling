import 'package:cycling_app/core/diagnostics/diagnostic_log.dart';

/// A diagnostic log that lives in memory.
///
/// Needed by any widget test that touches error handling, because the real one
/// writes to the file system — and real file IO never completes inside a
/// widget test's fake-async zone, so a screen waiting on it would look hung.
/// The file system itself is covered by the plain tests in
/// `diagnostic_log_test.dart`.
class FakeDiagnosticLog extends DiagnosticLog {
  String content = '';

  @override
  Future<void> init() async {}

  @override
  Future<void> error(String source, Object error, StackTrace? stack) async {
    content = '$content[$source] $error\n';
  }

  @override
  Future<String> read() async => content;

  @override
  Future<int> sizeBytes() async => content.length;

  @override
  Future<void> clear() async => content = '';
}
