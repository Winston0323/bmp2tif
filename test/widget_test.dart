import 'package:flutter_test/flutter_test.dart';

import 'package:bmp2tif_app/main.dart';

void main() {
  testWidgets('App loads', (tester) async {
    await tester.pumpWidget(const Bmp2TifApp());
    expect(find.textContaining('BMP'), findsWidgets);
  });
}
