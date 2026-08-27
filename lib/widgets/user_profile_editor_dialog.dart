import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/app_user.dart';
import '../services/lan_user_profile_service.dart';
import '../theme/app_layout.dart';
import '../theme/app_theme.dart';
import 'app_user_avatar.dart';

class UserProfileDraft {
  final String name;
  final String avatarId;
  final int avatarColorIndex;
  final Uint8List? customAvatarBytes;

  const UserProfileDraft({
    required this.name,
    required this.avatarId,
    required this.avatarColorIndex,
    this.customAvatarBytes,
  });
}

class UserProfileEditorDialog extends StatefulWidget {
  const UserProfileEditorDialog({super.key, this.initialUser});

  final AppUserProfile? initialUser;

  @override
  State<UserProfileEditorDialog> createState() =>
      _UserProfileEditorDialogState();
}

class _UserProfileEditorDialogState extends State<UserProfileEditorDialog> {
  late final TextEditingController _nameController;
  late String _avatarId;
  late int _colorIndex;
  Uint8List? _customAvatarBytes;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialUser;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _avatarId = initial?.avatarId ?? 'person';
    _colorIndex = initial?.avatarColorIndex ?? 0;
  }

  @override
  void dispose() {
    final bytes = _customAvatarBytes;
    if (bytes != null) unawaited(MemoryImage(bytes).evict());
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final name = AppUserProfile.normalizeName(_nameController.text);
      Navigator.pop(
        context,
        UserProfileDraft(
          name: name,
          avatarId: _avatarId,
          avatarColorIndex: _colorIndex,
          customAvatarBytes: _customAvatarBytes,
        ),
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _selectBuiltInAvatar(String avatarId) {
    final previous = _customAvatarBytes;
    if (previous != null) unawaited(MemoryImage(previous).evict());
    setState(() {
      _avatarId = avatarId;
      _customAvatarBytes = null;
    });
  }

  Future<void> _scanWithPhone() async {
    if (_scanning) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _scanning = true);
    LanUserProfileSession? session;
    LanUserProfileSubmission? submission;
    try {
      session = await LanUserProfileService.start(
        initialName: _nameController.text,
      );
      if (!mounted) return;
      final received = session.receivedSubmission;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UserProfileQrDialog(
          url: session!.url,
          receivedFuture: received.then((value) => value != null),
        ),
      );
      await session.stop();
      submission = await received;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('扫码输入失败：$error')));
      }
    } finally {
      try {
        await session?.stop();
      } catch (_) {}
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted || submission == null) return;
    final receivedSubmission = submission;
    final replacementBytes = receivedSubmission.avatarBytes;
    final previous = _customAvatarBytes;
    if (previous != null && replacementBytes != null) {
      unawaited(MemoryImage(previous).evict());
    }
    setState(() {
      _nameController.text = receivedSubmission.name;
      if (replacementBytes != null) {
        _customAvatarBytes = replacementBytes;
        _avatarId = AppUserProfile.customAvatarId;
      }
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = AppUserProfile(
      id: widget.initialUser?.id ?? 'preview',
      name: _nameController.text.trim().isEmpty
          ? '新用户'
          : _nameController.text.trim(),
      avatarId: _avatarId,
      avatarColorIndex: _colorIndex,
      avatarFileName: _avatarId == AppUserProfile.customAvatarId
          ? widget.initialUser?.avatarFileName
          : null,
    );
    return AlertDialog(
      key: const ValueKey('user-profile-editor-dialog'),
      title: Text(widget.initialUser == null ? '新增用户' : '编辑用户'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: _buildPreview(preview)),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('user-profile-name'),
                controller: _nameController,
                autofocus: true,
                maxLength: AppUserProfile.maxNameLength,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '用户名称',
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('user-profile-scan'),
                onPressed: _scanning ? null : _scanWithPhone,
                icon: const Icon(Icons.qr_code_2_rounded),
                label: Text(_scanning ? '正在等待手机' : '手机扫码输入'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 14),
              Text('头像', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final avatarId in AppUserProfile.avatarIds)
                    _AvatarChoice(
                      avatarId: avatarId,
                      colorIndex: _colorIndex,
                      selected: avatarId == _avatarId,
                      onPressed: () => _selectBuiltInAvatar(avatarId),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text('颜色', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 9,
                runSpacing: 9,
                children: [
                  for (
                    var index = 0;
                    index < AppUserProfile.avatarColorCount;
                    index++
                  )
                    InkWell(
                      key: ValueKey('user-avatar-color-$index'),
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => setState(() => _colorIndex = index),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _colorIndex == index
                                ? AppColors.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        padding: const EdgeInsets.all(3),
                        child: AppUserAvatar(
                          user: preview.copyWith(
                            avatarId: 'person',
                            avatarColorIndex: index,
                          ),
                          size: 32,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('user-profile-save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildPreview(AppUserProfile preview) {
    final bytes = _customAvatarBytes;
    if (bytes == null) return AppUserAvatar(user: preview, size: 72);
    return ClipOval(
      child: Image.memory(
        bytes,
        key: const ValueKey('user-profile-custom-preview'),
        width: 72,
        height: 72,
        fit: BoxFit.cover,
        cacheWidth: 144,
        cacheHeight: 144,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => const ColoredBox(
          color: Color(0xFF5D6178),
          child: SizedBox.square(
            dimension: 72,
            child: Icon(Icons.person_rounded, color: Colors.white, size: 38),
          ),
        ),
      ),
    );
  }
}

class _AvatarChoice extends StatelessWidget {
  const _AvatarChoice({
    required this.avatarId,
    required this.colorIndex,
    required this.selected,
    required this.onPressed,
  });

  final String avatarId;
  final int colorIndex;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final user = AppUserProfile(
      id: 'choice',
      name: '',
      avatarId: avatarId,
      avatarColorIndex: colorIndex,
    );
    return InkWell(
      key: ValueKey('user-avatar-$avatarId'),
      borderRadius: BorderRadius.circular(28),
      onTap: onPressed,
      child: Container(
        width: 54,
        height: 54,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.outline,
            width: selected ? 3 : 1,
          ),
        ),
        child: AppUserAvatar(user: user, size: 44),
      ),
    );
  }
}

class UserProfileQrDialog extends StatelessWidget {
  const UserProfileQrDialog({
    super.key,
    required this.url,
    required this.receivedFuture,
  });

  final String url;
  final Future<bool> receivedFuture;

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.fromContext(context);
    final compact = layout.isCompactLandscape;
    final qrSize = compact ? 136.0 : 205.0;
    final qrCode = ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: QrImageView(
          key: const ValueKey('user-profile-qr-code'),
          data: url,
          version: QrVersions.auto,
          size: qrSize,
          backgroundColor: Colors.white,
          semanticsLabel: '手机扫码输入用户资料',
        ),
      ),
    );
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '手机设置用户资料',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: layout.sectionTitleSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        FutureBuilder<bool>(
          future: receivedFuture,
          builder: (context, snapshot) {
            final received =
                snapshot.connectionState == ConnectionState.done &&
                snapshot.data == true;
            final ended =
                snapshot.connectionState == ConnectionState.done &&
                snapshot.data != true;
            return Row(
              children: [
                Icon(
                  received
                      ? Icons.check_circle_outline_rounded
                      : ended
                      ? Icons.timer_off_outlined
                      : Icons.phone_android_rounded,
                  color: received
                      ? AppColors.primary
                      : ended
                      ? AppColors.textHint
                      : AppColors.primary,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    received
                        ? '资料已接收，关闭后确认保存'
                        : ended
                        ? '本次扫码输入已结束'
                        : '扫码后填写名称并选择头像',
                    key: const ValueKey('user-profile-qr-status'),
                    style: TextStyle(color: AppColors.textPrimary),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          '手机与车机需连接同一个 Wi-Fi，二维码约 10 分钟后失效。',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: layout.secondarySize,
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('user-profile-qr-close'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
            label: const Text('关闭'),
          ),
        ),
      ],
    );
    return Dialog(
      key: const ValueKey('user-profile-qr-dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 20),
          child: MediaQuery.orientationOf(context) == Orientation.landscape
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    qrCode,
                    SizedBox(width: compact ? 12 : 20),
                    Flexible(child: details),
                  ],
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [qrCode, const SizedBox(height: 16), details],
                  ),
                ),
        ),
      ),
    );
  }
}
