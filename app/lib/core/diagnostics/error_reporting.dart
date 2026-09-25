import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'diagnostic_log.dart';

/// What the app shows when a widget build throws.
///
/// Assigned to [ErrorWidget.builder] in `main`, which means it has to work
/// with no MaterialApp, no Theme, no Directionality and no Localizations above
/// it — the exception it is reporting might be the very thing that would have
/// provided them. So it is a bare `ColoredBox` with explicit text styles.
///
/// The message has one job: tell the rider whether their ride is safe. It is
/// — recording runs in the recorder and the database, neither of which cares
/// that a widget failed to build — and saying so is the difference between a
/// scary screen and a lost afternoon.
Widget buildFatalErrorView(FlutterErrorDetails details) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '界面出错了',
                style: TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '骑行记录不受影响：数据由记录器直接写入本机数据库。'
                '重启后如果看到「发现未完成的骑行」，可以继续。',
                style: TextStyle(
                  color: Color(0xFFA8ADB4),
                  fontSize: 14,
                  height: 1.5,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '错误详情已写入诊断日志，可在「设置 → 诊断日志」中导出。',
                style: TextStyle(
                  color: Color(0xFF6B7075),
                  fontSize: 12,
                  height: 1.5,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _firstLine(details.exceptionAsString()),
                style: const TextStyle(
                  color: Color(0xFF6B7075),
                  fontSize: 11,
                  fontFamily: 'monospace',
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The error's headline, not its whole story — a paragraph of stack trace on a
/// phone screen is noise, and the file has the rest.
String _firstLine(String text) {
  final breakIndex = text.indexOf('\n');
  final line = breakIndex == -1 ? text : text.substring(0, breakIndex);
  return line.length > 160 ? '${line.substring(0, 160)}…' : line;
}

/// Wires the three places an uncaught error can surface, and keeps a record.
///
/// Called once from `main`, before the app is built, so that anything that
/// fails during the first frame is already covered.
void installErrorHandlers(DiagnosticLog log) {
  FlutterError.onError = (details) {
    log.error('flutter', details.exception, details.stack);
    // Still print in debug — the console is where a developer looks first.
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.error('platform', error, stack);
    // Handled: returning false here would let the error take the isolate down.
    return true;
  };

  ErrorWidget.builder = buildFatalErrorView;
}
