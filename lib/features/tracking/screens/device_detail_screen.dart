import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:last/core/theme/app_colors.dart';
import 'package:last/core/widgets/empty_state.dart';
import 'package:last/core/widgets/loading_shimmer.dart';
import 'package:last/features/admin/providers/admin_provider.dart';
import 'package:last/features/tracking/models/gps_tracker.dart';
import 'package:last/features/tracking/models/location_record.dart';
import 'package:last/features/tracking/services/tracker_admin_service.dart';
import 'package:last/features/tracking/providers/tracking_provider.dart';
import 'package:last/features/tracking/widgets/battery_indicator.dart';
import 'package:last/features/tracking/widgets/check_in_proximity_badge.dart';
import 'package:last/features/tracking/widgets/device_status_card.dart';
import 'package:last/features/tracking/widgets/last_updated_widget.dart';

/// Officer screen: device details, status management, assignment, location logs.
class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({super.key, required this.trackerId});

  final String trackerId;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  final _adminService = createTrackerAdminService();

  GpsTracker? _tracker;
  List<LocationRecord> _logs = [];
  bool _loading = true;
  bool _refreshInProgress = false;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _load(showLoading: false);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (_refreshInProgress) return;
    _refreshInProgress = true;
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final tracker = await _adminService.getTrackerById(widget.trackerId);
      final logs = await _adminService.getDeviceLocationLogs(widget.trackerId);
      if (mounted) {
        setState(() {
          _tracker = tracker;
          _logs = logs;
          _error = null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          if (showLoading || _tracker == null) {
            _error = 'Failed to load device';
          }
          _loading = false;
        });
      }
    } finally {
      _refreshInProgress = false;
    }
  }

  Future<void> _setStatus(TrackerDeviceStatus status) async {
    await _adminService.updateTrackerStatus(widget.trackerId, status);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Status updated to ${status.label}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<AdminProvider>();
    final tracking = context.watch<TrackingProvider>();
    final tracker = _tracker;
    final proximity = tracking
        .summaryForTracker(widget.trackerId)
        ?.checkInProximity;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(tracker?.deviceId ?? 'Device Details'),
        backgroundColor: AppColors.reports,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const LoadingShimmer()
          : _error != null
          ? EmptyState(
              icon: Icons.error_outline,
              title: _error!,
              actionLabel: 'Retry',
              onAction: () => _load(),
            )
          : tracker == null
          ? const EmptyState(icon: Icons.gps_off, title: 'Device not found')
          : RefreshIndicator(
              onRefresh: () => _load(),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  DeviceStatusCard(tracker: tracker, showAdminDetails: true),
                  const SizedBox(height: 12),
                  if (proximity != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'CHECK-IN PROXIMITY',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 10),
                            CheckInProximityBadge(result: proximity),
                            if (proximity.locationName != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                proximity.locationName!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            const Text(
                              'GPS proximity does not prove who is carrying the device.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ACTIONS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (!tracker.isAssigned ||
                                  tracker.hasHiddenAssignment)
                                FilledButton.icon(
                                  onPressed: () =>
                                      _showAssignDialog(admin.parolees),
                                  icon: const Icon(Icons.link, size: 18),
                                  label: Text(
                                    tracker.hasHiddenAssignment
                                        ? 'Transfer'
                                        : 'Assign',
                                  ),
                                ),
                              if (tracker.isAssigned &&
                                  !tracker.hasHiddenAssignment)
                                OutlinedButton.icon(
                                  onPressed: () => _adminService
                                      .unassignTracker(widget.trackerId),
                                  icon: const Icon(Icons.link_off, size: 18),
                                  label: const Text('Unassign'),
                                ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _setStatus(TrackerDeviceStatus.maintenance),
                                icon: const Icon(Icons.build, size: 18),
                                label: const Text('Maintenance'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _setStatus(TrackerDeviceStatus.inactive),
                                icon: const Icon(Icons.block, size: 18),
                                label: const Text('Deactivate'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'LOCATION LOGS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (_logs.isEmpty)
                            const Text(
                              'No location records yet.',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textMuted,
                              ),
                            )
                          else
                            ..._logs
                                .take(20)
                                .map(
                                  (r) => ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      '${r.latitude.toStringAsFixed(5)}, ${r.longitude.toStringAsFixed(5)}',
                                    ),
                                    subtitle: LastUpdatedWidget(
                                      timestamp: r.recordedAt,
                                    ),
                                    trailing: r.batteryLevel != null
                                        ? BatteryIndicator(
                                            level: r.batteryLevel,
                                            compact: true,
                                          )
                                        : null,
                                  ),
                                ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _showAssignDialog(List<dynamic> parolees) async {
    final selected = await showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Assign Device'),
        children: parolees
            .map<Widget>(
              (p) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, p),
                child: Text(p.fullName),
              ),
            )
            .toList(),
      ),
    );
    if (selected != null) {
      await _adminService.assignTracker(
        trackerId: widget.trackerId,
        paroleeId: selected.id,
      );
      await _load();
    }
  }
}
