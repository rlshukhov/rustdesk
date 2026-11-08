import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/macos_gesture.dart';

void main() {
  test('pinch keeps its remote anchor and sends multiplicative scale deltas',
      () {
    final gesture = MacOSGesture(const Offset(-400, 800), Offset.zero, 2);
    expect(gesture.update(1.01, Offset.zero), isNull);
    final began = gesture.update(1.2, Offset.zero)!['v'];
    expect(began['scroll'], false);
    expect(began['phase'], 1);
    expect(began['x'], -400);
    expect(began['magnification'], closeTo(0.2, 0.0001));
    final changed = gesture.update(1.5, const Offset(40, 30))!['v'];
    expect(changed['phase'], 2);
    expect(changed['magnification'], closeTo(0.25, 0.0001));
    expect(changed['delta_x'], 0);
    expect(gesture.end()!['v']['phase'], 4);
  });

  test('two-finger scroll uses remote image pixels and retains scroll mode',
      () {
    final gesture = MacOSGesture(Offset.zero, const Offset(10, 10), 2);
    expect(gesture.update(1, const Offset(13, 12)), isNull);
    final began = gesture.update(1, const Offset(30, 50))!['v'];
    expect(began['scroll'], true);
    expect(began['delta_x'], 10);
    expect(began['delta_y'], 20);
    final changed = gesture.update(1.1, const Offset(34, 60))!['v'];
    expect(changed['magnification'], 0);
    expect(changed['delta_y'], 5);
    expect(gesture.end(cancelled: true)!['v']['phase'], 8);
  });

  test('an unrecognised or invalid gesture sends no input', () {
    final gesture = MacOSGesture(Offset.zero, Offset.zero, 1);
    expect(gesture.update(double.nan, Offset.zero), isNull);
    expect(gesture.update(0, Offset.zero), isNull);
    expect(gesture.update(1, const Offset(2, 2)), isNull);
    expect(gesture.end(), isNull);
  });
}
