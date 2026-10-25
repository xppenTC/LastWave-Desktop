# LastWave Desktop — test builds (portable)

Windows x64, nothing to install: unzip anywhere and run `lastwave_desktop.exe`.
Close any other LastWave window first: the app runs as a single instance.
No `.env` in these builds: the lossless addons are disabled (YouTube playback is unaffected).

## `lastwave_1.5.0-sync_windows-x86_64-portable.zip` (latest)

Built from `feat/backup-file` (3570022) = upstream main bc87414 (CSV import already merged) +
Settings → General → **Backup & Restore**:
- **Export backup**: writes the same backup file as the LastWave phone app.
- **Sync with file**: three-way merge with that shared file, written back for the phone
  (phone side: Backup & Restore → Sync with file, from the `feat/backup-sync` APK).
  The phone's local songs and its "Local songs" playlist are never imported here.

KHInsider is **not** in this build.

SHA-256: DDC6D0D0851CDE445A10F75EA101F518AB85B84DB5C1CACB96992E7EE69C7749

## `lastwave_1.5.0-csv-khinsider_windows-x86_64-portable.zip`

Built from `local/desktop-test` (0d967c1) = upstream main 807e872 +
- `feat/playlist-file-import` (ee9515f): Import playlist → "From file..." (CSV, M3U, text)
- `feat/khinsider` (b97a216): Search → "Video game soundtracks"

SHA-256: E362E21AE4E3EBF04B76C9C62271E60D435C81F3FE1E2276A003B9221DB90A8F
