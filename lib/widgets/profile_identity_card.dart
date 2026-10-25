import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/profile_presentation_service.dart';
import 'profile_cover_photo.dart';
import '../utils/local_profile_photo.dart';

class ProfileIdentityCard extends StatelessWidget {
  const ProfileIdentityCard({
    super.key,
    required this.name,
    required this.avatar,
    required this.style,
    this.status = '',
    this.city = '',
    this.sport = '',
    this.title,
    this.titleIcon,
    this.coverImage,
    this.coverPhoto,
    this.onEditCover,
    this.onEditAvatar,
    this.onEditTitle,
    this.onEditBio,
    this.onCustomize,
    this.avatarDiameter = 96,
  });
  final String name, status, city, sport;
  final String? title, titleIcon;
  final Widget? coverImage;
  final ImageProvider? coverPhoto;
  final VoidCallback? onEditCover, onEditAvatar, onEditTitle, onEditBio;
  final Widget avatar;
  final ProfilePresentation style;
  final VoidCallback? onCustomize;
  final double avatarDiameter;

  @override
  Widget build(BuildContext context) {
    final color = style.color;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final photo =
        coverPhoto ?? localProfilePhoto(style.localCoverPhotoPath) ??
        (style.coverPhotoUrl == null
            ? null
            : CachedNetworkImageProvider(style.coverPhotoUrl!));
    final avatarExtent =
        avatarDiameter +
        (style.frame == 'plain'
            ? 8
            : style.frame == 'double'
            ? 26
            : 18);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width - 40;
          final bannerHeight = width / ProfileCoverPhoto.aspectRatio;
          return Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: bannerHeight,
                    child: Semantics(
                      button: onEditCover != null,
                      label: onEditCover == null
                          ? 'Баннер профиля'
                          : 'Изменить баннер',
                      child: InkWell(
                        onTap: onEditCover,
                        child: AnimatedContainer(
                          duration: motion,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                color,
                                Color.lerp(
                                  color,
                                  const Color(0xFF102C3A),
                                  .62,
                                )!,
                              ],
                            ),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (coverImage != null)
                                coverImage!
                              else if (photo != null)
                                ProfileCoverPhoto(
                                  image: photo,
                                  crop: style.coverCrop,
                                )
                              else
                                CustomPaint(
                                  painter: _ProfileCoverPainter(style.cover),
                                ),
                              if (onEditCover != null)
                                Positioned(
                                  right: 12,
                                  top: 12,
                                  child: _editBadge('Баннер', onEditCover!),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      avatarExtent - 32 + 16,
                      20,
                      20,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (status.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(
                              status,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (title != null || onEditTitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: InkWell(
                              onTap: onEditTitle,
                              borderRadius: BorderRadius.circular(14),
                              child: AnimatedContainer(
                                duration: motion,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                constraints: onEditTitle == null
                                    ? null
                                    : const BoxConstraints(minHeight: 48),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: AnimatedSwitcher(
                                  duration: motion,
                                  child: Text(
                                    '${titleIcon ?? '🏅'}  ${title ?? 'Выберите титул'}${onEditTitle != null ? '  ✎' : ''}',
                                    key: ValueKey((title, titleIcon)),
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (city.isNotEmpty || sport.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                if (city.isNotEmpty) Text('📍 $city'),
                                if (sport.isNotEmpty)
                                  Text(sport, style: TextStyle(color: color)),
                              ],
                            ),
                          ),
                        if (style.bio.isNotEmpty || onEditBio != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: InkWell(
                              onTap: onEditBio,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Text(
                                  style.bio.isEmpty
                                      ? 'Расскажите о себе  ✎'
                                      : '${style.bio}${onEditBio != null ? '  ✎' : ''}',
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              // The complete avatar is inside this Stack's hit-test bounds.
              Positioned(
                left: 20,
                top: bannerHeight - 32,
                child: Semantics(
                  label: 'Изменить аватар и рамку',
                  button: onEditAvatar != null,
                  child: InkWell(
                    key: const Key('profile-avatar-edit'),
                    onTap: onEditAvatar,
                    customBorder: const CircleBorder(),
                    child: AnimatedContainer(
                      duration: motion,
                      padding: EdgeInsets.all(style.frame == 'plain' ? 4 : 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.surface,
                        border: style.frame == 'plain'
                            ? null
                            : Border.all(color: color, width: 3),
                      ),
                      child: Container(
                        padding: EdgeInsets.all(
                          style.frame == 'double' ? 3 : 0,
                        ),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: style.frame == 'double'
                              ? Border.all(color: color)
                              : null,
                        ),
                        child: Stack(
                          alignment: Alignment.bottomRight,
                          children: [
                            SizedBox.square(
                              dimension: avatarDiameter,
                              child: FittedBox(child: avatar),
                            ),
                            if (onEditAvatar != null)
                              const CircleAvatar(
                                radius: 12,
                                child: Icon(Icons.edit, size: 13),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (onCustomize != null)
                Positioned(
                  right: 12,
                  top: bannerHeight + 8,
                  child: IconButton.filledTonal(
                    tooltip: 'Оформить профиль',
                    onPressed: onCustomize,
                    icon: const Icon(Icons.palette_outlined),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _editBadge(String label, VoidCallback onTap) => Material(
    color: Colors.black54,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.edit_outlined, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    ),
  );
}

class ProfileAwardsShowcase extends StatelessWidget {
  const ProfileAwardsShowcase({super.key, required this.style});
  final ProfilePresentation style;
  @override
  Widget build(BuildContext context) {
    final awards = style.showcase;
    if (awards.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Витрина наград',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final award in awards)
                  SizedBox(
                    width: constraints.maxWidth < 270
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 10) / 2,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: style.color.withValues(alpha: .07),
                        border: Border.all(
                          color: style.color.withValues(alpha: .16),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            award.icon,
                            style: const TextStyle(fontSize: 30),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            award.label,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            'В коллекции',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileCoverPainter extends CustomPainter {
  const _ProfileCoverPainter(this.pattern);
  final String pattern;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (pattern == 'plain') return;
    if (pattern == 'dots') {
      paint.style = PaintingStyle.fill;
      for (var x = 10.0; x < size.width; x += 22) {
        for (var y = 10.0; y < size.height; y += 22) {
          canvas.drawCircle(Offset(x, y), 2, paint);
        }
      }
      return;
    }
    if (pattern == 'contour') {
      for (var i = 0; i < 10; i++) {
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(size.width * .72, size.height * .8),
            width: 35 + i * 42,
            height: 18 + i * 25,
          ),
          paint,
        );
      }
      return;
    }
    for (var i = 0; i < 6; i++) {
      final path = Path();
      for (var x = 0.0; x <= size.width; x += 3) {
        final y = pattern == 'summit'
            ? size.height * .65 + i * 14 - (1 - ((x / 70) % 2 - 1).abs()) * 45
            : size.height * .35 +
                  i * 19 +
                  math.sin(x / (pattern == 'road' ? 100 : 45) + i * .25) * 22;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ProfileCoverPainter oldDelegate) =>
      oldDelegate.pattern != pattern;
}
