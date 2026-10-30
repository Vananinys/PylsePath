part of '../../main.dart';

/// Маркеры на карте: местоположение пользователя и друзья.
mixin _MapMarkersMixin on _MapScreenStateBase {
  Widget _buildUserLocationMarker() {
    // Угол обновляется через headingListenable (до 50 Гц), без rebuild экрана.
    return ValueListenableBuilder<double>(
      valueListenable: _navigationController.headingListenable,
      builder: (context, heading, _) {
        return _buildUserLocationMarkerInner(heading);
      },
    );
  }

  Widget _buildUserLocationMarkerInner(double heading) {
    // Соглашение о знаках в flutter_map 7 (сверено с исходниками пакета):
    //  * MobileLayerTransformer крутит ВЕСЬ слой карты на
    //    `Transform.rotate(angle: +camera.rotationRad)`, а в экранных
    //    координатах Flutter (ось Y вниз) положительный угол = ПО ЧАСОВОЙ;
    //  * MarkerLayer при `Marker(rotate: true)` компенсирует это
    //    (`Transform.rotate(angle: -map.rotationRad)`), поэтому угол,
    //    переданный в RiderMarker, — уже чистый ЭКРАННЫЙ.
    //
    // Направление движения в экранных координатах = heading + camera.rotation,
    // значит именно это и нужно отдать маркеру:
    //  * follow («Север вверху»): camera.rotation == 0 -> angle == heading;
    //  * followAndHeading («По направлению»): карта повёрнута на -heading
    //    (см. moveAndRotate ниже) -> angle == 0, стрелка строго вверх,
    //    а под ней вращается карта.
    //
    // Важно: знак здесь «+», а не «-», потому что поворот карты и поворот
    // маркера складываются, а не вычитаются. Формула самосогласована при
    // любом camera.rotation (в т.ч. когда пользователь вручную повернул карту).
    final double cameraRotation = _isMapReady
        ? _mapController.camera.rotation
        : 0.0;
    final double relativeHeading = RiderMarker.normalizeSigned(
      heading + cameraRotation,
    );

    // Маркер в стиле маркеров друзей (аватар + имя), но кольцо с курсом
    // вращается за поворотами пользователя. Аватар берём из общего кэша
    // профиля; подпись не вращаем, чтобы имя всегда читалось.
    final profile = context.read<ProfileProvider>().profile;
    final url = profile.avatarUrl;
    final hasUrl =
        url != null &&
        (url.startsWith('http://') || url.startsWith('https://'));

    return SizedBox(
      width: 64,
      height: 76,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Кольцо с треугольным указателем: вращается по курсу.
                Transform.rotate(
                  angle: relativeHeading * math.pi / 180.0,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          top: -6,
                          left: (44 - 10) / 2,
                          child: CustomPaint(
                            size: const Size(10, 7),
                            painter: _HeadingArrowPainter(),
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF1E88E5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Аватар поверх кольца — статичен, крутится только указатель.
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.deepOrange.shade50,
                  backgroundImage: hasUrl ? NetworkImage(url) : null,
                  child: hasUrl
                      ? null
                      : Text(
                          profile.username.trim().isEmpty
                              ? 'Я'
                              : profile.username.characters.first.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepOrange,
                          ),
                        ),
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF1E88E5)),
            ),
            child: const Text(
              'Вы',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E88E5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Маркер друга на карте: аватар с зелёной рамкой и именем снизу.
  Widget _buildFriendMarker(friend, {bool selected = false}) {
    final url = friend.avatarUrl;
    final hasUrl =
        url != null &&
        (url.startsWith('http://') || url.startsWith('https://'));
    final Color markerColor = friend.isLive ? Colors.green : Colors.grey;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: markerColor, width: 2.5),
                color: Colors.white,
              ),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: Colors.deepOrange.shade50,
                backgroundImage: hasUrl ? NetworkImage(url) : null,
                child: hasUrl
                    ? null
                    : Text(
                        friend.username.isEmpty
                            ? 'Р'
                            : friend.username.characters.first.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.deepOrange,
                        ),
                      ),
              ),
            ),
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: markerColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    friend.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: markerColor,
                    ),
                  ),
                  if (friend.hasFreshMotion)
                    Text(
                      friend.motionText,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFF455A64),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Треугольный указатель курса над маркером пользователя (остриём вверх,
/// вращается вместе с кольцом маркера).
class _HeadingArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1E88E5)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
