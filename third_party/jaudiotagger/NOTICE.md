# Jaudiotagger for Android

- License: GNU LGPL 2.1 or later; see `LGPL-2.1.txt`.
- Original authors: Paul Taylor and contributors; portions originate from the Entagged Audio Tag library, copyright 2003-2005 Raphael Slinckx.
- Android adaptation and source: https://github.com/hexise/jaudiotagger-android (based on Jaudiotagger 2.2.6). A source archive is included as `source.zip`.
- Integration reference: https://github.com/kingmuchen/Mint-Music/blob/main/android/app/libs/jaudiotagger-android.jar
- Our binary is rebuilt from the included, unmodified source archive using JDK 17 (`-source 8 -target 8`) against Android API 34, with the LGPL text added to the JAR.
- Binary SHA-256: `8128f53f67ec5e0d6643a36b2fa857254c9a893d11ffa482259e48224f5f786d`.
- Source ZIP SHA-256: `4f1499e72489ae94b133ec4656b2e7550fd445f66c95cfba514a185c9fa4613c`.

The library is used only to tag application-owned downloaded copies. It is a separate Gradle file dependency at `android/app/libs/jaudiotagger-android.jar`, and can be replaced and the application rebuilt. The source archive contains the Android-compatible Java sources; compile them against an Android SDK `android.jar` to rebuild the library. No library sources were modified here.
