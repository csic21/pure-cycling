import 'package:cycling_app/core/sync/supabase_config.dart';
import 'package:cycling_app/features/auth/data/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
// `AuthException` comes through supabase_flutter rather than a direct
// dependency on gotrue: it is the same type, and depending on the transport
// package directly would pin a version the SDK is free to move.
// `show` because the SDK also exports a type called `AuthUser`, and this
// file's own `AuthUser` is the one under test.
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

/// The parts of authentication that can be verified without a Supabase project.
///
/// The network calls are not tested here — they are the SDK's job, and a test
/// that needs a live project is a test that fails when the project is asleep.
/// What is tested is the logic this app owns: the redirect configuration, the
/// account labelling, and the translation of Supabase's error strings into
/// something a rider can act on.
void main() {
  group('redirect configuration', () {
    test('is a valid custom-scheme URL', () {
      // Supabase validates this format and rejects anything it cannot parse,
      // with an error that appears at sign-up rather than at build time.
      final uri = Uri.parse(SupabaseConfig.redirectUrl);

      expect(uri.scheme, SupabaseConfig.redirectScheme);
      expect(uri.host, SupabaseConfig.redirectPath);
      expect(uri.hasScheme, isTrue);
      expect(uri.query, isEmpty);
    });

    test('the scheme matches what the platforms register', () {
      // These three have to agree or the link opens a browser instead of the
      // app: the constant here, `CFBundleURLSchemes` in the Info.plists, and
      // the `android:scheme` in the manifest. The platform files cannot be
      // read from a unit test, so this asserts the value the others must
      // carry — see docs/auth.md for the checklist.
      expect(SupabaseConfig.redirectScheme, 'purecycling');
      expect(SupabaseConfig.redirectUrl, 'purecycling://login-callback');
    });

    test('lists exactly what a Supabase project has to allow', () {
      expect(SupabaseConfig.requiredRedirectUrls, [SupabaseConfig.redirectUrl]);
      expect(SupabaseConfig.requiredRedirectUrls, isNotEmpty);
    });
  });

  group('account labelling', () {
    test('prefers a display name over an address', () {
      const user = AuthUser(
        id: 'u1',
        email: 'rider@example.com',
        displayName: '小林',
      );
      expect(user.label, '小林');
    });

    test('ignores a blank display name', () {
      const user = AuthUser(
        id: 'u1',
        email: 'rider@example.com',
        displayName: '   ',
      );
      expect(user.label, 'rider@example.com');
    });

    test('falls back to the address, then to a description of the account', () {
      expect(
        const AuthUser(id: 'u1', email: 'rider@example.com').label,
        'rider@example.com',
      );
      // An anonymous account has no address to show, and "已登录" would be
      // misleading — it is the one state where the rider cannot sign back in.
      expect(const AuthUser(id: 'u1', isAnonymous: true).label, '匿名账号');
      expect(const AuthUser(id: 'u1').label, '已登录');
    });

    test('an account is not anonymous unless it says so', () {
      // The default matters: getting it wrong in this direction shows an
      // "attach an email" prompt to somebody who already has one.
      expect(const AuthUser(id: 'u1').isAnonymous, isFalse);
    });
  });

  group('error translation', () {
    String describe(String message, {String? statusCode}) =>
        AuthRepository.describeAuthError(
          AuthException(message, statusCode: statusCode),
        );

    test('the two failures a rider actually hits are explained', () {
      expect(
        describe('User already registered'),
        contains('已被注册'),
        reason: 'signing up with an address that already has an account',
      );
      expect(
        describe('Email not confirmed'),
        contains('验证'),
        reason: 'trying to sign in before following the confirmation link',
      );
      expect(
        describe('Invalid login credentials'),
        '邮箱或密码不正确',
      );
    });

    test('an address already attached to another account is explained', () {
      // This is what `attachEmail` hits when the rider tries to bind an
      // address that belongs to a different account — the one failure in that
      // flow they can actually do something about.
      expect(
        describe(
          'A user with this email address has already been registered',
        ),
        contains('已被注册'),
      );
    });

    test('a malformed address is distinguished from a taken one', () {
      expect(describe('Unable to validate email address: invalid format'),
          contains('格式'));
    });

    test('rate limiting and network failures are explained', () {
      expect(describe('Email rate limit exceeded'), contains('频繁'));
      expect(describe('Request rate limit reached', statusCode: '429'),
          contains('频繁'));
      expect(describe('SocketException: failed host lookup'),
          contains('网络'));
    });

    test('a missing session says to sign in again', () {
      expect(
        describe('Auth session missing!'),
        contains('重新登录'),
        reason: 'a token that expired while the app was backgrounded',
      );
    });

    test('an unrecognised message passes through rather than being swallowed',
        () {
      // Flattening an unknown error into "登录失败" leaves a rider with
      // nothing to report. An English one is at least diagnosable.
      expect(
        describe('Something new the SDK started saying'),
        'Something new the SDK started saying',
      );
    });

    test('every mapping produces something non-empty', () {
      // A mapping that returned '' would render as a blank error box.
      for (final message in const [
        'Invalid login credentials',
        'Email not confirmed',
        'User already registered',
        'Email rate limit exceeded',
        'Auth session missing!',
        'totally unrecognised',
      ]) {
        expect(describe(message), isNotEmpty);
      }
    });
  });

  group('AuthFailure', () {
    test('renders as its message rather than as a type name', () {
      // It reaches a SnackBar, where `Instance of 'AuthFailure'` would be the
      // default.
      const failure = AuthFailure('邮箱或密码不正确');
      expect(failure.toString(), '邮箱或密码不正确');
    });

    test('carries whether the cause is configuration', () {
      // The distinction the UI branches on: a missing key sends the rider to
      // settings, a transient failure offers a retry.
      const config = AuthFailure('未配置', isConfiguration: true);
      const transient = AuthFailure('网络不可用');

      expect(config.isConfiguration, isTrue);
      expect(transient.isConfiguration, isFalse);
    });
  });
}
