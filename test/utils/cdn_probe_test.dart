import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/utils/cdn_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// Local stand-ins for CDN nodes.
class _Servers {
  final _closers = <Future<void> Function()>[];
  final rangeHeaders = <String?>[];

  /// Responds with [status] after [delay].
  Future<String> http(int status, {Duration delay = Duration.zero}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      rangeHeaders.add(req.headers.value('range'));
      await Future<void>.delayed(delay);
      req.response.statusCode = status;
      req.response.write('x');
      await req.response.close().catchError((_) {});
    });
    _closers.add(() => server.close(force: true));
    return 'http://127.0.0.1:${server.port}/video.m4s';
  }

  /// Accepts connections but never answers. [onClientClosed] completes when
  /// the client closes its socket.
  Future<(String, Future<void>)> silent() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final clientClosed = Completer<void>();
    server.listen((socket) {
      socket.listen(
        (_) {},
        onDone: () {
          if (!clientClosed.isCompleted) clientClosed.complete();
          socket.destroy();
        },
        onError: (_) {
          if (!clientClosed.isCompleted) clientClosed.complete();
        },
      );
    });
    _closers.add(server.close);
    return ('http://127.0.0.1:${server.port}/video.m4s', clientClosed.future);
  }

  /// A port with nothing listening.
  Future<String> dead() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return 'http://127.0.0.1:$port/video.m4s';
  }

  Future<void> close() => Future.wait(_closers.map((c) => c()));
}

void main() {
  const timeout = Duration(seconds: 2);
  late _Servers servers;

  setUp(() => servers = _Servers());
  tearDown(() => servers.close());

  test('the fastest successful URL wins', () async {
    final slow = await servers.http(206, delay: const Duration(seconds: 1));
    final fast = await servers.http(206);
    expect(await CdnProbe.race([slow, fast], timeout: timeout), fast);
  });

  test('error responses and dead hosts never win', () async {
    final forbidden = await servers.http(403);
    final dead = await servers.dead();
    final ok = await servers.http(
      206,
      delay: const Duration(milliseconds: 300),
    );
    expect(await CdnProbe.race([forbidden, dead, ok], timeout: timeout), ok);
  });

  test('returns null at once when every URL fails', () async {
    final stopwatch = Stopwatch()..start();
    final urls = [await servers.http(404), await servers.dead()];
    expect(await CdnProbe.race(urls, timeout: timeout), isNull);
    expect(stopwatch.elapsed, lessThan(timeout));
  });

  test('returns null after the timeout when no URL answers', () async {
    final (silent, _) = await servers.silent();
    final stopwatch = Stopwatch()..start();
    expect(await CdnProbe.race([silent], timeout: timeout), isNull);
    expect(stopwatch.elapsed, greaterThanOrEqualTo(timeout));
    expect(stopwatch.elapsed, lessThan(timeout * 2));
  });

  test('an empty list returns null', () async {
    expect(await CdnProbe.race([], timeout: timeout), isNull);
  });

  test('losing requests are closed once a URL wins', () async {
    final (silent, clientClosed) = await servers.silent();
    final ok = await servers.http(206);
    expect(await CdnProbe.race([silent, ok], timeout: timeout), ok);
    await clientClosed.timeout(const Duration(seconds: 1));
  });

  test('probes request a single byte', () async {
    final ok = await servers.http(206);
    final dio = CdnProbe.createDio(timeout);
    addTearDown(() => dio.close(force: true));
    await CdnProbe.ttfb(dio, ok, timeout: timeout);
    expect(servers.rangeHeaders, ['bytes=0-0']);
  });
}
