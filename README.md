# LastWave Desktop — test build (portable)

`lastwave_1.5.0-csv-khinsider_windows-x86_64-portable.zip` — Windows x64, nothing to install:
unzip anywhere and run `lastwave_desktop.exe`.

Built from `local/desktop-test` (0d967c1) = upstream main 807e872 +
- `feat/playlist-file-import` (ee9515f): Import playlist → "From file..." (CSV, M3U, text)
- `feat/khinsider` (b97a216): Search → "Video game soundtracks"

SHA-256: E362E21AE4E3EBF04B76C9C62271E60D435C81F3FE1E2276A003B9221DB90A8F

No `.env` in this build: the lossless addons are disabled (YouTube playback, KHInsider and imports are unaffected).
Close any other LastWave window first: the app runs as a single instance.
