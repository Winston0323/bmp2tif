import 'package:flutter/foundation.dart';

bool get isWeb => kIsWeb;

bool get isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

bool get isMobile => isAndroid || isIOS;

/// Desktop-class file system features (rename on disk, zip-delete, folder walk).
bool get supportsDesktopFs => !kIsWeb && !isMobile;
