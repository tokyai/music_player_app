import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/account_service.dart';
import '../theme/app_theme.dart';
import '../widgets/remote_focusable.dart';

class LoginScreen extends StatefulWidget {
  final Future<void> Function(String server, String username, String password)
  onLogin;

  const LoginScreen({super.key, required this.onLogin});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _server;
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(
      text: context.read<AccountService>().baseUrl,
    );
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _error = null);
    try {
      await widget.onLogin(_server.text, _username.text, _password.text);
    } on AccountException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '登录失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.syncWithTheme(context);
    final account = context.watch<AccountService>();
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrowLandscape =
                constraints.maxWidth > constraints.maxHeight &&
                constraints.maxHeight <= 420;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: narrowLandscape ? 28 : 20,
                  vertical: narrowLandscape ? 10 : 24,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: narrowLandscape ? 720 : 440,
                  ),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Image.asset(
                              'assets/images/app_logo.png',
                              width: narrowLandscape ? 48 : 64,
                              height: narrowLandscape ? 48 : 64,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '登录库仔音乐',
                                    style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: narrowLandscape ? 22 : 28,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '登录后才能使用播放、收藏和同步功能',
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: narrowLandscape ? 14 : 24),
                        if (narrowLandscape)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _credentials(account)),
                              const SizedBox(width: 12),
                              Expanded(child: _serverAndSubmit(account)),
                            ],
                          )
                        else ...[
                          _credentials(account),
                          const SizedBox(height: 12),
                          _serverAndSubmit(account),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _credentials(AccountService account) => Column(
    children: [
      RemoteTextFieldTraversal(
        controller: _username,
        child: TextField(
          key: const ValueKey('account-username'),
          controller: _username,
          autofillHints: const [AutofillHints.username],
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '用户名',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
      ),
      const SizedBox(height: 10),
      RemoteTextFieldTraversal(
        controller: _password,
        child: TextField(
          key: const ValueKey('account-password'),
          controller: _password,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
          onSubmitted: account.busy ? null : (_) => _submit(),
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: _obscure ? '显示密码' : '隐藏密码',
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _serverAndSubmit(AccountService account) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RemoteTextFieldTraversal(
        controller: _server,
        child: TextField(
          key: const ValueKey('account-server'),
          controller: _server,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '账号服务器',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
      ),
      if (_error != null || account.message != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _error ?? account.message!,
            key: const ValueKey('account-login-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('account-login-submit'),
        onPressed: account.busy ? null : _submit,
        icon: account.busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.login),
        label: Text(account.busy ? '正在登录' : '登录'),
      ),
    ],
  );
}
