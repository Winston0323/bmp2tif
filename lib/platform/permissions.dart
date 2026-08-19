import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'env.dart';

/// Ensures the app can list/read/write BMP folders on Android.
///
/// Folder rename, recursive listing, and writing TIFFs next to inputs need
/// broad storage access (SAF alone is not enough for dart:io paths).
Future<bool> ensureStorageAccess() async {
  if (kIsWeb || !isAndroid) return true;

  var manage = await Permission.manageExternalStorage.status;
  if (manage.isGranted) return true;

  manage = await Permission.manageExternalStorage.request();
  if (manage.isGranted) return true;

  // Android 12 and below may still grant classic storage.
  final storage = await Permission.storage.request();
  if (storage.isGranted) return true;

  if (manage.isPermanentlyDenied || manage.isDenied) {
    await openAppSettings();
  }
  return false;
}
