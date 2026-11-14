import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:crypto/crypto.dart';

/// One process-wide queue per database path. Native SQLite may have only one
/// worker thread: letting a second connection block that thread on a write lock
/// can prevent the first transaction from committing. Queue before entering SQL.
/// Never steal a live lock on a timer: failure must not rewind ratchet state.
class SignalIsolateMutex {
  static Future<T> run<T>(String path, Future<T> Function() action) async {
    var canonical = File(path).absolute.uri.normalizePath().toFilePath();
    if (Platform.isWindows) canonical = canonical.toLowerCase();
    final name =
        'pulsepath.signal.sql.${sha256.convert(utf8.encode(canonical))}';
    var broker = IsolateNameServer.lookupPortByName(name);
    if (broker == null) {
      final initialized = ReceivePort();
      try {
        await Isolate.spawn(_broker, [name, initialized.sendPort]);
        broker = await initialized.first.timeout(
          const Duration(seconds: 30),
        ) as SendPort;
      } finally {
        initialized.close();
      }
    }
    final reply = ReceivePort();
    var granted = false;
    try {
      broker.send(['acquire', reply.sendPort]);
      await reply.first.timeout(const Duration(seconds: 30));
      granted = true;
      return await action();
    } finally {
      broker.send([granted ? 'release' : 'cancel', reply.sendPort]);
      reply.close();
    }
  }
}

void _broker(List<Object> args) {
  final name = args[0] as String, initialized = args[1] as SendPort;
  final input = ReceivePort();
  if (!IsolateNameServer.registerPortWithName(input.sendPort, name)) {
    final existing = IsolateNameServer.lookupPortByName(name);
    if (existing != null) initialized.send(existing);
    input.close();
    return;
  }
  initialized.send(input.sendPort);
  final queue = Queue<SendPort>();
  SendPort? active;
  Timer? idle;
  void dispatch() {
    if (active == null && queue.isNotEmpty) {
      active = queue.removeFirst();
      active!.send(true);
    }
    if (active == null && queue.isEmpty) {
      idle?.cancel();
      idle = Timer(const Duration(seconds: 30), () {
        IsolateNameServer.removePortNameMapping(name);
        input.close();
      });
    }
  }

  dispatch();
  input.listen((dynamic message) {
    idle?.cancel();
    final op = message[0] as String, client = message[1] as SendPort;
    if (op == 'acquire') {
      queue.add(client);
    } else if (op == 'release' || op == 'cancel') {
      if (active == client) {
        active = null;
      } else {
        queue.remove(client);
      }
    }
    dispatch();
  });
}
