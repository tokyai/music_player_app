import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/player_provider.dart';
import '../services/bilibili_service.dart';
import '../theme/app_theme.dart';

class BilibiliLoginDialog extends StatefulWidget {
  const BilibiliLoginDialog({super.key});

  @override
  State<BilibiliLoginDialog> createState() => _BilibiliLoginDialogState();
}

class _BilibiliLoginDialogState extends State<BilibiliLoginDialog> {
  Timer? _timer;
  BilibiliQrCode? _qrCode;
  bool _loading = true;
  bool _polling = false;
  int _secondsLeft = 180;
  String _status = '正在获取二维码';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _status = '正在获取二维码';
      _secondsLeft = 180;
    });
    try {
      final code = await context.read<PlayerProvider>().createBilibiliQrCode();
      if (!mounted) return;
      setState(() {
        _qrCode = code;
        _loading = false;
        _status = '请使用哔哩哔哩 App 扫码';
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        final seconds = 180 - timer.tick;
        setState(() => _secondsLeft = seconds.clamp(0, 180));
        if (seconds <= 0) {
          timer.cancel();
          setState(() => _status = '二维码已过期');
        } else if (timer.tick.isEven) {
          unawaited(_poll());
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
        _status = '二维码加载失败';
      });
    }
  }

  Future<void> _poll() async {
    final code = _qrCode;
    if (_polling || code == null) return;
    _polling = true;
    try {
      final result = await context.read<PlayerProvider>().pollBilibiliQrCode(
        code.key,
      );
      if (!mounted) return;
      switch (result.status) {
        case BilibiliQrStatus.success:
          _timer?.cancel();
          Navigator.pop(context, true);
        case BilibiliQrStatus.expired:
          _timer?.cancel();
          setState(() {
            _secondsLeft = 0;
            _status = result.message;
          });
        case BilibiliQrStatus.scanned:
          setState(() => _status = result.message);
        case BilibiliQrStatus.waiting:
          if (_status != result.message) {
            setState(() => _status = result.message);
          }
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.height <= 420;
    final qrSize = compact ? 156.0 : 220.0;
    return Dialog(
      key: const ValueKey('bilibili-login-dialog'),
      insetPadding: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: size.height - 24),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(compact ? 14 : 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.qr_code_2_rounded),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '登录 B站',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              SizedBox(height: compact ? 4 : 12),
              SizedBox.square(
                dimension: qrSize,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _qrCode == null
                    ? Icon(
                        Icons.qr_code_2_rounded,
                        size: qrSize * 0.65,
                        color: AppColors.textHint,
                      )
                    : ColoredBox(
                        color: Colors.white,
                        child: QrImageView(
                          key: const ValueKey('bilibili-login-qr'),
                          data: _qrCode!.url,
                          version: QrVersions.auto,
                          padding: const EdgeInsets.all(8),
                        ),
                      ),
              ),
              SizedBox(height: compact ? 8 : 14),
              Text(
                _status,
                key: const ValueKey('bilibili-login-status'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                '剩余 $_secondsLeft 秒',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(
                  _error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
              SizedBox(height: compact ? 8 : 14),
              OutlinedButton.icon(
                key: const ValueKey('bilibili-login-refresh'),
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新二维码'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
