# BMP → TIFF Converter

Flutter app for batch BMP to TIFF conversion (Windows desktop + static web).

## Features

- Compression: ZIP/Deflate, LZW, None, JPEG
- Pixel order: interleaved / per-channel
- Optional image pyramid
- Parallel conversion (desktop)
- Optional rename + archive BMPs (desktop)
- Web: pick files/folder → convert → download ZIP

## Run

```bash
flutter pub get
flutter run -d windows
# or
flutter run -d chrome
```

## Release build (Windows)

```bash
flutter build windows --release
```

Output: `build/windows/x64/runner/Release/bmp2tif_app.exe`

## Web / GitHub Pages

```bash
flutter build web --release --base-href "/bmp2tif/"
```

Pushing to `main` runs `.github/workflows/deploy-pages.yml` and publishes to the `gh-pages` branch.

Site: https://winston0323.github.io/bmp2tif/

In the repo: **Settings → Pages → Build and deployment → Source: Deploy from a branch → Branch: `gh-pages` / `/ (root)`**.
