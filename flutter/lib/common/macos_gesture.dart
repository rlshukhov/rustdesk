import 'dart:ui';

class MacOSGesture {
  final Offset position;
  final Offset origin;
  final double canvasScale;
  Offset _lastFocalPoint;
  double _lastScale = 1;
  bool? _scroll;

  MacOSGesture(this.position, this.origin, this.canvasScale)
      : _lastFocalPoint = origin;

  Map<String, dynamic>? update(double scale, Offset focalPoint) {
    if (!canvasScale.isFinite ||
        canvasScale <= 0 ||
        !scale.isFinite ||
        scale <= 0 ||
        !focalPoint.dx.isFinite ||
        !focalPoint.dy.isFinite) return null;
    final began = _scroll == null;
    if (began) {
      if ((scale - 1).abs() > 0.02) {
        _scroll = false;
      } else if ((focalPoint - origin).distance > 6) {
        _scroll = true;
      } else {
        return null;
      }
    }
    final delta = (focalPoint - _lastFocalPoint) / canvasScale;
    final magnification = scale / _lastScale - 1;
    _lastFocalPoint = focalPoint;
    _lastScale = scale;
    return _packet(began ? 1 : 2,
        magnification: _scroll! ? 0 : magnification,
        delta: _scroll! ? delta : Offset.zero);
  }

  Map<String, dynamic>? end({bool cancelled = false}) =>
      _scroll == null ? null : _packet(cancelled ? 8 : 4);

  Map<String, dynamic> _packet(int phase,
          {double magnification = 0, Offset delta = Offset.zero}) =>
      {
        'k': 'macos-gesture',
        'v': {
          'scroll': _scroll,
          'phase': phase,
          'x': position.dx.round(),
          'y': position.dy.round(),
          'magnification': magnification,
          'delta_x': delta.dx,
          'delta_y': delta.dy,
        }
      };
}
