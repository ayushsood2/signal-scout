# SignalScout (Flutter → Android APK)

This zip contains the **app code**. To build the APK on your machine:

1) Install Flutter + Android SDK. Run `flutter doctor` until all checks pass.
2) Create a Flutter project scaffold in this folder:
   ```bash
   flutter create .
   ```
   (This will generate android/ ios/ web/ etc. We already include `lib/` and `pubspec.yaml` here.)

3) Install deps:
   ```bash
   flutter pub get
   ```

4) Run on a device:
   ```bash
   flutter run -d android
   ```

5) Build a release APK:
   ```bash
   flutter build apk --release
   ```

The APK will be at:
```
build/app/outputs/flutter-apk/app-release.apk
```

### Notes
- Works **out of the box** using Alpha Vantage `demo` key (MSFT only). Add your own free key in *Settings* to scan any symbol.
- If you hit rate limits, wait a bit and tap **Refresh** (free tier is throttled).

### Optional: GitHub Actions (auto-build APK)
Push this repo to GitHub and the included workflow `.github/workflows/android.yml` will build a release APK and attach it as a downloadable artifact on each push to `main`.
