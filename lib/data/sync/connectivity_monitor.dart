import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Whether the device thinks it has a network. Wrapped in an interface so
/// sync can be tested against a connection that comes and goes on demand.
abstract class ConnectivityMonitor {
  Future<bool> isOnline();
  Stream<bool> get onChange;
  void dispose();
}

class PlatformConnectivityMonitor implements ConnectivityMonitor {
  PlatformConnectivityMonitor([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _online(List<ConnectivityResult> results) =>
      results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async => _online(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get onChange =>
      _connectivity.onConnectivityChanged.map(_online).distinct();

  @override
  void dispose() {}
}

/// Test double.
class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({bool online = true})
      // ignore: prefer_initializing_formals
      : _online = online;

  bool _online;
  final _controller = StreamController<bool>.broadcast();

  set online(bool value) {
    if (_online == value) return;
    _online = value;
    _controller.add(value);
  }

  @override
  Future<bool> isOnline() async => _online;

  @override
  Stream<bool> get onChange => _controller.stream;

  @override
  void dispose() => _controller.close();
}
