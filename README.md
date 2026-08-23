# BMP → TIFF Converter

Flutter app for batch BMP to TIFF conversion (Windows desktop, Android, and static web).

## Features

- Compression: ZIP/Deflate, LZW, None, JPEG
- Pixel order: interleaved / per-channel
- Optional image pyramid
- Parallel conversion (desktop / Android)
- Optional rename + archive BMPs (desktop / Android)
- Web: pick files/folder → convert → download ZIP

## Run

```bash
flutter pub get
flutter run -d windows
# or
flutter run -d chrome
# or (USB debugging / emulator)
flutter run -d android
```

## Release build (Windows)

```bash
flutter build windows --release
```

Output: `build/windows/x64/runner/Release/bmp2tif_app.exe`

## Windows installer (MSI)

Requires [WiX Toolset CLI](https://wixtoolset.org/) (`winget install --id WiXToolset.WiXCLI -e`).

```bash
powershell -File tool/build_msi.ps1
```

Output: `dist/Bmp2Tif.msi`

The script rebuilds the Flutter Windows release first. Pass `-SkipFlutter` if that build is already current.

## Rebuild GUI (Windows / Android / Web / MSI)

```bash
python tool/rebuild_gui.py
```

Or double-click `tool/rebuild_gui.bat`. Check the targets you want, then **Build selected**.


## Release build (Android)

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

On first use, grant **All files access** so the app can read BMP folders and write TIFFs (same workflow as desktop).

## Web / GitHub Pages

```bash
flutter build web --release --base-href "/bmp2tif/"
```

Pushing to `main` runs `.github/workflows/deploy-pages.yml` and publishes to the `gh-pages` branch.

Site: https://winston0323.github.io/bmp2tif/

In the repo: **Settings → Pages → Build and deployment → Source: Deploy from a branch → Branch: `gh-pages` / `/ (root)`**.
