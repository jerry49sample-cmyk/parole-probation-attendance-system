import { supabase } from '../utils/supabase';
import {
  ActivityModel,
  ActivityStatus,
  ActivityType,
  AppUser,
  AttendanceRecord,
  AttendanceStatus,
  Geofence,
  GpsTracker,
  NotificationItem,
  UserRole,
} from '../types';

type Row = Record<string, unknown>;

export interface OperationalSnapshot {
  users: AppUser[];
  trackers: GpsTracker[];
  geofences: Geofence[];
  activities: ActivityModel[];
  attendance: AttendanceRecord[];
  notifications: NotificationItem[];
}

function text(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : value == null ? fallback : String(value);
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.map((item) => String(item)) : [];
}

function parseRole(value: unknown): UserRole | null {
  const role = text(value).toLowerCase();
  return role === 'officer' || role === 'parolee' ? role : null;
}

function mapUser(row: Row): AppUser | null {
  const role = parseRole(row.role);
  if (!role) return null;

  return {
    id: text(row.id),
    email: text(row.email),
    fullName: text(row.full_name, text(row.email, 'User')),
    role,
    department: text(row.department) || undefined,
    caseNumber: text(row.case_number) || undefined,
    officerId: text(row.officer_id) || undefined,
    avatarInitials: text(row.avatar_initials) || undefined,
    phone: text(row.phone) || undefined,
    isActive: row.is_active === true,
    supervisionStartDate: text(row.supervision_start_date) || undefined,
    supervisionEndDate: text(row.supervision_end_date) || undefined,
    supervisionIsSuspended: row.supervision_is_suspended === true,
  };
}

function mapTracker(row: Row, users: AppUser[]): GpsTracker {
  const paroleeId = text(row.parolee_id) || undefined;
  const parolee = users.find((user) => user.id === paroleeId);
  const status = text(row.status, 'unassigned').toLowerCase() as GpsTracker['status'];

  return {
    id: text(row.id),
    deviceIdentifier: text(row.device_id, text(row.id)),
    deviceName: text(row.device_name) || undefined,
    deviceType: text(row.device_type) || undefined,
    serialNumber: text(row.serial_number) || undefined,
    paroleeId,
    paroleeName: text(row.parolee_name) || parolee?.fullName,
    status,
    batteryLevel: row.battery_level == null ? undefined : Number(row.battery_level),
    lastSeenAt: text(row.last_seen_at) || undefined,
    assignedAt: text(row.assigned_at) || undefined,
    createdAt: text(row.created_at) || undefined,
    updatedAt: text(row.updated_at) || undefined,
  };
}

function mapGeofence(row: Row): Geofence {
  return {
    id: text(row.id),
    paroleeId: text(row.parolee_id),
    name: text(row.name, 'Monitoring Area'),
    centerLat: Number(row.latitude),
    centerLng: Number(row.longitude),
    radiusMeters: Number(row.radius_meters),
    isActive: true,
  };
}

function mapActivity(
  row: Row,
  users: AppUser[],
  attendanceRows: Row[] = [],
): ActivityModel {
  const id = text(row.id);
  const assignedParoleeIds = stringList(row.assigned_parolee_ids);
  const completedParoleeIds = attendanceRows
    .filter((record) =>
      text(record.activity_id) === id &&
      ['present', 'late'].includes(text(record.status).toLowerCase())
    )
    .map((record) => text(record.parolee_id));
  const officerId = text(row.assigned_officer_id);
  const officer = users.find((user) => user.id === officerId);

  return {
    id,
    title: text(row.title),
    type: (text(row.activity_type, 'other') || 'other') as ActivityType,
    description: text(row.description),
    location: text(row.location_name),
    scheduleDate: text(row.start_time),
    assignedParoleeIds,
    assignedOfficerId: officerId,
    officerName: text(row.officer_name) || officer?.fullName,
    status: (text(row.status, 'pending') || 'pending') as ActivityStatus,
    createdAt: text(row.created_at) || text(row.start_time),
    completedParoleeIds,
  };
}

function mapAttendanceStatus(value: unknown): AttendanceStatus {
  switch (text(value).toLowerCase()) {
    case 'checkedin':
    case 'confirmed':
    case 'present':
    case 'late':
      return text(value).toLowerCase() === 'confirmed' ? 'confirmed' : 'checkedIn';
    case 'missed':
    case 'absent':
      return 'missed';
    default:
      return 'pending';
  }
}

function mapAttendance(row: Row, users: AppUser[], activity?: boolean): AttendanceRecord {
  const paroleeId = text(row.parolee_id);
  const user = users.find((item) => item.id === paroleeId);
  const activityId = text(row.activity_id) || undefined;
  const recordId = text(row.id);

  return {
    id: recordId,
    ticketId: text(row.ticket_id, `ACT-${recordId}`),
    paroleeId,
    paroleeName: text(row.parolee_name) || user?.fullName || 'Parolee',
    officerId: text(row.officer_id),
    status: mapAttendanceStatus(row.status),
    checkInTime: text(activity ? row.scanned_at : row.check_in_time) || undefined,
    scheduledTime: undefined,
    location: undefined,
    verified: activity ? row.verified_by_officer === true : row.verified === true,
    activityId,
    activityTitle: text(row.activity_title) || undefined,
  };
}

function mapNotification(row: Row): NotificationItem {
  const allowedTypes: NotificationItem['type'][] = [
    'proximity',
    'geofence',
    'battery',
    'activity',
    'checkin',
    'info',
  ];
  const rawType = text(row.type) as NotificationItem['type'];

  return {
    id: text(row.id),
    title: text(row.title),
    message: text(row.body),
    type: allowedTypes.includes(rawType) ? rawType : 'info',
    timestamp: text(row.created_at),
    isRead: row.read === true,
    paroleeId: text(row.parolee_id) || undefined,
  };
}

function throwIfError(error: { message: string } | null, operation: string): void {
  if (error) throw new Error(`${operation}: ${error.message}`);
}

export async function loadOperationalSnapshot(userId: string): Promise<OperationalSnapshot> {
  const [
    profilesResult,
    trackersResult,
    geofencesResult,
    activitiesResult,
    attendanceResult,
    activityAttendanceResult,
    notificationsResult,
  ] = await Promise.all([
    supabase
      .from('profiles')
      .select(
        'id,email,full_name,role,is_active,department,case_number,officer_id,avatar_initials,phone,supervision_start_date,supervision_end_date,supervision_is_suspended'
      ),
    supabase.from('gps_trackers').select('*'),
    supabase.from('geofences').select('*'),
    supabase.from('activities').select('*').order('start_time', { ascending: false }),
    supabase.from('attendance_records').select('*').order('check_in_time', { ascending: false }).limit(500),
    supabase
      .from('activity_attendance_records')
      .select('*')
      .order('scanned_at', { ascending: false })
      .limit(500),
    supabase
      .from('notifications')
      .select('*')
      .eq('user_id', userId)
      .eq('read', false)
      .order('created_at', { ascending: false })
      .limit(100),
  ]);

  throwIfError(profilesResult.error, 'Could not load account profiles');
  throwIfError(trackersResult.error, 'Could not load GPS trackers');
  throwIfError(geofencesResult.error, 'Could not load geofences');
  throwIfError(activitiesResult.error, 'Could not load activities');
  throwIfError(attendanceResult.error, 'Could not load attendance records');
  throwIfError(activityAttendanceResult.error, 'Could not load activity attendance');
  throwIfError(notificationsResult.error, 'Could not load notifications');

  const users = (profilesResult.data || [])
    .map((row) => mapUser(row as Row))
    .filter((user): user is AppUser => user !== null);
  const activityAttendanceRows = (activityAttendanceResult.data || []) as Row[];
  const trackers = ((trackersResult.data || []) as Row[]).map((row) => mapTracker(row, users));
  const usersWithTracker = users.map((user) => ({
    ...user,
    trackerId: trackers.find((tracker) => tracker.paroleeId === user.id)?.id,
  }));
  const activities = ((activitiesResult.data || []) as Row[]).map((row) =>
    mapActivity(row, usersWithTracker, activityAttendanceRows),
  );
  const attendance = [
    ...((attendanceResult.data || []) as Row[]).map((row) =>
      mapAttendance(row, usersWithTracker),
    ),
    ...activityAttendanceRows.map((row) =>
      mapAttendance(row, usersWithTracker, true),
    ),
  ].sort(
    (a, b) =>
      new Date(b.checkInTime || 0).getTime() - new Date(a.checkInTime || 0).getTime(),
  );

  return {
    users: usersWithTracker,
    trackers,
    geofences: ((geofencesResult.data || []) as Row[]).map(mapGeofence),
    activities,
    attendance,
    notifications: ((notificationsResult.data || []) as Row[]).map(mapNotification),
  };
}

export async function createActivityRecord(
  data: {
    title: string;
    type: ActivityType;
    description: string;
    location: string;
    scheduleDate: string;
    assignedParoleeIds: string[];
  },
  officer: AppUser,
): Promise<ActivityModel> {
  const start = new Date(data.scheduleDate);
  const { data: row, error } = await supabase
    .from('activities')
    .insert({
      title: data.title,
      description: data.description,
      activity_type: data.type,
      location_name: data.location,
      start_time: start.toISOString(),
      end_time: new Date(start.getTime() + 60 * 60 * 1000).toISOString(),
      assigned_officer_id: officer.id,
      assigned_parolee_ids: data.assignedParoleeIds,
      status: 'pending',
    })
    .select('*')
    .single();
  throwIfError(error, 'Could not create the activity');
  if (!row) throw new Error('Could not create the activity: Supabase returned no record.');
  return mapActivity(row as Row, [officer]);
}

export async function updateActivityRecordStatus(
  activityId: string,
  status: ActivityStatus,
): Promise<void> {
  const { error } = await supabase
    .from('activities')
    .update({ status })
    .eq('id', activityId);
  throwIfError(error, 'Could not update the activity status');
}

export async function createTrackerRecord(
  trackerId: string,
  deviceIdentifier: string,
): Promise<GpsTracker> {
  const { data, error } = await supabase
    .from('gps_trackers')
    .insert({
      id: trackerId,
      device_id: deviceIdentifier || `dev-${trackerId.toLowerCase()}`,
      device_name: `ESP32 Tracker ${trackerId}`,
      device_type: 'Wearable Ankle Tracker',
      serial_number: `SN-TAC-${Date.now().toString().slice(-6)}`,
      status: 'unassigned',
      battery_level: 100,
    })
    .select('*')
    .single();
  throwIfError(error, 'Could not create the GPS tracker');
  if (!data) throw new Error('Could not create the GPS tracker: Supabase returned no record.');
  return mapTracker(data as Row, []);
}

export async function assignTrackerRecord(trackerId: string, paroleeId: string): Promise<void> {
  const { error } = await supabase.rpc('ppa_assign_tracker', {
    p_tracker_id: trackerId,
    p_parolee_id: paroleeId,
  });
  throwIfError(error, 'Could not assign the GPS tracker');
}

export async function unassignTrackerRecord(trackerId: string): Promise<void> {
  const { error } = await supabase.rpc('ppa_unassign_tracker', {
    p_tracker_id: trackerId,
  });
  throwIfError(error, 'Could not unassign the GPS tracker');
}

export async function createGeofenceRecord(data: Omit<Geofence, 'id'>): Promise<Geofence> {
  const { data: row, error } = await supabase
    .from('geofences')
    .insert({
      parolee_id: data.paroleeId,
      name: data.name,
      latitude: data.centerLat,
      longitude: data.centerLng,
      radius_meters: data.radiusMeters,
    })
    .select('*')
    .single();
  throwIfError(error, 'Could not save the geofence');
  if (!row) throw new Error('Could not save the geofence: Supabase returned no record.');
  return mapGeofence(row as Row);
}

export async function issueActivityQrRecord(
  activityId: string,
  rotate: boolean,
): Promise<string> {
  const { data, error } = await supabase.rpc('ppa_issue_activity_qr', {
    p_activity_id: activityId,
    p_rotate: rotate,
  });
  throwIfError(error, 'Could not issue an activity QR ticket');
  const row = data as Row | null;
  const token = text(row?.token);
  const issuedActivityId = text(row?.activity_id);
  if (!token || issuedActivityId !== activityId) {
    throw new Error('Supabase returned an invalid activity QR ticket.');
  }
  return JSON.stringify({ t: token, a: issuedActivityId });
}

export async function recordActivityQr(
  payload: string,
  expectedActivityId: string,
  users: AppUser[],
): Promise<AttendanceRecord> {
  let parsed: Row;
  try {
    parsed = JSON.parse(payload) as Row;
  } catch {
    throw new Error('Invalid activity QR payload.');
  }

  const token = text(parsed.t, text(parsed.token));
  const activityId = text(parsed.a, text(parsed.activityId));
  if (!token || activityId !== expectedActivityId) {
    throw new Error('This QR code is not valid for the selected activity.');
  }

  const { data, error } = await supabase.rpc('ppa_record_activity_attendance', {
    p_token: token,
    p_activity_id: expectedActivityId,
    p_status: 'present',
  });
  throwIfError(error, 'Could not verify this activity QR code');
  if (!data || typeof data !== 'object') {
    throw new Error('Supabase returned an invalid attendance result.');
  }
  return mapAttendance(data as Row, users, true);
}

export async function markActivityAttendanceRecord(
  activityId: string,
  paroleeId: string,
  status: AttendanceStatus,
  users: AppUser[],
): Promise<AttendanceRecord> {
  const statusByAttendance: Record<AttendanceStatus, string> = {
    checkedIn: 'present',
    confirmed: 'present',
    missed: 'absent',
    pending: 'pending',
  };
  const rpcStatus = statusByAttendance[status];
  if (rpcStatus === 'pending') {
    throw new Error('Manual activity attendance must be marked present or absent.');
  }

  const { data, error } = await supabase.rpc('ppa_mark_activity_attendance', {
    p_activity_id: activityId,
    p_parolee_id: paroleeId,
    p_status: rpcStatus,
  });
  throwIfError(error, 'Could not save manual activity attendance');
  if (!data || typeof data !== 'object') {
    throw new Error('Supabase returned an invalid attendance result.');
  }
  return mapAttendance(data as Row, users, true);
}

export async function markNotificationReadRecord(id: string, userId: string): Promise<void> {
  const { error } = await supabase
    .from('notifications')
    .update({ read: true })
    .eq('id', id)
    .eq('user_id', userId);
  throwIfError(error, 'Could not mark the notification as read');
}

export async function clearNotificationRecords(userId: string): Promise<void> {
  const { error } = await supabase
    .from('notifications')
    .update({ read: true })
    .eq('user_id', userId)
    .eq('read', false);
  throwIfError(error, 'Could not clear notifications');
}
