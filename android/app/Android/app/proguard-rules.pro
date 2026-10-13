-keeppackagenames **
-keep class skip.** { *; }
-keep class tools.skip.** { *; }
-keep class kotlin.jvm.functions.** {*;}
# Bridged throwing async calls return their coroutine Job, which Swift looks up by name over JNI
# (skipstone 1.9.13). From skiptools/skipstone#294 on (unreleased after 1.9.13), skipstone generates
# this rule itself.
-keep interface kotlinx.coroutines.Job { void cancel(java.util.concurrent.CancellationException); }
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
-keep class * implements com.sun.jna.** { *; }
-keep class * implements skip.bridge.** { *; }
-keep class **._ModuleBundleAccessor_* { *; }

# The Kotlin classes Swift reaches by name through SkipBridge's reflection (the composers,
# AndroidDocuments, AndroidPlatform): nothing in Kotlin references them, so R8 would drop them.
-keep class piru.module.** { *; }
