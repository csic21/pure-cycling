# R8 rules for release builds.
#
# Minification is on in release because that is the build riders will actually
# run for four hours in the sun, and it is the only configuration where a
# missing keep-rule shows up. Everything below is a class the app reaches
# reflectively — through JSON serialization, through drift's generated code, or
# through a plugin's platform channel.

# ---------------------------------------------------------------------------
# Supabase / PostgREST
#
# PostgrestBuilder decodes responses with `jsonDecode` and hands the result to
# caller-supplied converters; the auth package reads its session out of a
# serialized blob. Both survive on field names, not on static types.
# ---------------------------------------------------------------------------
-keep class io.supabase.** { *; }
-keepclassmembers class io.supabase.** { *; }
-dontwarn io.supabase.**

# ---------------------------------------------------------------------------
# Drift / SQLite
#
# Drift's generated companions and the sqlite3 ffi bindings are reached by
# name. Shrinking the generated table classes breaks queries at runtime with a
# missing-column error rather than at build time, which is exactly the failure
# that is worst to debug.
# ---------------------------------------------------------------------------
-keep class com.cycling_app.** { *; }
-keep class ** extends drift.** { *; }
-keepclassmembers class * extends drift.** { *; }
-dontwarn drift.**
-keep class org.sqlite.** { *; }
-keep class com.tekartik.sqflite.** { *; }
-dontwarn org.sqlite.**

# ---------------------------------------------------------------------------
# flutter_blue_plus
#
# Scans for services by UUID and reflects over characteristic write types.
# ---------------------------------------------------------------------------
-keep class com.lib.flutter_blue_plus.** { *; }
-dontwarn com.lib.flutter_blue_plus.**

# ---------------------------------------------------------------------------
# Plugins with reflection or platform-channel class lookups.
# ---------------------------------------------------------------------------
-keep class com.baseflow.geolocator.** { *; }
-dontwarn com.baseflow.geolocator.**
-keep class dev.fluttercommunity.plus.** { *; }
-dontwarn dev.fluttercommunity.plus.**

# ---------------------------------------------------------------------------
# Flutter embedding
# ---------------------------------------------------------------------------
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Keep annotations and generic signatures used by serialization frameworks.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# Useful line numbers in a crash report from the field.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
