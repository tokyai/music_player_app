# Flutter's generated plugin registrant calls plugin classes directly. Keep
# public plugin APIs and Android components that may be reached reflectively.
-keep public class io.flutter.plugins.** { *; }
-keep public class com.ryanheise.audioservice.** { *; }

# Sherpa-onnx and record load native code through their Android plugin APIs.
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keep class com.llfbandit.record.** { *; }

# Preserve JNI/native method names used by bundled libraries.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
