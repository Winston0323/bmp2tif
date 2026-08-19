// Generates the sample BMP fixtures used by self_test.dart and
// test_manager.dart. Run with: dart run tool/gen_test_assets.dart
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final dir = Directory('test_assets');
  dir.createSync(recursive: true);

  void writeBmp(String name, int w, int h) {
    final image = img.Image(width: w, height: h, numChannels: 3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        image.setPixelRgb(x, y, (x * 3 + y) & 0xFF, (y * 5 + x) & 0xFF, ((x + y) * 7) & 0xFF);
      }
    }
    File('${dir.path}/$name').writeAsBytesSync(img.encodeBmp(image));
    print('wrote ${dir.path}/$name ($w x $h)');
  }

  writeBmp('sample1.bmp', 130, 97);
  writeBmp('sample2.bmp', 300, 200);
  File('${dir.path}/bad.bmp').writeAsBytesSync([0x42, 0x4D, 1, 2, 3]);
  print('wrote ${dir.path}/bad.bmp (intentionally corrupt)');
}
