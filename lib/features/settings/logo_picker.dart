import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../../domain/logo.dart';

enum LogoSource { gallery, camera }

/// Chooses a picture for the shop logo. An interface so the screen can be
/// tested without a camera or a photo library.
abstract class LogoPicker {
  /// The chosen picture, or null if he backed out.
  Future<Uint8List?> pick(LogoSource source);
}

class ImagePickerLogoPicker implements LogoPicker {
  ImagePickerLogoPicker([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<Uint8List?> pick(LogoSource source) async {
    final file = await _picker.pickImage(
      source: source == LogoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      // Scaled down on the phone before anything else happens to it: a bill
      // logo is a few centimetres wide, and a 12-megapixel photo would be
      // uploaded, downloaded and embedded in every PDF for no benefit.
      maxWidth: logoMaxSide,
      maxHeight: logoMaxSide,
      imageQuality: 85,
    );
    return file?.readAsBytes();
  }
}
