import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:pulsepath/widgets/primary_map_portal.dart';

/// Mount the real primary map when testing a screen that opens a map task.
class MainMapTestHost extends StatefulWidget {
  const MainMapTestHost({super.key, required this.child});
  final Widget child;
  @override
  State<MainMapTestHost> createState() => _MainMapTestHostState();
}

class _MainMapTestHostState extends State<MainMapTestHost> {
  final controller = MapController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      PrimaryMapPortal(
        controller: controller,
        onOpen: () {},
        child: FlutterMap(
          mapController: controller,
          options: MapOptions(onTap: PrimaryMapNavigation.instance.tap),
          children: const [
            SizedBox.expand(child: ColoredBox(color: Colors.white)),
            PrimaryMapTaskLayers(),
          ],
        ),
      ),
      widget.child,
    ],
  );
}
