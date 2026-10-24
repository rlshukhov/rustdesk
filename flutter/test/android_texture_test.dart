import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/models/android_texture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rustdesk/android_texture');
  const codec = StandardMethodCodec();

  Future<void> state(Map<String, Object> state) async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(MethodCall('state', state)),
            (_) => done.complete());
    await done.future;
  }

  test('texture becomes visible after surface output and clears on fallback',
      () async {
    var frames = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (call) async => call.method == 'create' ? 7 : null);
    final controller = AndroidTextureController('session', onReady: () async {
      frames++;
    }, onChanged: () {});
    await controller.start();
    expect(controller.ready, isFalse);
    await state({
      'session': 'session',
      'state': 'texture',
      'texture': 7,
      'width': 3024,
      'height': 1964
    });
    expect(controller.ready, isTrue);
    expect(frames, 1);
    expect(controller.width, 3024);
    await state({
      'session': 'session',
      'state': 'software',
      'texture': 7,
      'width': 3024,
      'height': 1964
    });
    expect(controller.ready, isFalse);
    await controller.close();
    await state({
      'session': 'session',
      'state': 'texture',
      'texture': 7,
      'width': 3024,
      'height': 1964
    });
    expect(controller.ready, isFalse);
    expect(frames, 1);
  });

  testWidgets('native video follows desktop pan and zoom geometry',
      (tester) async {
    final controller = AndroidTextureController('geometry',
        onReady: () async {}, onChanged: () {})
      ..textureId = 8
      ..width = 1920
      ..height = 1080;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: AndroidTextureView(
          controller: controller, offset: const Offset(-100, 25), scale: 0.5),
    ));
    final positioned = tester.widget<Positioned>(find.byType(Positioned));
    expect(positioned.left, -100);
    expect(positioned.top, 25);
    expect(positioned.width, 960);
    expect(positioned.height, 540);
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 8);
  });

  test('platform disposal failure still completes session texture cleanup',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'create') return 9;
      if (call.method == 'dispose') {
        throw PlatformException(code: 'engine_closed');
      }
      return null;
    });
    final controller = AndroidTextureController('dispose-error',
        onReady: () async {}, onChanged: () {});
    await controller.start();
    await controller.close();
    expect(controller.ready, isFalse);
    expect(await controller.stats(), isNull);
  });

  testWidgets(
      'quality monitor shows actual decoder, rates, queues and fallback',
      (tester) async {
    var snapshot = <String, Object>{
      'texture': 7,
      'codec': 'c2.qti.hevc.decoder',
      'active': true,
      'failed': false,
      'reason': '',
      'sampleTimeNs': 1000000000,
      'submitted': 100,
      'decoded': 95,
      'consumed': 90,
      'rustQueue': 7,
      'codecQueue': 3,
      'codecQueueLimit': 4,
      'queueAgeMs': 8,
      'surfaceQueue': 1,
      'surfaceQueueLimit': 2,
      'surfaceDropped': 5,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stats') {
        expect(call.arguments, {'session': 'monitor', 'texture': 7});
        return snapshot;
      }
      return null;
    });
    final controller = AndroidTextureController('monitor',
        onReady: () async {}, onChanged: () {})
      ..textureId = 7
      ..ready = true;
    Widget monitor() => Directionality(
          textDirection: TextDirection.ltr,
          child: AndroidDecoderMonitor(
              controller: controller,
              hasImage: true,
              rowBuilder: (label, value, {rightColor}) =>
                  Text('$label: $value')),
        );
    await tester.pumpWidget(monitor());
    await tester.pump();
    expect(find.text('Decode path: HW / Surface'), findsOneWidget);
    expect(find.text('Decoder: c2.qti.hevc.decoder'), findsOneWidget);
    expect(find.text('Rust queue: 7 frames'), findsOneWidget);
    expect(find.text('Codec queue: 3/4 · 8ms'), findsOneWidget);
    expect(find.text('Surface queue: 1/2 · drop 5'), findsOneWidget);

    snapshot = {
      ...snapshot,
      'sampleTimeNs': 2000000000,
      'submitted': 160,
      'decoded': 154,
      'consumed': 148
    };
    await tester.pumpWidget(monitor());
    await tester.pump();
    expect(find.text('Input / decode FPS: 60.0 / 59.0'), findsOneWidget);
    expect(find.text('Texture FPS: 58.0'), findsOneWidget);

    controller.ready = false;
    snapshot = {
      ...snapshot,
      'active': false,
      'failed': true,
      'reason': 'Decoder input stayed full'
    };
    await tester.pumpWidget(monitor());
    await tester.pump();
    expect(find.text('Decode path: SW / CPU'), findsOneWidget);
    expect(find.text('Rust queue: 7 frames'), findsOneWidget);
    expect(find.text('Fallback: Decoder input stayed full'), findsOneWidget);
    expect(find.text('Decoder: c2.qti.hevc.decoder'), findsNothing);
    await controller.close();
  });
}
