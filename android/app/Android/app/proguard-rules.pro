-keeppackagenames **
-keep class skip.** { *; }
-keep class tools.skip.** { *; }
-keep class kotlin.jvm.functions.** {*;}
# Bridged throwing async calls return their coroutine Job, which Swift looks up by name over JNI
# (skipstone 1.9.13; Skip's own project template carries this rule after 1.9.13).
-keep interface kotlinx.coroutines.Job { void cancel(java.util.concurrent.CancellationException); }
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
-keep class * implements com.sun.jna.** { *; }
-keep class * implements skip.bridge.** { *; }
-keep class **._ModuleBundleAccessor_* { *; }

# The Kotlin classes Swift reaches by name through SkipBridge's reflection (the composers,
# AndroidDocuments, AndroidPlatform): nothing in Kotlin references them, so R8 would drop them.
-keep class piru.module.** { *; }
