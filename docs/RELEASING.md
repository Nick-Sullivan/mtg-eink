# Releasing to Google Play

Every push to `main` (except docs-only changes) runs `.github/workflows/release.yml`: analyze,
test, build a signed bundle, upload to the Play **internal testing** track. Production is manual:
Actions → *Deploy to Google Play* → Run workflow → `production`.

Version names and codes are automatic (`YYYY.MM.DD.<run>`, code `1000 + run`). Nothing to bump.

## One-time setup

The upload keystore and Play service account are shared with `scryfall_app`.

1. **GitHub secrets** (repo → Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `GOOGLE_PLAY_KEYSTORE_BASE64` | base64 of `upload-keystore.jks` |
   | `GOOGLE_PLAY_KEYSTORE_PASSWORD` | keystore password (also used for the key) |
   | `GOOGLE_PLAY_KEYSTORE_ALIAS` | `upload` |
   | `GOOGLE_PLAY_SERVICE_KEY` | full contents of the service account JSON key |

   Base64 on Windows:
   `[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks")) | Set-Clipboard`

2. **Play Console → Create app.** App, Free. The package name `com.nicksullivan.mtg_eink` gets
   fixed by the first upload and can never change.

3. **Grant the service account access** to the new app: Play Console → Users and permissions →
   the service account → Manage → *App permissions* → add mtg-eink with release permissions.

4. **App content** (Play Console → Policy → App content): privacy policy URL (see below), app
   access (all features available without login), ads (none), content rating questionnaire,
   target audience (not children), data safety (no data collected or shared).

5. **Store listing**: name (30 chars), short description (80), full description, 512×512 icon,
   1024×500 feature graphic, at least 2 phone screenshots.

6. **Upload the first bundle by hand.** Play won't accept API uploads until a first release exists.
   Put `upload-keystore.jks` in `android/` and create `android/key.properties` (both gitignored):

   ```properties
   storeFile=upload-keystore.jks
   storePassword=...
   keyAlias=upload
   keyPassword=...
   ```

   Then `flutter build appbundle --release --build-number=1`, and in Play Console → Testing →
   Internal testing → Create release, upload
   `build/app/outputs/bundle/release/app-release.aab` and roll it out. Accept Play App Signing
   when asked. Keep the build number below 1000 so CI's codes stay higher.

7. From then on, push to `main`.

## Privacy policy

[privacy-policy.html](privacy-policy.html), served by GitHub Pages (repo → Settings →
Pages → deploy from `main`, folder `/docs`) at
`https://nick-sullivan.github.io/mtg-eink/privacy-policy.html`. Fill in the contact email first.

## Troubleshooting

- **`Package not found`**: the app doesn't exist yet, the first bundle hasn't been uploaded, or
  the service account hasn't been given access to this app (step 3).
- **`Only releases with status draft may be created on draft app`**: the first release (step 6)
  hasn't been rolled out yet.
- **`Version code has already been used`**: raise `VERSION_CODE_BASE` in the workflow.
