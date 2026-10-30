import 'package:flutter/material.dart';

import '../models/vehicle.dart';
import '../services/garage_service.dart';
import '../screens/vehicle_detail_screen.dart';

class GarageProfileGallery extends StatefulWidget {
  const GarageProfileGallery({super.key, this.userId, this.isOwner = false});
  final String? userId;
  final bool isOwner;
  @override
  State<GarageProfileGallery> createState() => _GarageProfileGalleryState();
}

class _GarageProfileGalleryState extends State<GarageProfileGallery> {
  late Future<List<Vehicle>> _future;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final service = GarageService();
    _future = widget.isOwner
        ? service.fetchVehicles().then((rows) {
            if (!service.lastFetchSucceeded) {
              throw const GarageServiceException('Не удалось загрузить гараж');
            }
            return rows;
          })
        : service.fetchPublicVehicles(widget.userId!);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Vehicle>>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (snapshot.hasError) {
        return ListTile(
          title: const Text('Не удалось загрузить велосипеды'),
          trailing: IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(_load),
          ),
        );
      }
      final vehicles = snapshot.data ?? [];
      if (vehicles.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            widget.isOwner
                ? 'В гараже пока нет техники'
                : 'Пользователь пока не опубликовал велосипеды',
          ),
        );
      }
      return Column(
        children: [
          for (final vehicle in vehicles)
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VehicleDetailScreen(
                        vehicle: vehicle,
                        readOnly: !widget.isOwner,
                      ),
                    ),
                  );
                  if (mounted) setState(_load);
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (vehicle.photoUrl != null)
                      Image.network(
                        vehicle.photoUrl!,
                        height: 160,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(
                          height: 90,
                          child: Icon(Icons.directions_bike, size: 48),
                        ),
                      )
                    else
                      const SizedBox(
                        height: 90,
                        child: Icon(
                          Icons.directions_bike,
                          size: 48,
                          color: Colors.deepOrange,
                        ),
                      ),
                    ListTile(
                      title: Text(vehicle.name),
                      subtitle: Text(
                        '${vehicle.activityType.label} · ${vehicle.totalDistance.toStringAsFixed(1)} км${vehicle.isActive ? ' · Основной' : ''}',
                      ),
                      trailing: widget.isOwner
                          ? Icon(
                              vehicle.isPublic
                                  ? Icons.public
                                  : Icons.lock_outline,
                              size: 20,
                            )
                          : const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
