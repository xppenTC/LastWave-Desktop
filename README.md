# LastWave Desktop — test builds (portable)

Windows x64, nothing to install: unzip anywhere and run `lastwave_desktop.exe`.
Close any other LastWave window first: the app runs as a single instance.
No `.env` in these builds: the lossless addons are disabled (YouTube playback is unaffected).

## `lastwave_1.5.0-backup_windows-x86_64-portable.zip` (latest)

Built from `feat/backup-file` (db751af) = upstream main bc87414 (CSV import already merged) +
Settings → General → **Backup & Restore**: export / restore the same backup file as the LastWave phone app.
KHInsider is **not** in this build.

SHA-256: B0958E6509A04D040C6E709C52AA98C3CDACE70CBB09DD739682F731DA2C7674

## `lastwave_1.5.0-csv-khinsider_windows-x86_64-portable.zip`

Built from `local/desktop-test` (0d967c1) = upstream main 807e872 +
- `feat/playlist-file-import` (ee9515f): Import playlist → "From file..." (CSV, M3U, text)
- `feat/khinsider` (b97a216): Search → "Video game soundtracks"

SHA-256: E362E21AE4E3EBF04B76C9C62271E60D435C81F3FE1E2276A003B9221DB90A8F
