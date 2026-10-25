import 'package:flutter/material.dart';

import '../models/profile_cover_crop.dart';
import '../widgets/profile_cover_photo.dart';

class ProfileCoverEditor extends StatefulWidget {
  const ProfileCoverEditor({
    super.key,
    required this.image,
    this.initial = const ProfileCoverCrop(),
  });
  final ImageProvider image;
  final ProfileCoverCrop initial;
  @override
  State<ProfileCoverEditor> createState() => _ProfileCoverEditorState();
}

class _ProfileCoverEditorState extends State<ProfileCoverEditor> {
  late ProfileCoverCrop _crop = widget.initial;
  Size? _source;
  Size _frame = Size.zero;
  Offset _sourcePoint = Offset.zero;
  double _startZoom = 1;

  void _zoom(double zoom) {
    if (_source == null) return;
    final center = _frame.center(Offset.zero);
    setState(
      () => _crop = _crop.move(
        frame: _frame,
        source: _source!,
        sourcePoint: _crop.geometry(_frame, _source!).sourcePointAt(center),
        focalPoint: center,
        newZoom: zoom,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Кадрирование баннера'),
      actions: [
        TextButton(
          onPressed: () => setState(() => _crop = const ProfileCoverCrop()),
          child: const Text('Сбросить'),
        ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: _source == null
                  ? null
                  : () => Navigator.pop(context, _crop),
              child: const Text('Применить'),
            ),
          ),
        ],
      ),
    ),
    body: Column(
      children: [
        Expanded(
          flex: 3,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.clamp(
                0.0,
                constraints.maxHeight * ProfileCoverPhoto.aspectRatio,
              );
              _frame = Size(width, width / ProfileCoverPhoto.aspectRatio);
              return Center(
                child: SizedBox(
                  width: _frame.width,
                  height: _frame.height,
                  child: GestureDetector(
                    key: const Key('cover-crop-gesture'),
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (details) {
                      if (_source == null) return;
                      _startZoom = _crop.zoom;
                      _sourcePoint = _crop
                          .geometry(_frame, _source!)
                          .sourcePointAt(details.localFocalPoint);
                    },
                    onScaleUpdate: (details) {
                      if (_source == null) return;
                      setState(
                        () => _crop = _crop.move(
                          frame: _frame,
                          source: _source!,
                          sourcePoint: _sourcePoint,
                          focalPoint: details.localFocalPoint,
                          newZoom: _startZoom * details.scale,
                        ),
                      );
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ProfileCoverPhoto(
                          image: widget.image,
                          crop: _crop,
                          onSize: (size) {
                            if (_source != size) setState(() => _source = size);
                          },
                        ),
                        const IgnorePointer(
                          child: CustomPaint(painter: _CropGrid()),
                        ),
                        Positioned(
                          left: 20,
                          bottom: -30,
                          child: IgnorePointer(
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: .55),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                              ),
                              child: const Icon(
                                Icons.person_outline,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Flexible(
          flex: 2,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              children: [
                const Row(
                  children: [
                    Icon(Icons.pinch_outlined),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Перетаскивайте фото и разводите пальцы для увеличения. Круг показывает место аватара.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.zoom_out),
                    Expanded(
                      child: Slider(
                        value: _crop.zoom,
                        min: 1,
                        max: 4,
                        label: '${_crop.zoom.toStringAsFixed(1)}×',
                        onChanged: _source == null ? null : _zoom,
                      ),
                    ),
                    const Icon(Icons.zoom_in),
                  ],
                ),
                const Text(
                  'Фото применится к предпросмотру. Опубликуйте изменения кнопкой «Сохранить» в редакторе профиля.',
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _CropGrid extends CustomPainter {
  const _CropGrid();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(size.width * i / 3, 0),
        Offset(size.width * i / 3, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(0, size.height * i / 3),
        Offset(size.width, size.height * i / 3),
        paint,
      );
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_CropGrid oldDelegate) => false;
}
