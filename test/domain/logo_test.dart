import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/domain/logo.dart';

Uint8List bytes(List<int> head, {int length = 64}) {
  final out = Uint8List(length);
  for (var i = 0; i < head.length; i++) {
    out[i] = head[i];
  }
  return out;
}

final jpeg = bytes([0xFF, 0xD8, 0xFF, 0xE0]);
final png = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

void main() {
  group('what a picture really is', () {
    test('a JPEG and a PNG are recognised by their first bytes', () {
      expect(sniffLogoFormat(jpeg), LogoFormat.jpeg);
      expect(sniffLogoFormat(png), LogoFormat.png);
    });

    test('anything else is refused, whatever it was called', () {
      expect(sniffLogoFormat(bytes([0x47, 0x49, 0x46, 0x38])), isNull, // GIF
          reason: 'the PDF renderer cannot draw a GIF');
      expect(sniffLogoFormat(bytes([0x3C, 0x73, 0x76, 0x67])), isNull); // <svg
      expect(sniffLogoFormat(bytes([0x25, 0x50, 0x44, 0x46])), isNull); // %PDF
      expect(sniffLogoFormat(bytes([])), isNull);
    });

    test('a file too short to hold its own header is not a picture', () {
      expect(sniffLogoFormat(Uint8List.fromList([0xFF, 0xD8])), isNull);
      expect(
        sniffLogoFormat(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
        isNull,
      );
    });

    test('a PNG header with one wrong byte is not a PNG', () {
      final almost = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B]);
      expect(sniffLogoFormat(almost), isNull);
    });
  });

  group('whether it can be the logo', () {
    test('a small JPEG or PNG is fine', () {
      expect(logoProblem(jpeg), isNull);
      expect(logoProblem(png), isNull);
    });

    test('empty, oversized and wrong-type each say why', () {
      expect(logoProblem(Uint8List(0)), contains('empty'));
      expect(
        logoProblem(bytes([0xFF, 0xD8, 0xFF], length: maxLogoBytes + 1)),
        contains('too large'),
      );
      expect(logoProblem(bytes([0x47, 0x49, 0x46])), contains('JPEG or PNG'));
    });

    test('exactly the limit is allowed', () {
      expect(
        logoProblem(bytes([0xFF, 0xD8, 0xFF], length: maxLogoBytes)),
        isNull,
      );
    });
  });
}
