import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../theme/app_theme.dart';
import 'app_user_avatar.dart';

class UserProfileDraft {
  final String name;
  final String avatarId;
  final int avatarColorIndex;

  const UserProfileDraft({
    required this.name,
    required this.avatarId,
    required this.avatarColorIndex,
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
        ),
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
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
              Center(child: AppUserAvatar(user: preview, size: 72)),
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
                      onPressed: () => setState(() => _avatarId = avatarId),
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
