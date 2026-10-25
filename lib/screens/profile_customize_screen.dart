import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/user_scope.dart';
import '../models/profile_cover_crop.dart';
import '../services/achievement_journey.dart';
import '../services/profile_photo_service.dart';
import '../services/profile_presentation_service.dart';
import '../services/profile_sync_service.dart';
import '../widgets/profile_identity_card.dart';
import 'profile_cover_editor.dart';
import '../utils/local_profile_photo.dart';

class ProfileCustomizeScreen extends StatefulWidget {
  const ProfileCustomizeScreen({
    super.key,
    required this.initial,
    required this.name,
    required this.avatar,
    required this.availableRanks,
    this.onChangeAvatar,
    this.onEditDetails,
    this.initialSection,
  });
  final ProfilePresentation initial;
  final String name;
  final Widget avatar;
  final List<JourneyRank> availableRanks;
  final Future<Widget> Function()? onChangeAvatar;
  final Future<String> Function()? onEditDetails;
  final String? initialSection;
  @override
  State<ProfileCustomizeScreen> createState() => _ProfileCustomizeScreenState();
}

enum _CoverAction { photo, crop, pattern, remove }

class _ProfileCustomizeScreenState extends State<ProfileCustomizeScreen> {
  static const _looks = [
    _ProfileLookPreset('Тёплый маршрут', '🌅', 'ember', 'road', 'ring'),
    _ProfileLookPreset('Морской ветер', '🌊', 'ocean', 'waves', 'double'),
    _ProfileLookPreset('Лесная тропа', '🌲', 'forest', 'summit', 'ring'),
    _ProfileLookPreset('Ночная поездка', '🌙', 'slate', 'dots', 'plain'),
  ];
  final _photos = ProfilePhotoService();
  final _owner = UserScope.currentUserId();
  late String _accent = widget.initial.accent;
  late String _cover = widget.initial.cover;
  late String _frame = widget.initial.frame;
  late String _bio = widget.initial.bio;
  late bool _show = widget.initial.showAwards;
  late List<String> _featured = widget.initial.featured
      .where(
        (id) => widget.initial.rewards.any(
          (r) => r.id == id && r.kind == 'achievement',
        ),
      )
      .toList();
  late String? _title = widget.initial.rankTitle ?? widget.initial.title?.id;
  late String? _coverPath = widget.initial.coverPhotoPath;
  late ProfileCoverCrop _crop = widget.initial.coverCrop;
  late Widget _avatar = widget.avatar;
  late String _name = widget.name;
  String? _pendingPhoto, _error;
  late String? _localPhoto = widget.initial.localCoverPhotoPath;
  bool _busy = false, _picking = false, _allowPop = false, _asking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (widget.initialSection) {
        case 'cover':
          _editCover();
        case 'title':
          _editTitle();
        case 'bio':
          _editBio();
      }
    });
  }

  bool get _hasPhoto =>
      _pendingPhoto != null || _localPhoto != null || _coverPath != null;
  ImageProvider? get _photo =>
      localProfilePhoto(_pendingPhoto ?? _localPhoto) ??
      (_coverPath == null || widget.initial.coverPhotoUrl == null
          ? null
          : CachedNetworkImageProvider(widget.initial.coverPhotoUrl!));
  ProfilePresentation get _style => ProfilePresentation(
    accent: _accent,
    cover: _cover,
    frame: _frame,
    bio: _bio,
    showAwards: _show,
    featured: _featured,
    rewards: widget.initial.rewards,
    coverPhotoPath: _coverPath,
    coverPhotoUrl: _coverPath == null ? null : widget.initial.coverPhotoUrl,
    coverCrop: _crop,
    localCoverPhotoPath: _localPhoto,
  );
  bool get _dirty =>
      _accent != widget.initial.accent ||
      _cover != widget.initial.cover ||
      _frame != widget.initial.frame ||
      _bio != widget.initial.bio ||
      _show != widget.initial.showAwards ||
      _title != (widget.initial.rankTitle ?? widget.initial.title?.id) ||
      _coverPath != widget.initial.coverPhotoPath ||
      _pendingPhoto != null ||
      _localPhoto != widget.initial.localCoverPhotoPath ||
      _crop != widget.initial.coverCrop ||
      _featured.join(',') != widget.initial.featured.join(',');

  void _leave([bool? saved]) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, saved);
    });
  }

  Future<void> _close() async {
    if (_busy || _picking || _asking) return;
    if (!_dirty) {
      _leave();
      return;
    }
    _asking = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Сохранить новый образ?'),
        content: const Text('Изменения ещё видны только в предпросмотре.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Продолжить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Выйти без сохранения'),
          ),
        ],
      ),
    );
    _asking = false;
    if (discard == true && mounted) _leave();
  }

  Future<T?> _sheet<T>(String title, Widget child) => showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: Duration(milliseconds: 280),
            reverseDuration: Duration(milliseconds: 180),
          ),
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * .86),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            20 + MediaQuery.viewInsetsOf(c).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _editCover() async {
    final action = await _sheet<_CoverAction>(
      'Баннер профиля',
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _option(
            Icons.add_photo_alternate_outlined,
            _hasPhoto ? 'Заменить фотографию' : 'Выбрать фотографию',
            'Из галереи, с настройкой кадра',
            () => Navigator.pop(context, _CoverAction.photo),
          ),
          if (_hasPhoto)
            _option(
              Icons.crop,
              'Расположить фотографию',
              'Положение и масштаб',
              () => Navigator.pop(context, _CoverAction.crop),
            ),
          _option(
            Icons.texture,
            'Цвет и узор',
            'Оформление без фотографии',
            () => Navigator.pop(context, _CoverAction.pattern),
          ),
          if (_hasPhoto)
            _option(
              Icons.hide_image_outlined,
              'Убрать фото с баннера',
              'Вернуться к цвету и узору',
              () => Navigator.pop(context, _CoverAction.remove),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _CoverAction.photo:
        await _choosePhoto();
      case _CoverAction.crop:
        await _reframe();
      case _CoverAction.pattern:
        await _editPattern();
      case _CoverAction.remove:
        setState(() {
          _coverPath = null;
          _pendingPhoto = null;
          _localPhoto = null;
          _crop = const ProfileCoverCrop();
        });
    }
  }

  Future<void> _choosePhoto() async {
    setState(() => _picking = true);
    try {
      final path = await _photos.pickCoverFromGallery();
      if (path == null || !mounted) return;
      final crop = await Navigator.push<ProfileCoverCrop>(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileCoverEditor(image: FileImage(File(path))),
        ),
      );
      if (crop != null && mounted)
        setState(() {
          _pendingPhoto = path;
          _crop = crop;
        });
    } on ProfilePhotoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _reframe() async {
    final image = _photo;
    if (image == null) return;
    final crop = await Navigator.push<ProfileCoverCrop>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileCoverEditor(image: image, initial: _crop),
      ),
    );
    if (crop != null && mounted) setState(() => _crop = crop);
  }

  Widget _palette(String selected, ValueChanged<String> changed) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final entry in ProfilePresentation.colors.entries)
        Semantics(
          label:
              ProfilePresentation.colorNames[ProfilePresentation.colors.keys
                  .toList()
                  .indexOf(entry.key)],
          selected: selected == entry.key,
          child: InkWell(
            onTap: () => changed(entry.key),
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: entry.value,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected == entry.key
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.transparent,
                  width: 3,
                ),
              ),
              child: selected == entry.key
                  ? const Icon(Icons.check, color: Colors.white)
                  : null,
            ),
          ),
        ),
    ],
  );

  Future<void> _editAccent() async {
    var value = _accent;
    final result = await _sheet<String>(
      'Акцент профиля',
      StatefulBuilder(
        builder: (c, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _palette(value, (v) => update(() => value = v)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(c, value),
              child: const Text('Применить цвет'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) setState(() => _accent = result);
  }

  Future<void> _editPattern() async {
    var accent = _accent, cover = _cover;
    final result = await _sheet<(String, String)>(
      'Цвет и узор баннера',
      StatefulBuilder(
        builder: (c, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ProfileIdentityCard(
              name: _name,
              avatar: _avatar,
              style: ProfilePresentation(
                accent: accent,
                cover: cover,
                frame: _frame,
              ),
            ),
            const SizedBox(height: 20),
            _palette(accent, (v) => update(() => accent = v)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final pattern in ProfilePresentation.covers.entries)
                  ChoiceChip(
                    label: Text(pattern.value),
                    selected: cover == pattern.key,
                    onSelected: (_) => update(() => cover = pattern.key),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_hasPhoto)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'После применения узор заменит фотографию на баннере.',
                ),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(c, (accent, cover)),
              child: const Text('Применить к баннеру'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted)
      setState(() {
        _accent = result.$1;
        _cover = result.$2;
        _coverPath = null;
        _pendingPhoto = null;
        _localPhoto = null;
        _crop = const ProfileCoverCrop();
      });
  }

  Future<void> _editAvatar() async {
    var frame = _frame;
    final result = await _sheet<String>(
      'Аватар и рамка',
      StatefulBuilder(
        builder: (c, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(c)
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: frame == 'plain'
                          ? Colors.transparent
                          : _style.color,
                      width: frame == 'double' ? 6 : 3,
                    ),
                  ),
                  child: _avatar,
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const {
                  'plain': 'Без рамки',
                  'ring': 'Кольцо',
                  'double': 'Двойная',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: frame == entry.key,
                    onSelected: (_) => update(() => frame = entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(c, frame),
              child: const Text('Применить рамку'),
            ),
            if (widget.onChangeAvatar != null)
              TextButton.icon(
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Сменить фото или значок аватара'),
                onPressed: () async {
                  Navigator.pop(c, frame);
                  final avatar = await widget.onChangeAvatar!();
                  if (mounted) setState(() => _avatar = avatar);
                },
              ),
          ],
        ),
      ),
    );
    if (result != null && mounted) setState(() => _frame = result);
  }

  Future<void> _editTitle() async {
    final ranks = [...widget.availableRanks];
    final stored = JourneyRank.all
        .where((r) => 'rank:${r.xp}' == _title)
        .firstOrNull;
    if (stored != null && !ranks.contains(stored)) ranks.add(stored);
    final result = await _sheet<String>(
      'Титул под именем',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Выбирайте любой открытый ранг или особый титул. Новые ранги открываются за XP.',
          ),
          const SizedBox(height: 8),
          _titleOption(
            'auto',
            'Текущий ранг автоматически',
            Icons.auto_awesome_outlined,
            null,
          ),
          for (final rank in ranks)
            _titleOption(
              'rank:${rank.xp}',
              '${rank.icon}  ${rank.name}',
              null,
              '${rank.xp} XP',
            ),
          if (widget.initial.rewards.any((r) => r.kind == 'title'))
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(
                'Особые титулы',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          for (final award in widget.initial.rewards.where(
            (r) => r.kind == 'title',
          ))
            _titleOption(award.id, '${award.icon}  ${award.label}', null, null),
        ],
      ),
    );
    if (result != null && mounted)
      setState(() => _title = result == 'auto' ? null : result);
  }

  Widget _titleOption(
    String id,
    String label,
    IconData? icon,
    String? subtitle,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: icon == null ? null : Icon(icon),
    title: Text(label),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: (_title ?? 'auto') == id
        ? Icon(Icons.check_circle, color: _style.color)
        : null,
    onTap: () => Navigator.pop(context, id),
  );

  Future<void> _editBio() async {
    final controller = TextEditingController(text: _bio);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('О себе'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 240,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Где катаюсь и что люблю',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    // Dispose after the dialog's closing animation has finished.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (result != null && mounted) setState(() => _bio = result);
  }

  Future<void> _editAwards() async {
    var show = _show;
    final selected = List<String>.of(_featured);
    final awards = widget.initial.rewards
        .where((r) => r.kind == 'achievement')
        .toList();
    final result = await _sheet<(bool, List<String>)>(
      'Витрина наград',
      StatefulBuilder(
        builder: (c, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Показывать витрину'),
              value: show,
              onChanged: (v) => update(() => show = v),
            ),
            const Text(
              'Выберите до 6 наград. Перетаскивайте выбранные, чтобы изменить порядок.',
            ),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: selected.length,
              onReorderItem: (oldIndex, newIndex) => update(() {
                final id = selected.removeAt(oldIndex);
                selected.insert(newIndex, id);
              }),
              itemBuilder: (c, i) {
                final award = awards
                    .where((r) => r.id == selected[i])
                    .firstOrNull;
                return ListTile(
                  key: ValueKey(selected[i]),
                  leading: Text(award?.icon ?? '🏅'),
                  title: Text(award?.label ?? 'Награда'),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                  onTap: () => update(() => selected.removeAt(i)),
                );
              },
            ),
            for (final award in awards.where((r) => !selected.contains(r.id)))
              ListTile(
                leading: Text(award.icon),
                title: Text(award.label),
                trailing: const Icon(Icons.add_circle_outline),
                enabled: selected.length < 6,
                onTap: () => update(() => selected.add(award.id)),
              ),
            if (awards.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Заработанные награды появятся здесь после синхронизации тренировок.',
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(c, (show, selected)),
              child: const Text('Применить к витрине'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted)
      setState(() {
        _show = result.$1;
        _featured = result.$2;
      });
  }

  Future<void> _ideas() async {
    _ProfileLookPreset? preview;
    final result = await _sheet<_ProfileLookPreset>(
      'Идеи оформления',
      StatefulBuilder(
        builder: (c, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Необязательные сочетания. Сначала посмотрите пример, затем решите, применять ли его.',
            ),
            const SizedBox(height: 16),
            ProfileIdentityCard(
              name: _name,
              avatar: _avatar,
              coverPhoto: _photo,
              style: preview == null
                  ? _style
                  : ProfilePresentation(
                      accent: preview!.accent,
                      cover: preview!.cover,
                      frame: preview!.frame,
                      coverCrop: _crop,
                    ),
            ),
            const SizedBox(height: 16),
            for (final look in _looks)
              ListTile(
                leading: Text(look.icon, style: const TextStyle(fontSize: 24)),
                title: Text(look.name),
                trailing: preview == look
                    ? Icon(
                        Icons.check_circle,
                        color: ProfilePresentation.colors[look.accent],
                      )
                    : const Icon(Icons.visibility_outlined),
                onTap: () => update(() => preview = look),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Сочетание меняет акцент, рамку и узор. Ваше фото, титул и награды сохраняются.',
              ),
            ),
            FilledButton(
              onPressed: preview == null
                  ? null
                  : () => Navigator.pop(c, preview),
              child: const Text('Использовать сочетание'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Оставить мой вариант'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted)
      setState(() {
        _accent = result.accent;
        _cover = result.cover;
        _frame = result.frame;
      });
  }

  Future<void> _save() async {
    if (_busy || _picking) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_owner != UserScope.currentUserId())
        throw const ProfileSyncException(
          'Аккаунт изменился. Откройте профиль заново.',
        );
      if (_owner != UserScope.currentUserId())
        throw const ProfileSyncException(
          'Аккаунт изменился. Откройте профиль заново.',
        );
      await ProfilePresentationService().save(
        _style,
        _title,
        newCoverPhoto: _pendingPhoto,
      );
      if (mounted) _leave(true);
    } catch (e) {
      if (mounted)
        setState(
          () => _error = e is ProfileSyncException ? e.message : 'Не удалось сохранить. Ваши изменения остались в предпросмотре. Попробуйте ещё раз.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _option(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 4),
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final rank = _title == null
        ? widget.availableRanks.lastOrNull
        : JourneyRank.all.where((r) => 'rank:${r.xp}' == _title).firstOrNull;
    final award = widget.initial.rewards
        .where((r) => r.id == _title)
        .firstOrNull;
    return PopScope(
      canPop: !_busy && !_picking && (_allowPop || !_dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Мой профиль'),
          leading: BackButton(onPressed: _close),
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_dirty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Изменения ещё не опубликованы',
                    textAlign: TextAlign.center,
                  ),
                ),
              FilledButton.icon(
                onPressed: _busy || _picking || !_dirty ? null : _save,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(
                  _busy ? 'Сохраняем профиль…' : 'Сохранить изменения',
                ),
              ),
            ],
          ),
        ),
        body: AbsorbPointer(
          absorbing: _busy || _picking,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Text(
                'Ваш профиль — ваш образ',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Нажмите на баннер, аватар, титул или текст о себе, чтобы изменить их.',
              ),
              const SizedBox(height: 20),
              ProfileIdentityCard(
                name: _name,
                avatar: _avatar,
                style: _style,
                coverPhoto: _photo,
                title: rank?.name ?? award?.label,
                titleIcon: rank?.icon ?? award?.icon,
                onEditCover: _editCover,
                onEditAvatar: _editAvatar,
                onEditTitle: _editTitle,
                onEditBio: _editBio,
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (c, constraints) => Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: constraints.maxWidth < 300
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 12) / 2,
                      child: _actionCard(
                        Icons.palette_outlined,
                        'Акцент',
                        'Цвет деталей',
                        _editAccent,
                      ),
                    ),
                    SizedBox(
                      width: constraints.maxWidth < 300
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 12) / 2,
                      child: _actionCard(
                        Icons.auto_awesome_outlined,
                        'Идеи',
                        'Посмотреть сочетания',
                        _ideas,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: _editAwards,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.workspace_premium_outlined),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Витрина наград',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            const Icon(Icons.edit_outlined, size: 18),
                          ],
                        ),
                        Text(
                          _show
                              ? '${_featured.length} из 6 наград · нажмите для настройки'
                              : 'Витрина скрыта · нажмите для настройки',
                        ),
                        ProfileAwardsShowcase(style: _style),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.onEditDetails != null) ...[
                const SizedBox(height: 16),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.manage_accounts_outlined),
                    title: const Text('Имя, город и личные сведения'),
                    subtitle: const Text('Открыть отдельную форму'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final name = await widget.onEditDetails!();
                      if (mounted) setState(() => _name = name);
                    },
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                'Изменения сохраняются на телефоне. Когда появится интернет, они автоматически отправятся в облако и станут видны другим пользователям.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionCard(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Card(
    margin: EdgeInsets.zero,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: _style.color),
            const SizedBox(height: 10),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}

class _ProfileLookPreset {
  const _ProfileLookPreset(
    this.name,
    this.icon,
    this.accent,
    this.cover,
    this.frame,
  );
  final String name, icon, accent, cover, frame;
}
