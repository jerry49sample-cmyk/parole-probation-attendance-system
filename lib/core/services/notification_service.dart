import 'dart:async';

import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/shared/models/notification_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

abstract class NotificationService {
  Stream<List<NotificationModel>> watchForUser(String userId);
  Future<List<NotificationModel>> getForUser(String userId);
  Future<void> markRead(String id);
  Future<void> send({
    required String userId,
    required String title,
    required String body,
    required NotificationType type,
  });
  Future<void> initializeMessaging();
}

class SupabaseNotificationService implements NotificationService {
  final SupabaseClient _db = SupabaseConfig.client;

  @override
  Stream<List<NotificationModel>> watchForUser(String userId) => _db
      .from('notifications')
      .stream(primaryKey: ['id'])
      .eq('user_id', userId)
      .map((rows) => rows.map(NotificationModel.fromMap).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));

  @override
  Future<List<NotificationModel>> getForUser(String userId) async {
    final rows = await _db
        .from('notifications')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false);
    return rows.map((row) => NotificationModel.fromMap(row)).toList();
  }

  @override
  Future<void> markRead(String id) async {
    await _db.from('notifications').update({'read': true}).eq('id', id);
  }

  @override
  Future<void> send({
    required String userId,
    required String title,
    required String body,
    required NotificationType type,
  }) async {
    if (userId.isEmpty) return;
    await _db.from('notifications').insert({
      'id': const Uuid().v4(),
      'user_id': userId,
      'title': title,
      'body': body,
      'type': type.name,
      'created_at': DateTime.now().toIso8601String(),
      'read': false,
    });
  }

  @override
  Future<void> initializeMessaging() async {
    // Push delivery needs an installed push provider. In-app notifications work
    // independently and are stored in the Supabase notifications table.
  }
}

class InMemoryNotificationService implements NotificationService {
  InMemoryNotificationService();

  static final InMemoryNotificationService instance = InMemoryNotificationService();
  final List<NotificationModel> _items = [];
  final _controller = StreamController<List<NotificationModel>>.broadcast();

  @override
  Stream<List<NotificationModel>> watchForUser(String userId) {
    Future.microtask(() => _emit());
    return _controller.stream.map((items) => items.where((n) => n.userId == userId).toList());
  }

  @override
  Future<List<NotificationModel>> getForUser(String userId) async =>
      _items.where((n) => n.userId == userId).toList();

  @override
  Future<void> markRead(String id) async {
    final index = _items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    _items[index] = _items[index].copyWith(read: true);
    _emit();
  }

  @override
  Future<void> send({
    required String userId,
    required String title,
    required String body,
    required NotificationType type,
  }) async {
    _items.insert(
      0,
      NotificationModel(
        id: const Uuid().v4(),
        userId: userId,
        title: title,
        body: body,
        type: type,
        createdAt: DateTime.now(),
      ),
    );
    _emit();
  }

  @override
  Future<void> initializeMessaging() async {}

  void _emit() => _controller.add(List.unmodifiable(_items));
}

NotificationService createNotificationService() => SupabaseNotificationService();
