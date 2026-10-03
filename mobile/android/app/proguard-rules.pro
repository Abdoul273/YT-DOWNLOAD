# Filet de sécurité si la réduction R8 est réactivée : yt-dlp embarqué utilise la réflexion.
-keep class com.yausername.** { *; }
-keep class org.apache.commons.compress.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-dontwarn org.apache.commons.compress.**
-dontwarn com.fasterxml.jackson.**
