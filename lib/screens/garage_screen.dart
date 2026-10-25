import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/user_profile_repository.dart';
import '../models/transport_type.dart';
import '../models/user_profile.dart';
import '../services/garage_service.dart';
import 'vehicle_detail_screen.dart';
import '../models/activity_type.dart';

class GarageScreen extends StatefulWidget {
  const GarageScreen({super.key});

  @override
  State<GarageScreen> createState() => _GarageScreenState();
}

class _GarageScreenState extends State<GarageScreen> {
  final UserProfileRepository _repository = UserProfileRepository();
  final GarageService _garageService = GarageService();

  /// Профиль пользователя. null, пока идёт загрузка, — build() в этом случае
  /// показывает CircularProgressIndicator и не обращается к данным.
  UserProfile? _profile;
  bool _isLoading = true;
  int _loadGeneration = 0;

  final TextEditingController _bikeNameController = TextEditingController();
  final TextEditingController _bikeWeightController = TextEditingController();
  final TextEditingController _bikeWheelSizeController =
      TextEditingController();
  TransportType _selectedTransport = TransportType.bicycle;
  bool _isEbike = false;

  /// Идёт загрузка фото техники (иконка камеры показывает спиннер).
  String? _photoBusyBikeId;
  bool _adding = false;
  ActivityType _bikeActivity = ActivityType.mountainBiking;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _loadGeneration++;
    _bikeNameController.dispose();
    _bikeWeightController.dispose();
    _bikeWheelSizeController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final generation = ++_loadGeneration;
    // Спиннер показываем только на первой загрузке, чтобы обновления после
    // добавления/удаления не «мигали» полноэкранным индикатором.
    if (mounted && _profile == null) {
      setState(() => _isLoading = true);
    }
    // Локальный профиль и облачный гараж не зависят друг от друга — грузим
    // параллельно, чтобы экран открывался быстрее.
    final refresh = _garageService.fetchVehicles();
    await _repository.load();
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _profile = _repository.profile;
      _isLoading = false;
    });
    final vehicles = await refresh;
    if (!mounted || generation != _loadGeneration) return;
    // `garage` в Supabase — источник правды. Если в облаке есть техника,
    // зеркалим её в локальный профиль (id совпадают с облачными строками).
    // При сетевой ошибке сохраняем локальное зеркало; успешный пустой ответ очищает его.
    if (_garageService.lastFetchSucceeded) {
      final bikes = vehicles.map((vehicle) => vehicle.toBike()).toList();
      final active = vehicles.where((vehicle) => vehicle.isActive).toList();
      await _repository.updateGarageCache(
        garage: bikes,
        selectedBike: active.isNotEmpty ? active.first.toBike() : null,
      );
      await _repository.load();
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _profile = _repository.profile;
      _isLoading = false;
    });
  }

  Future<void> _addBike() async {
    // Добавляем только после полной загрузки профиля (форма станет видна
    // пользователю лишь тогда, когда данные получены из Supabase).
    if (_isLoading || _profile == null || _adding) return;
    final name = _bikeNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название транспорта')),
      );
      return;
    }
    // Вес и размер колёс — необязательные числовые поля. Пусто → 0, а вот
    // неразобранная строка («29о») — ошибка формы, а не молчаливый ноль.
    final weightText = _bikeWeightController.text.trim().replaceAll(',', '.');
    final wheelText = _bikeWheelSizeController.text.trim().replaceAll(',', '.');
    double? parseNumber(String text) =>
        text.isEmpty ? 0 : double.tryParse(text);
    final weight = parseNumber(weightText);
    final wheelSize = parseNumber(wheelText);
    if (weight == null ||
        wheelSize == null ||
        !weight.isFinite ||
        !wheelSize.isFinite ||
        weight < 0 ||
        weight > 150 ||
        wheelSize < 0 ||
        wheelSize > 40) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Вес и размер колёс — числа (например, 14.5 или 29). '
            'Оставьте поле пустым, чтобы пропустить.',
          ),
        ),
      );
      return;
    }

    try {
      setState(() => _adding = true);
      // Чистый INSERT в `garage` (без Storage). Первая техника — активная.
      final isFirst = _profile!.garage.isEmpty;
      final cloudId = await _garageService.addVehicle(
        name: name,
        transportType: _selectedTransport == TransportType.bicycle
            ? _bikeActivity.name
            : _selectedTransport.label,
        weightKg: weight,
        wheelSize: wheelSize,
        isActive: isFirst,
        isEbike: _isEbike,
      );

      if (cloudId == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось сохранить транспорт. Проверьте интернет.',
            ),
          ),
        );
        return;
      }

      // Локальное зеркало для отображения (id совпадает с облачной строкой).
      final bike = Bike(
        id: cloudId,
        name: name,
        weightKg: weight,
        type: _selectedTransport.bikeType,
        wheelSize: wheelSize,
        totalDistance: 0.0,
        isEbike: _isEbike,
      );
      await _repository.addBike(bike);
      _bikeNameController.clear();
      _bikeWeightController.clear();
      _bikeWheelSizeController.clear();
      setState(() => _isEbike = false);
      await _loadProfile();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('«$name» добавлен в гараж')));
    } on GarageServiceException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Не удалось сохранить транспорт: ${error.message}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// Ссылка на фото техники из кэша облачного гаража (по совпадению id).
  String? _photoUrlFor(String bikeId) {
    for (final vehicle in _garageService.vehicles) {
      if (vehicle.id == bikeId) return vehicle.photoUrl;
    }
    return null;
  }

  /// Выбор источника фото и загрузка его в бакет `vehicles`.
  Future<void> _changePhoto(Bike bike) async {
    if (_photoBusyBikeId != null) return;
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Фото техники',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Сделать фото'),
              onTap: () => Navigator.pop(sheetContext, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Из галереи'),
              onTap: () => Navigator.pop(sheetContext, 'gallery'),
            ),
            // «Убрать» доступно только когда фото уже есть.
            if (_photoUrlFor(bike.id) != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  'Убрать фото',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(sheetContext, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    // null в результате sheet — просьба убрать фото.
    if (source == 'camera' || source == 'gallery') {
      setState(() => _photoBusyBikeId = bike.id);
      try {
        final picker = ImagePicker();
        final picked = await picker.pickImage(
          source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1280,
          maxHeight: 1280,
          imageQuality: 85,
        );
        if (picked == null) return;
        await _garageService.uploadVehiclePhoto(picked.path, bike.id);
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Фото обновлено')));
      } on GarageServiceException catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      } finally {
        if (mounted) setState(() => _photoBusyBikeId = null);
      }
      await _loadProfile();
      return;
    }

    // Удаление фото
    setState(() => _photoBusyBikeId = bike.id);
    try {
      final removed = await _garageService.removeVehiclePhoto(bike.id);
      if (!removed && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось удалить фото. Повторите при подключении к сети.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _photoBusyBikeId = null);
    }
    await _loadProfile();
  }

  Future<void> _removeBike(Bike bike) async {
    if (_garageService.sessionVehicle?.id == bike.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Этот велосипед используется в текущем заезде. Сначала завершите тренировку.',
          ),
        ),
      );
      return;
    }
    // Удаление синхронизируется с облаком — случайный тап по корзине не
    // должен удалять технику без подтверждения.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить технику?'),
        content: Text('«${bike.name}» будет удалена из гаража.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Удаляем из облака (если строка там есть) и из локального профиля.
    if (!await _garageService.deleteVehicle(bike.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось удалить велосипед')),
        );
      }
      return;
    }
    await _repository.removeBike(bike);
    await _loadProfile();
  }

  Future<void> _selectBike(Bike bike) async {
    // `is_active` в `garage` — единый источник «основного» транспорта.
    if (!await _garageService.setActiveVehicle(bike.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось выбрать велосипед')),
        );
      }
      return;
    }
    await _repository.selectBike(bike);
    await _loadProfile();
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    // Пока профиль не загружен — только индикатор: обращаться к данным нельзя
    // (иначе LateInitializationError/null-ошибки при первом кадре).
    if (_isLoading || profile == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Мой гараж')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Мой гараж')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Гараж велосипедов',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildGarageList(profile),
            const SizedBox(height: 32),
            _buildAddBikeForm(),
          ],
        ),
      ),
    );
  }

  Widget _buildGarageList(UserProfile profile) {
    if (profile.garage.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Text('Гараж пуст. Добавьте велосипед.'),
      );
    }
    return Column(
      children: profile.garage.map((bike) {
        // Сравниваем по id: после перечитывания профиля из JSON выбранный
        // велосипед — уже другой экземпляр Bike с тем же id.
        final isSelected = profile.selectedBike?.id == bike.id;
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          color: isSelected ? Colors.deepOrange.shade50 : null,
          child: ListTile(
            onTap: () async {
              final vehicle = _garageService.vehicles
                  .where((v) => v.id == bike.id)
                  .firstOrNull;
              if (vehicle == null) return;
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VehicleDetailScreen(vehicle: vehicle),
                ),
              );
              if (mounted) await _loadProfile();
            },
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    bike.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (bike.isEbike)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.bolt, size: 16, color: Colors.deepOrange),
                  ),
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Основной',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Тип: ${bike.type.label}'),
                Text('Вес: ${bike.weightKg} кг, Колёса: ${bike.wheelSize}"'),
                Text('Пробег: ${bike.totalDistance.toStringAsFixed(1)} км'),
                if (_garageService.vehicles
                        .where((v) => v.id == bike.id)
                        .firstOrNull
                    case final vehicle?)
                  Text(
                    '${vehicle.recordedHours.toStringAsFixed(1)} ч · ${vehicle.isPublic ? 'Публичный велосипед' : 'Виден только вам'} · Проверить деталей: ${vehicle.parts.where((p) => p.due(vehicle.totalDistance, totalHours: vehicle.recordedHours)).length}',
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isSelected)
                  IconButton(
                    icon: const Icon(Icons.check_circle_outline),
                    onPressed: () => _selectBike(bike),
                    tooltip: 'Выбрать основным',
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removeBike(bike),
                  tooltip: 'Удалить',
                ),
              ],
            ),
            // Фото техники: загруженное из облака, иначе иконка типа.
            // Тап по фото — сменить/убрать.
            leading: GestureDetector(
              onTap: () => _changePhoto(bike),
              child: _photoBusyBikeId == bike.id
                  ? const SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _buildBikeAvatar(bike),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Аватар техники: фото из `vehicles`-бакета (если есть) с меткой камеры,
  /// иначе иконка типа транспорта.
  Widget _buildBikeAvatar(Bike bike) {
    final photoUrl = _photoUrlFor(bike.id);
    final hasPhoto =
        photoUrl != null &&
        (photoUrl.startsWith('http://') || photoUrl.startsWith('https://'));
    return Stack(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: Colors.deepOrange.shade50,
          backgroundImage: hasPhoto ? NetworkImage(photoUrl) : null,
          child: hasPhoto
              ? null
              : const Icon(
                  Icons.directions_bike,
                  color: Colors.deepOrange,
                  size: 24,
                ),
        ),
        // Метка-приглашение «нажми, чтобы поменять фото».
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: const BoxDecoration(
              color: Colors.deepOrange,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.photo_camera,
              size: 11,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAddBikeForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Добавить транспорт',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _bikeNameController,
          decoration: const InputDecoration(
            labelText: 'Название',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<TransportType>(
          initialValue: _selectedTransport,
          decoration: const InputDecoration(
            labelText: 'Тип транспорта',
            border: OutlineInputBorder(),
          ),
          items: TransportType.garageOptions
              .map(
                (type) =>
                    DropdownMenuItem(value: type, child: Text(type.label)),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _selectedTransport = value;
              });
            }
          },
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          value: _isEbike,
          onChanged: (value) => setState(() => _isEbike = value ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text('Электропривод (E-bike)'),
          subtitle: const Text(
            'Мотор забирает часть нагрузки — расход калорий считается вдвое меньше',
          ),
        ),
        const SizedBox(height: 12),
        if (_selectedTransport == TransportType.bicycle) ...[
          DropdownButtonFormField<ActivityType>(
            initialValue: _bikeActivity,
            decoration: const InputDecoration(labelText: 'Вид велосипеда'),
            items:
                [
                      ActivityType.mountainBiking,
                      ActivityType.roadCycling,
                      ActivityType.gravelRiding,
                      ActivityType.bikepacking,
                      ActivityType.cycling,
                    ]
                    .map(
                      (a) => DropdownMenuItem(value: a, child: Text(a.label)),
                    )
                    .toList(),
            onChanged: (a) {
              if (a != null) setState(() => _bikeActivity = a);
            },
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _bikeWeightController,
          decoration: const InputDecoration(
            labelText: 'Вес (кг) — необязательно',
            border: OutlineInputBorder(),
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _bikeWheelSizeController,
          decoration: const InputDecoration(
            labelText: 'Размер колёс (дюймы) — необязательно',
            border: OutlineInputBorder(),
            hintText: '29.0',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _adding ? null : _addBike,
          child: const Text('Добавить транспорт'),
        ),
      ],
    );
  }
}
