import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A failure the rider can act on.
///
/// Two lines: what happened, and what to do about it. Deliberately without the
/// raw exception — that goes to the diagnostic log (see `FailureReporter`),
/// which can be exported and read. Showing it here would turn a recoverable
/// problem into reading practice.
class ErrorNotice extends StatelessWidget {
  const ErrorNotice({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final String title;
  final String message;

  /// Offered only where trying again can plausibly work — a database read, a
  /// network call. Never shown beside a validation error.
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 40,
              color: AppColors.danger,
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: AppText.title,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The same message in a row, for forms and sheets where a centred block would
/// push the content around.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppText.caption.copyWith(color: AppColors.danger),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onRetry,
              child: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// The one-line form: a snackbar that says what happened and points at the log.
///
/// Used where the action failed but the screen is still valid — an export, a
/// rename, a share.
void showFailureSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
