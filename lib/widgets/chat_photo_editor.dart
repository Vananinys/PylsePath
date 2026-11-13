import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Crop coordinates are normalized in the rotated image, independent of layout.
class ChatPhotoStroke {
  ChatPhotoStroke(this.color, this.points);
  final Color color;
  final List<Offset> points;
}

void _paintStrokes(Canvas canvas, Size size, List<ChatPhotoStroke> strokes) {
  for (final stroke in strokes) {
    if (stroke.points.isEmpty) continue;
    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = math.min(size.width, size.height) * .012
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    Offset point(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        point(stroke.points.first),
        paint.strokeWidth / 2,
        Paint()..color = stroke.color,
      );
    } else {
      final path = Path()
        ..moveTo(point(stroke.points.first).dx, point(stroke.points.first).dy);
      for (final p in stroke.points.skip(1)) {
        final next = point(p);
        path.lineTo(next.dx, next.dy);
      }
      canvas.drawPath(path, paint);
    }
  }
}

Future<Uint8List> renderChatPhoto(
  ui.Image image,
  int turns,
  Rect crop, {
  List<ChatPhotoStroke> strokes = const [],
}) async {
  final rotation = turns % 4;
  final width = rotation.isOdd ? image.height : image.width;
  final height = rotation.isOdd ? image.width : image.height;
  final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final area = Rect.fromLTRB(
    crop.left * width,
    crop.top * height,
    crop.right * width,
    crop.bottom * height,
  ).intersect(bounds);
  if (area.width < 1 || area.height < 1) {
    throw const FormatException('Выберите область фото');
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..translate(-area.left, -area.top);
  canvas.save();
  switch (rotation) {
    case 1:
      canvas.translate(image.height.toDouble(), 0);
      canvas.rotate(math.pi / 2);
    case 2:
      canvas.translate(image.width.toDouble(), image.height.toDouble());
      canvas.rotate(math.pi);
    case 3:
      canvas.translate(0, image.width.toDouble());
      canvas.rotate(-math.pi / 2);
  }
  canvas.drawImage(image, Offset.zero, Paint());
  canvas.restore();
  _paintStrokes(canvas, Size(width.toDouble(), height.toDouble()), strokes);
  final picture = recorder.endRecording();
  ui.Image? output;
  try {
    output = await picture.toImage(area.width.round(), area.height.round());
    final bytes = await output.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Фото не удалось обработать');
    return bytes.buffer.asUint8List();
  } finally {
    output?.dispose();
    picture.dispose();
  }
}

class ChatPhotoEditor extends StatefulWidget {
  const ChatPhotoEditor({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<ChatPhotoEditor> createState() => _ChatPhotoEditorState();
}

class _ChatPhotoEditorState extends State<ChatPhotoEditor> {
  ui.Image? _image;
  bool _busy = false;
  String? _error;
  int _turns = 0;
  Rect _crop = const Rect.fromLTWH(0, 0, 1, 1);
  Offset? _origin;
  bool _cropping = false;
  bool _drawing = false;
  Color _penColor = Colors.red;
  final List<ChatPhotoStroke> _strokes = [];
  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(
        widget.bytes,
        targetWidth: 2048,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось открыть это фото');
    } finally {
      codec?.dispose();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_image == null || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await renderChatPhoto(
        _image!,
        _turns,
        _crop,
        strokes: _strokes,
      );
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Не удалось обработать фото. Попробуйте другую область.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Редактировать фото')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _image == null
                    ? (_error != null
                          ? Text(_error!)
                          : const CircularProgressIndicator())
                    : LayoutBuilder(
                        builder: (context, limits) {
                          final ratio = _turns.isOdd
                              ? _image!.height / _image!.width
                              : _image!.width / _image!.height;
                          final width = math.min(
                            limits.maxWidth,
                            limits.maxHeight * ratio,
                          );
                          final height = width / ratio;
                          Offset normalized(Offset point) => Offset(
                            (point.dx / width).clamp(0.0, 1.0),
                            (point.dy / height).clamp(0.0, 1.0),
                          );
                          return Center(
                            child: SizedBox(
                              width: width,
                              height: height,
                              child: GestureDetector(
                                onPanStart: (!_cropping && !_drawing) || _busy
                                    ? null
                                    : (d) {
                                        final point = normalized(
                                          d.localPosition,
                                        );
                                        if (_drawing) {
                                          setState(
                                            () => _strokes.add(
                                              ChatPhotoStroke(_penColor, [
                                                point,
                                              ]),
                                            ),
                                          );
                                        } else {
                                          _origin = point;
                                        }
                                      },
                                onPanUpdate: (!_cropping && !_drawing) || _busy
                                    ? null
                                    : (d) {
                                        if (_drawing) {
                                          setState(
                                            () => _strokes.last.points.add(
                                              normalized(d.localPosition),
                                            ),
                                          );
                                          return;
                                        }
                                        final origin = _origin;
                                        if (origin == null) return;
                                        final end = normalized(d.localPosition);
                                        final next = Rect.fromPoints(
                                          origin,
                                          end,
                                        );
                                        if (next.width >= .03 &&
                                            next.height >= .03) {
                                          setState(() => _crop = next);
                                        }
                                      },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    RotatedBox(
                                      quarterTurns: _turns,
                                      child: RawImage(
                                        image: _image,
                                        fit: BoxFit.fill,
                                      ),
                                    ),
                                    CustomPaint(
                                      painter: _StrokePainter(_strokes),
                                    ),
                                    if (_cropping)
                                      CustomPaint(painter: _CropOverlay(_crop)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            if (_cropping)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Проведите по фото, чтобы выбрать область обрезки.',
                ),
              ),
            if (_drawing)
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  for (final color in [
                    Colors.red,
                    Colors.orange,
                    Colors.yellow,
                    Colors.green,
                    Colors.blue,
                    Colors.white,
                    Colors.black,
                  ])
                    IconButton(
                      tooltip: 'Цвет кисти',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _penColor = color),
                      icon: Icon(
                        _penColor == color ? Icons.check_circle : Icons.circle,
                        color: color,
                      ),
                    ),
                  IconButton(
                    tooltip: 'Отменить штрих',
                    onPressed: _busy || _strokes.isEmpty
                        ? null
                        : () => setState(() => _strokes.removeLast()),
                    icon: const Icon(Icons.undo),
                  ),
                ],
              ),
            if (_error != null && _image != null) Text(_error!),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy || _image == null
                        ? null
                        : () => setState(() {
                            _turns = (_turns + 1) % 4;
                            for (final stroke in _strokes) {
                              for (var i = 0; i < stroke.points.length; i++) {
                                final point = stroke.points[i];
                                stroke.points[i] = Offset(
                                  1 - point.dy,
                                  point.dx,
                                );
                              }
                            }
                            _crop = const Rect.fromLTWH(0, 0, 1, 1);
                          }),
                    icon: const Icon(Icons.rotate_right),
                    label: const Text('Повернуть'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _image == null
                        ? null
                        : () => setState(() {
                            _cropping = !_cropping;
                            _drawing = false;
                          }),
                    icon: const Icon(Icons.crop),
                    label: Text(_cropping ? 'Область выбрана' : 'Обрезать'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _image == null
                        ? null
                        : () => setState(() {
                            _drawing = !_drawing;
                            _cropping = false;
                          }),
                    icon: const Icon(Icons.brush_outlined),
                    label: Text(_drawing ? 'Рисование включено' : 'Рисовать'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _turns = 0;
                            _crop = const Rect.fromLTWH(0, 0, 1, 1);
                            _cropping = false;
                            _drawing = false;
                            _strokes.clear();
                          }),
                    child: const Text('Сбросить'),
                  ),
                  FilledButton(
                    onPressed: _busy || _image == null ? null : _save,
                    child: Text(_busy ? 'Обработка…' : 'Готово'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StrokePainter extends CustomPainter {
  const _StrokePainter(this.strokes);
  final List<ChatPhotoStroke> strokes;
  @override
  void paint(Canvas canvas, Size size) => _paintStrokes(canvas, size, strokes);
  @override
  bool shouldRepaint(_StrokePainter oldDelegate) => true;
}

class _CropOverlay extends CustomPainter {
  const _CropOverlay(this.crop);
  final Rect crop;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(path, Paint()..color = Colors.black54);
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CropOverlay oldDelegate) => oldDelegate.crop != crop;
}
