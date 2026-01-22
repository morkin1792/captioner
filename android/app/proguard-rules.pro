# Keep FFmpegKit classes to prevent R8/ProGuard from stripping them
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keep class com.arthenica.ffmpegkit.** { *; }
-keep class com.arthenica.smartexception.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}
