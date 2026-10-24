import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class AndroidTextureController {
  static const enabled =
      bool.fromEnvironment('ANDROID_TEXTURE_DECODER', defaultValue: true);
  static const _channel = MethodChannel('rustdesk/android_texture');
  static final _controllers = <String, AndroidTextureController>{};
  static bool _listening = false;

  final String session;
  final Future<void> Function() onReady;
  final VoidCallback onChanged;
  int? textureId;
  int width = 0;
  int height = 0;
  bool ready = false;
  bool _closed = false;

  AndroidTextureController(this.session,
      {required this.onReady, required this.onChanged});

  Future<void> start() async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'state' || call.arguments is! Map) return;
        final event = Map<String, dynamic>.from(call.arguments as Map);
        final controller = _controllers[event['session']];
        if (controller == null || controller._closed) return;
        if (controller.textureId != null &&
            controller.textureId != event['texture']) return;
        controller.width = event['width'] as int;
        controller.height = event['height'] as int;
        controller.ready = event['state'] == 'texture';
        if (controller.ready) await controller.onReady();
        if (!controller._closed) controller.onChanged();
      });
    }
    _controllers[session] = this;
    try {
      textureId =
          await _channel.invokeMethod<int>('create', {'session': session});
      if (_closed && textureId != null) await _disposeNative();
    } on PlatformException catch (error) {
      debugPrint('Android texture decoder unavailable: ${error.message}');
    } on MissingPluginException {
      debugPrint('Android texture decoder is unavailable in this build');
    }
  }

  Future<Map<dynamic, dynamic>?> stats() => _closed || textureId == null
      ? Future.value(null)
      : _channel
          .invokeMapMethod('stats', {'session': session, 'texture': textureId});

  Future<void> _disposeNative() async {
    try {
      await _channel.invokeMethod<void>(
          'dispose', {'session': session, 'texture': textureId});
    } on PlatformException catch (error) {
      debugPrint(
          'Android texture disposal failed: ${error.message ?? error.code}');
    } on MissingPluginException {
      debugPrint('Android texture channel already closed');
    }
  }

  Future<void> close() async {
    _closed = true;
    ready = false;
    if (identical(_controllers[session], this)) _controllers.remove(session);
    if (textureId != null) await _disposeNative();
  }
}

typedef DecoderMonitorRow = Widget Function(String label, String? value,
    {Color? rightColor});

class AndroidDecoderMonitor extends StatefulWidget {
  final AndroidTextureController? controller;
  final bool hasImage;
  final DecoderMonitorRow rowBuilder;

  const AndroidDecoderMonitor(
      {super.key,
      required this.controller,
      required this.hasImage,
      required this.rowBuilder});

  @override
  State<AndroidDecoderMonitor> createState() => _AndroidDecoderMonitorState();
}

class _AndroidDecoderMonitorState extends State<AndroidDecoderMonitor> {
  Map<dynamic, dynamic>? _stats;
  final _rates = <String, String>{};
  bool _polling = false;
  String? _queryError;

  @override
  void initState() {
    super.initState();
    _readStats();
  }

  @override
  void didUpdateWidget(covariant AndroidDecoderMonitor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _stats = null;
      _rates.clear();
      _queryError = null;
    }
    // The existing quality-status tick drives sampling while the monitor is visible.
    _readStats();
  }

  Future<void> _readStats() async {
    final controller = widget.controller;
    if (_polling || controller == null) return;
    _polling = true;
    try {
      final next = await controller.stats();
      if (!mounted ||
          !identical(controller, widget.controller) ||
          controller._closed ||
          next?['texture'] != controller.textureId) return;
      final previous = _stats;
      _rates.clear();
      if (previous != null && next != null) {
        final elapsed =
            (next['sampleTimeNs'] as int) - (previous['sampleTimeNs'] as int);
        if (elapsed > 0) {
          for (final counter in ['submitted', 'decoded', 'consumed']) {
            final frames = (next[counter] as int) - (previous[counter] as int);
            if (frames >= 0) {
              _rates[counter] = (frames * 1e9 / elapsed).toStringAsFixed(1);
            }
          }
        }
      }
      setState(() {
        _stats = next;
        _queryError = null;
      });
    } on PlatformException catch (error) {
      if (mounted && identical(controller, widget.controller)) {
        setState(() => _queryError = error.message ?? error.code);
      }
    } on MissingPluginException {
      if (mounted && identical(controller, widget.controller)) {
        setState(() => _queryError = 'Decoder stats unavailable');
      }
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hardware = widget.controller?.ready == true &&
        _stats?['failed'] != true &&
        _stats?['active'] != false;
    final row = widget.rowBuilder;
    const green = Color(0xff69f0ae);
    const amber = Color(0xffffd740);
    final reason = _stats?['reason'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(
            'Decode path',
            !widget.hasImage
                ? '-'
                : hardware
                    ? 'HW / Surface'
                    : 'SW / CPU',
            rightColor: hardware ? green : amber),
        if (hardware) ...[
          row('Decoder', _stats?['codec'] as String? ?? '-'),
          row('Input / decode FPS',
              '${_rates['submitted'] ?? '-'} / ${_rates['decoded'] ?? '-'}'),
          row('Texture FPS', _rates['consumed'] ?? '-'),
          row(
              'Codec queue',
              _stats == null
                  ? '-'
                  : '${_stats!['codecQueue']}/${_stats!['codecQueueLimit']} · ${_stats!['queueAgeMs']}ms'),
          row(
              'Surface queue',
              _stats?['surfaceQueue'] == null
                  ? '-'
                  : '${_stats!['surfaceQueue']}/${_stats!['surfaceQueueLimit']} · drop ${_stats!['surfaceDropped']}'),
        ],
        if ((_stats?['rustQueue'] as int? ?? -1) >= 0)
          row('Rust queue', '${_stats!['rustQueue']} frames'),
        if (!hardware && reason != null && reason.isNotEmpty)
          Text('Fallback: $reason',
              style: const TextStyle(color: amber),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
        if (_queryError != null)
          Text(_queryError!, style: const TextStyle(color: amber), maxLines: 2),
      ],
    );
  }
}

class AndroidTextureView extends StatelessWidget {
  final AndroidTextureController controller;
  final Offset offset;
  final double scale;

  const AndroidTextureView(
      {super.key,
      required this.controller,
      required this.offset,
      required this.scale});

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: offset.dx,
            top: offset.dy,
            width: controller.width * scale,
            height: controller.height * scale,
            child: Texture(textureId: controller.textureId!),
          ),
        ],
      );
}
