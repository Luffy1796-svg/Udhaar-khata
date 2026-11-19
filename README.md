# Mera Khata — Flutter Android source

An offline-first customer credit ledger for small shops.

## Included
- Customer records: name, mobile, optional photo, address
- Search by customer name or mobile number
- Add credit / udhaar entries and receive partial payments
- Automatically calculated customer balance
- Transaction history with date, amount, method and note
- Optional due date on credit entries
- Cash, UPI, bank transfer and other payment labels
- Customer statement sharing
- Dashboard totals and reports
- App PIN gate
- JSON backup export using Android share sheet
- SQLite local storage; no account or internet connection required

## Build an Android APK
1. Install Flutter stable and Android Studio (including Android SDK).
2. Unzip this project.
3. In the project folder run:

   ```bash
   flutter create . --platforms=android
   flutter pub get
   flutter run
   ```

4. To build a release APK:

   ```bash
   flutter build apk --release
   ```

   APK output: `build/app/outputs/flutter-apk/app-release.apk`

## Android permissions / setup
`image_picker` uses Android's system photo picker. No broad photo-library permission is required for the standard Android picker. The generated Flutter Android project supplies the standard Android manifest and Gradle wrapper.

## Important production notes
- This source bundle is not a signed APK. It must be built with Flutter/Android SDK.
- Test on real devices before using it for actual shop accounts.
- Current backup feature exports a JSON backup. Restore/import UI, automatic cloud backup, transaction correction/deletion, customer deletion, and date-filtered daily reports are planned follow-up work and are not represented as completed.
- PIN is a basic local app gate, not high-assurance device security. For public release, use secure hashing / Android Keystore and add recovery flow.
- Customer photo paths are local to the phone. If the app is reinstalled or photos are moved, the photo may need to be selected again.
- Keep backup files secure because they contain customer contact and financial records.
