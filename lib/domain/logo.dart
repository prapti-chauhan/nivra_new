/// Rules for the shop logo. Pure Dart.
///
/// The logo goes on every bill that leaves the shop and is fetched from a
/// server, so nothing is trusted on its say-so: bytes are accepted only if they
/// actually start like a JPEG or a PNG, and only if they are small. A logo that
/// the PDF renderer cannot decode would otherwise fail every bill.
library;

import 'dart:typed_data';

/// Larger than this is refused. A 512 px logo is a few tens of kilobytes; this
/// is a ceiling for a mistake, not a target.
const int maxLogoBytes = 1024 * 1024;

/// The longest side the picker is asked to scale a chosen image to.
const double logoMaxSide = 512;

enum LogoFormat {
  jpeg('image/jpeg', 'jpg'),
  png('image/png', 'png');

  const LogoFormat(this.mimeType, this.extension);
  final String mimeType;
  final String extension;
}

/// What [bytes] really are, from their first bytes, or null if they are not a
/// JPEG or a PNG. A file's name or a server's content type can be wrong; its
/// header is what the decoder will read.
LogoFormat? sniffLogoFormat(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return LogoFormat.jpeg;
  }
  const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length >= png.length) {
    var matches = true;
    for (var i = 0; i < png.length; i++) {
      if (bytes[i] != png[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return LogoFormat.png;
  }
  return null;
}

/// Why [bytes] cannot be used as a logo, or null if they can. The message is
/// meant to be shown.
String? logoProblem(Uint8List bytes) {
  if (bytes.isEmpty) return 'That picture is empty.';
  if (bytes.length > maxLogoBytes) {
    return 'That picture is too large. Choose a smaller one.';
  }
  if (sniffLogoFormat(bytes) == null) {
    return 'Use a JPEG or PNG picture.';
  }
  return null;
}
