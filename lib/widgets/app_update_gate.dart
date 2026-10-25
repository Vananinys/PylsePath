import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../services/push_service.dart';
import 'app_update_dialog.dart';

/// Routes update-notification taps to the in-app update flow.
class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate> {
  @override
  void initState() {
    super.initState();
    PushService.instance.onUpdateOpen = _showUpdate;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(PushService.instance.flushPendingTap());
    });
  }

  Future<void> _showUpdate() async {
    if (!mounted || !AppUpdateService.supported) return;
    await showAppUpdateDialog(context, showNoUpdate: false);
  }

  @override
  void dispose() {
    PushService.instance.onUpdateOpen = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
