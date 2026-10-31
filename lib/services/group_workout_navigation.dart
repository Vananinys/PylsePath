import 'package:flutter/foundation.dart';

/// A one-shot request to the mounted map. It never starts or stops recording.
class GroupWorkoutNavigation extends ChangeNotifier {
  static final instance = GroupWorkoutNavigation();
  String? roomId, userId;
  void prepare({required String room, required String owner}) {
    roomId = room;
    userId = owner;
    notifyListeners();
  }

  void consume() {
    roomId = null;
    userId = null;
  }
}
