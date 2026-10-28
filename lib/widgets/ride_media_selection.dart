import 'package:flutter/material.dart';

import '../data/ride_media_repository.dart';
import '../models/ride_media.dart';

class RideMediaSelection extends StatefulWidget {
  const RideMediaSelection({
    super.key,
    required this.rideId,
    required this.enabled,
    required this.onChanged,
    this.busy = false,
  });
  final String rideId;
  final bool enabled;
  final bool busy;
  final ValueChanged<Set<String>> onChanged;
  @override
  State<RideMediaSelection> createState() => _RideMediaSelectionState();
}

class _RideMediaSelectionState extends State<RideMediaSelection> {
  Set<String> _ids = {};
  Future<void> _pick() async {
    try {
      final rows = await RideMediaRepository(widget.rideId).load();
      if (!mounted) return;
      if (rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Сначала прикрепите фото или видео в деталях поездки',
            ),
          ),
        );
        return;
      }
      final selected = Set<String>.of(_ids);
      final result = await showModalBottomSheet<Set<String>>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (sheet) => StatefulBuilder(
          builder: (sheet, change) => SizedBox(
            height: MediaQuery.sizeOf(sheet).height * .65,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Материалы и их места будут видны получателям. Скрытые участки исключаются.',
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final item in rows)
                        CheckboxListTile(
                          value: selected.contains(item.id),
                          secondary: Icon(
                            item.kind == RideMediaKind.video
                                ? Icons.videocam
                                : Icons.photo,
                          ),
                          title: Text(
                            item.caption.isEmpty
                                ? (item.kind == RideMediaKind.video
                                      ? 'Видео'
                                      : 'Фото')
                                : item.caption,
                          ),
                          subtitle: Text('Точка ${item.pointIndex + 1}'),
                          onChanged: (value) => change(() {
                            if (value == true) {
                              selected.add(item.id);
                            } else {
                              selected.remove(item.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(sheet, selected),
                  child: const Text('Выбрать для отправки'),
                ),
              ],
            ),
          ),
        ),
      );
      if (mounted && result != null) {
        setState(() => _ids = result);
        widget.onChanged(Set.unmodifiable(result));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось прочитать материалы поездки'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        onPressed: widget.enabled && !widget.busy ? _pick : null,
        icon: const Icon(Icons.perm_media_outlined),
        label: Text(
          'Фото и видео с местами · выбрано ${widget.enabled ? _ids.length : 0}',
        ),
      ),
      if (!widget.enabled)
        const Text(
          'Для материалов с местами включите показ трека.',
          style: TextStyle(fontSize: 12),
        ),
    ],
  );
}
