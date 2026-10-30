import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/satellite_map.dart';

class MapCredits extends StatelessWidget {
  const MapCredits({super.key, this.layer = 0});
  final int layer;
  Widget _link(BuildContext context, String label, String url) => InkWell(
    onTap: () =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        color: Theme.of(context).colorScheme.onSurface,
        decoration: TextDecoration.underline,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
    borderRadius: BorderRadius.circular(5),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Wrap(
          spacing: 6,
          runSpacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (layer == 4)
              _link(context, '© CARTO', 'https://carto.com/attributions'),
            if (layer == 3)
              InkWell(
                onTap: () => launchUrl(
                  Uri.parse('https://www.maptiler.com'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Image.asset(
                  'assets/maptiler-logo.png',
                  width: 74,
                  height: 22,
                  fit: BoxFit.contain,
                  semanticLabel: 'MapTiler',
                ),
              ),
            if (layer == 3)
              _link(
                context,
                SatelliteMap.attribution,
                'https://www.maptiler.com/copyright/',
              ),
            if (layer == 1)
              _link(context, '© OpenTopoMap', 'https://opentopomap.org/about'),
            if (layer == 2)
              _link(context, '© CyclOSM', 'https://www.cyclosm.org/'),
            _link(
              context,
              '© OpenStreetMap contributors',
              'https://www.openstreetmap.org/copyright',
            ),
          ],
        ),
      ),
    ),
  );
}
