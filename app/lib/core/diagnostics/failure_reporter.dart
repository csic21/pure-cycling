import 'dart:async';

import 'diagnostic_log.dart';

/// The single place a caught failure becomes a sentence the rider sees.
///
/// The rule it enforces is a division of labour:
///
/// * **The screen says what to do.** One sentence, in the language of the
///   problem, plus a way to try again where that makes sense.
/// * **The log keeps the details.** The exception and its stack go to the
///   diagnostic file, where they can be exported and read. On the screen they
///   are noise that makes a recoverable problem look fatal.
///
/// Before this existed, ten call sites interpolated the raw exception into
/// their message (`'读取失败：$e'`). A rider got `SqliteException(11): database
/// disk image is malformed` and no idea what to do, and the one piece of
/// information that would have helped support was the only thing missing from
/// the record.
class FailureReporter {
  const FailureReporter(this._log);

  final DiagnosticLog _log;

  /// Records [error] under [source] and returns the message to show.
  ///
  /// [message] has to say what happens next — 「重试」, 「换一个文件」,
  /// 「在设置里检查」. Logging is fire-and-forget: a failure the rider has
  /// already been told about must not block on a disk write.
  String report(
    String source,
    Object error, {
    required String message,
    StackTrace? stack,
  }) {
    unawaited(_log.error(source, error, stack));
    return message;
  }
}
