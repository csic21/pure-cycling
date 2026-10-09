import 'dart:async';
import 'dart:io';

import 'package:cycling_app/core/updates/apk_updater.dart';
import 'package:cycling_app/core/updates/github_release_checker.dart';
import 'package:cycling_app/core/updates/update_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _HeldUpdater extends ApkUpdater {
  final result = Completer<File>();
  bool closed = false;
  @override
  Future<File> download(
    Uri url, {
    void Function(int received, int? total)? onProgress,
    Directory? destination,
  }) => result.future;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// The widget tests exercise route ownership. Real disk/stream behavior is
/// covered in apk_updater_test; native filesystem Futures do not belong in
/// the widget binding's fake event loop.
class _DownloadedFile implements File {
  bool deleted = false;
  @override
  Future<bool> exists() async => !deleted;
  @override
  Future<File> delete({bool recursive = false}) async {
    deleted = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final release = AppRelease(
    version: '0.1.18',
    tag: 'v0.1.18',
    notes: '更新说明',
    pageUrl: Uri.parse(
      'https://github.com/csic21/pure-cycling/releases/tag/v0.1.18',
    ),
    androidApkUrl: Uri.parse(
      'https://github.com/csic21/pure-cycling/releases/download/v0.1.18/app.apk',
    ),
  );
  // Flutter's test binding defaults to Android. Avoid overriding a debug
  // global in setUp: the binding verifies globals before tearDown runs.

  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('About'));
          },
        ),
      ),
    );
    return context;
  }

  testWidgets('late download removes only its own route, never a newer page', (
    tester,
  ) async {
    final context = await host(tester);
    final updater = _HeldUpdater();
    var installs = 0;
    final pending = presentAppUpdate(
      context,
      release: release,
      automatic: false,
      canPresent: () => true,
      createUpdater: () => updater,
      install: (_, _) async {
        installs++;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在下载更新'), findsOneWidget);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Newer route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final file = _DownloadedFile();
    updater.result.complete(file);
    await tester.pumpAndSettle();
    await pending;
    expect(find.text('Newer route'), findsOneWidget);
    expect(installs, 0);
    expect(file.deleted, isTrue);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(find.text('About'), findsOneWidget);
    expect(find.text('正在下载更新'), findsNothing);
  });

  testWidgets(
    'Cancel closes transport and a late successful file never installs',
    (tester) async {
      final context = await host(tester);
      final updater = _HeldUpdater();
      var installs = 0;
      final pending = presentAppUpdate(
        context,
        release: release,
        automatic: false,
        canPresent: () => true,
        createUpdater: () => updater,
        install: (_, _) async {
          installs++;
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('安装更新'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await pending;
      expect(updater.closed, isTrue);
      final file = _DownloadedFile();
      updater.result.complete(file);
      await tester.pumpAndSettle();
      expect(installs, 0);
      expect(file.deleted, isTrue);
      expect(find.text('About'), findsOneWidget);
    },
  );

  testWidgets('recording or backgrounding during download blocks installer', (
    tester,
  ) async {
    final context = await host(tester);
    final updater = _HeldUpdater();
    var eligible = true;
    var installs = 0;
    final pending = presentAppUpdate(
      context,
      release: release,
      automatic: false,
      canPresent: () => eligible,
      createUpdater: () => updater,
      install: (_, _) async {
        installs++;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    eligible = false;
    final file = _DownloadedFile();
    updater.result.complete(file);
    await tester.pumpAndSettle();
    await pending;
    expect(installs, 0);
    expect(file.deleted, isTrue);
  });
  testWidgets('Back cancels the owned download route without installing', (
    tester,
  ) async {
    final context = await host(tester);
    final updater = _HeldUpdater();
    var installs = 0;
    final pending = presentAppUpdate(
      context,
      release: release,
      automatic: false,
      canPresent: () => true,
      createUpdater: () => updater,
      install: (_, _) async {
        installs++;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await Navigator.of(context).maybePop();
    await tester.pumpAndSettle();
    await pending;
    expect(updater.closed, isTrue);
    updater.result.completeError(const ApkUpdateCancelled());
    await tester.pump();
    expect(installs, 0);
    expect(find.text('About'), findsOneWidget);
  });
}
