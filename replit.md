# Running this project in Replit

The `Start application` workflow runs the existing React/Vite web app in the Replit preview. Treat that app as the feature and flow reference when updating Flutter for Android.

## Build the Flutter Android APK

This project requires Flutter 3.38.4 or newer, Java 17, and the Android SDK.

```sh
bash scripts/flutter.sh doctor -v
bash scripts/flutter.sh pub get
bash scripts/flutter.sh analyze
bash scripts/flutter.sh test
bash scripts/flutter.sh build apk --debug
```

The debug APK is written to `build/app/outputs/flutter-apk/app-debug.apk`. It is suitable for device testing, not Play Store release. The build helper stores Flutter, Android, Pub, and Gradle caches under the Git-ignored and deployment-ignored `.build/` directory to avoid filling the limited home cache. Set `FLUTTER_SDK`, `ANDROID_SDK_ROOT`, `PUB_CACHE`, or `GRADLE_USER_HOME` to override their locations.

## Change scope

Before changing app code, explain the diagnosis and minimal plan. Preserve existing behavior and design; change only what is needed for the requested fix.
