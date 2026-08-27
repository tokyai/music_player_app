import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/app_user.dart';

class UserAvatarStorage {
  static const maxAvatarBytes = 384 * 1024;
  static const maxAvatarDimension = 512;

  final Directory? _rootOverride;
  final Random _random;

  UserAvatarStorage({Directory? rootDirectory, Random? random})
    : _rootOverride = rootDirectory,
      _random = random ?? Random.secure();

  static final shared = UserAvatarStorage();

  Future<String> save(String userId, Uint8List bytes) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(userId)) {
      throw const FormatException('用户 ID 无效');
    }
    validateJpeg(bytes);
    final directory = await _avatarDirectory(create: true);
    final suffix = List<int>.generate(
      12,
      (_) => _random.nextInt(256),
      growable: false,
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final fileName = 'avatar_${userId}_$suffix.jpg';
    final target = File(_join(directory.path, fileName));
    final temporary = File('${target.path}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      return fileName;
    } catch (_) {
      await _deleteIfPresent(temporary);
      rethrow;
    }
  }

  Future<File?> resolve(String? fileName) async {
    if (!AppUserProfile.isValidAvatarFileName(fileName)) return null;
    try {
      final directory = await _avatarDirectory();
      final file = File(_join(directory.path, fileName!));
      return await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> read(String? fileName) async {
    final file = await resolve(fileName);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    validateJpeg(bytes);
    return bytes;
  }

  Future<void> delete(String? fileName) async {
    if (!AppUserProfile.isValidAvatarFileName(fileName)) return;
    final directory = await _avatarDirectory();
    await _deleteIfPresent(File(_join(directory.path, fileName!)));
  }

  Future<void> deleteAllForUser(String userId) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(userId)) return;
    final directory = await _avatarDirectory();
    if (!await directory.exists()) return;
    final prefix = 'avatar_${userId}_';
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final fileName = entity.uri.pathSegments.last;
      if (fileName.startsWith(prefix) &&
          AppUserProfile.isValidAvatarFileName(fileName)) {
        await _deleteIfPresent(entity);
      }
    }
  }

  Future<Directory> _avatarDirectory({bool create = false}) async {
    final support = _rootOverride ?? await getApplicationSupportDirectory();
    final directory = Directory(_join(support.path, 'user_avatars'));
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      rethrow;
    }
  }

  static void validateJpeg(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxAvatarBytes) {
      throw const FormatException('头像文件不能超过 384 KB');
    }
    if (bytes.length < 12 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes[bytes.length - 1] != 0xd9) {
      throw const FormatException('头像必须是有效的 JPEG 图片');
    }

    var offset = 2;
    while (offset + 3 < bytes.length) {
      while (offset < bytes.length && bytes[offset] != 0xff) {
        offset++;
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd8 ||
          marker == 0xd9 ||
          marker == 0x01 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (offset + 1 >= bytes.length) break;
      final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
      if (segmentLength < 2 || offset + segmentLength > bytes.length) break;
      if (_isStartOfFrame(marker)) {
        if (segmentLength < 7) break;
        final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
        final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
        if (width <= 0 ||
            height <= 0 ||
            width > maxAvatarDimension ||
            height > maxAvatarDimension) {
          throw const FormatException('头像尺寸不能超过 512 x 512');
        }
        if (width != height) {
          throw const FormatException('头像必须是正方形图片');
        }
        return;
      }
      offset += segmentLength;
    }
    throw const FormatException('无法读取头像尺寸');
  }

  static bool _isStartOfFrame(int marker) =>
      marker == 0xc0 ||
      marker == 0xc1 ||
      marker == 0xc2 ||
      marker == 0xc3 ||
      marker == 0xc5 ||
      marker == 0xc6 ||
      marker == 0xc7 ||
      marker == 0xc9 ||
      marker == 0xca ||
      marker == 0xcb ||
      marker == 0xcd ||
      marker == 0xce ||
      marker == 0xcf;
}
