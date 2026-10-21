import React, { createContext, useContext, useState, useEffect, useMemo, useCallback, useRef } from 'react';
import {
  AppUser,
  UserRole,
  GpsTracker,
  Geofence,
  ActivityModel,
  AttendanceRecord,
  NotificationItem,
  LocationRecord,
  DashboardStats,
  ParoleeTrackingSummary,
  AttendanceStatus,
  ActivityType,
  ActivityStatus,
  GeofenceStatus,
  CheckInProximity,
} from '../types';
import {
  APP_CONFIG,
  DEMO_CREDENTIALS,
  INITIAL_USERS,
  INITIAL_TRACKERS,
  INITIAL_GEOFENCES,
  INITIAL_ACTIVITIES,
  INITIAL_ATTENDANCE,
  INITIAL_NOTIFICATIONS,
  calculateDistanceMeters,
} from '../constants';
import { supabase, isSupabaseConfigured } from '../utils/supabase';
import {
  assignTrackerRecord,
  clearNotificationRecords,
  createActivityRecord,
  createGeofenceRecord,
  createTrackerRecord,
  issueActivityQrRecord,
  loadOperationalSnapshot,
  markActivityAttendanceRecord,
  markNotificationReadRecord,
  recordActivityQr,
  unassignTrackerRecord,
  updateActivityRecordStatus,
} from '../services/supabaseOperationalData';

interface AppContextType {
  currentUser: AppUser | null;
  isAuthLoading: boolean;
  authNotice: string | null;
  canQuickSwitchRole: boolean;
  users: AppUser[];
  trackers: GpsTracker[];
  geofences: Geofence[];
  activities: ActivityModel[];
  attendance: AttendanceRecord[];
  notifications: NotificationItem[];
  liveLocations: Record<string, LocationRecord>;
  locationHistories: Record<string, LocationRecord[]>;
  stats: DashboardStats;
  isSimulating: boolean;
  isSupabaseLive: boolean;
  dataError: string | null;
  dismissDataError: () => void;
  setIsSimulating: (v: boolean) => void;
  // Auth
  login: (email: string, pass: string, role: UserRole) => Promise<boolean>;
  logout: () => void;
  quickSwitchRole: (role: UserRole) => void;
  signUp: (email: string, pass: string, fullName: string, role: UserRole) => Promise<{ needEmailConfirmation: boolean; message: string }>;
  // Admin & User actions
  toggleUserActive: (userId: string, isActive: boolean) => void;
  deleteUser: (userId: string) => boolean;
  assignOfficer: (paroleeId: string, officerId: string) => void;
  removeOfficer: (paroleeId: string) => void;
  // Tracker actions
  assignTracker: (trackerId: string, paroleeId: string) => Promise<void>;
  unassignTracker: (trackerId: string) => Promise<void>;
  createTracker: (trackerId: string, deviceIdentifier: string) => Promise<boolean>;
  assignGeofence: (data: Omit<Geofence, 'id'>) => Promise<boolean>;
  // Activity actions
  createActivity: (data: {
    title: string;
    type: ActivityType;
    description: string;
    location: string;
    scheduleDate: string;
    assignedParoleeIds: string[];
  }) => Promise<boolean>;
  updateActivityStatus: (activityId: string, status: ActivityStatus) => Promise<void>;
  // Attendance actions
  issueActivityQr: (activityId: string, rotate?: boolean) => Promise<string>;
  verifyAttendanceByQr: (payloadString: string, expectedActivityId?: string) => Promise<{ success: boolean; message: string; record?: AttendanceRecord }>;
  markAttendanceManual: (activityId: string, paroleeId: string, status: AttendanceStatus) => Promise<void>;
  submitParoleeSelfCheckIn: (activityId: string) => Promise<AttendanceRecord>;
  // GPS & Live Tracking
  shareParoleeLocation: (paroleeId: string, lat: number, lng: number) => void;
  getParoleeSummary: (paroleeId: string) => ParoleeTrackingSummary | null;
  // Notifications
  markNotificationRead: (id: string) => Promise<void>;
  clearNotifications: () => Promise<void>;
}

const AppContext = createContext<AppContextType | null>(null);

function isDemoUser(user: AppUser | null): boolean {
  return Boolean(user && INITIAL_USERS.some((demoUser) => demoUser.id === user.id && demoUser.email === user.email));
}

function getPersistedDemoUser(): AppUser | null {
  try {
    const saved = localStorage.getItem('ppa_tac_user');
    if (!saved) return null;

    const parsed = JSON.parse(saved) as Partial<AppUser>;
    return INITIAL_USERS.find((user) => user.id === parsed.id && user.email === parsed.email) || null;
  } catch {
    return null;
  }
}

async function loadAuthenticatedProfile(authUser: { id: string; email?: string | null }): Promise<AppUser> {
  const { data, error } = await supabase
    .from('profiles')
    .select(
      'id, email, full_name, role, is_active, department, case_number, officer_id, avatar_initials, phone, supervision_start_date, supervision_end_date, supervision_is_suspended'
    )
    .eq('id', authUser.id)
    .maybeSingle();

  if (error) {
    throw new Error(`Could not verify your account profile: ${error.message}`);
  }
  if (!data) {
    throw new Error('No account profile was found. Please contact an administrator.');
  }

  const profile = data as {
    id: string;
    email: string | null;
    full_name: string | null;
    role: string | null;
    is_active: boolean | null;
    department: string | null;
    case_number: string | null;
    officer_id: string | null;
    avatar_initials: string | null;
    phone: string | null;
    supervision_start_date: string | null;
    supervision_end_date: string | null;
    supervision_is_suspended: boolean | null;
  };
  const role = profile.role?.toLowerCase();

  if (profile.is_active !== true) {
    throw new Error('This account is inactive. Please contact an administrator.');
  }
  if (role !== 'officer' && role !== 'parolee') {
    throw new Error('This account has an unsupported role. Please contact an administrator.');
  }

  return {
    id: profile.id,
    email: profile.email || authUser.email || '',
    fullName: profile.full_name || profile.email || authUser.email || 'User',
    role,
    isActive: profile.is_active,
    department: profile.department || undefined,
    caseNumber: profile.case_number || undefined,
    officerId: profile.officer_id || undefined,
    avatarInitials: profile.avatar_initials || undefined,
    phone: profile.phone || undefined,
    supervisionStartDate: profile.supervision_start_date || undefined,
    supervisionEndDate: profile.supervision_end_date || undefined,
    supervisionIsSuspended: profile.supervision_is_suspended ?? undefined,
  };
}

function readDemoState<T>(key: string, fallback: T): T {
  try {
    const saved = localStorage.getItem(key);
    return saved ? (JSON.parse(saved) as T) : fallback;
  } catch {
    return fallback;
  }
}

export const AppProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [isAuthLoading, setIsAuthLoading] = useState<boolean>(isSupabaseConfigured);
  const [authNotice, setAuthNotice] = useState<string | null>(null);
  const [dataError, setDataError] = useState<string | null>(null);

  // Only restore canonical local demo users from browser storage. Real accounts
  // are restored from their Supabase session and verified against profiles.
  const [currentUser, setCurrentUser] = useState<AppUser | null>(() => {
    return getPersistedDemoUser();
  });

  const [users, setUsers] = useState<AppUser[]>(() => readDemoState('ppa_tac_users', INITIAL_USERS));
  const [trackers, setTrackers] = useState<GpsTracker[]>(() => readDemoState('ppa_tac_trackers', INITIAL_TRACKERS));
  const [geofences, setGeofences] = useState<Geofence[]>(() => readDemoState('ppa_tac_geofences', INITIAL_GEOFENCES));
  const [activities, setActivities] = useState<ActivityModel[]>(() => readDemoState('ppa_tac_activities', INITIAL_ACTIVITIES));
  const [attendance, setAttendance] = useState<AttendanceRecord[]>(() =>
    readDemoState('ppa_tac_attendance', INITIAL_ATTENDANCE),
  );
  const [notifications, setNotifications] = useState<NotificationItem[]>(() =>
    readDemoState('ppa_tac_notifications', INITIAL_NOTIFICATIONS),
  );

  const [isSimulating, setIsSimulating] = useState<boolean>(false);
  const [isSupabaseLive, setIsSupabaseLive] = useState<boolean>(false);
  const [tick, setTick] = useState<number>(0);
  const proximityStateRef = useRef<Record<string, boolean>>({});

  const applyOperationalSnapshot = (snapshot: Awaited<ReturnType<typeof loadOperationalSnapshot>>) => {
    setUsers(snapshot.users);
    setTrackers(snapshot.trackers);
    setGeofences(snapshot.geofences);
    setActivities(snapshot.activities);
    setAttendance(snapshot.attendance);
    setNotifications(snapshot.notifications);
  };

  const restoreDemoSnapshot = () => {
    setUsers(readDemoState('ppa_tac_users', INITIAL_USERS));
    setTrackers(readDemoState('ppa_tac_trackers', INITIAL_TRACKERS));
    setGeofences(readDemoState('ppa_tac_geofences', INITIAL_GEOFENCES));
    setActivities(readDemoState('ppa_tac_activities', INITIAL_ACTIVITIES));
    setAttendance(readDemoState('ppa_tac_attendance', INITIAL_ATTENDANCE));
    setNotifications(readDemoState('ppa_tac_notifications', INITIAL_NOTIFICATIONS));
    setDataError(null);
    setIsSupabaseLive(false);
  };

  const reportDataError = (error: unknown, fallback: string) => {
    setDataError(error instanceof Error ? error.message : fallback);
    setIsSupabaseLive(false);
  };

  useEffect(() => {
    if (!isSupabaseConfigured) {
      setIsAuthLoading(false);
      return;
    }

    let mounted = true;
    let sessionRevision = 0;

    const syncSessionUser = async (authUser: { id: string; email?: string | null } | null) => {
      const revision = ++sessionRevision;

      if (!authUser) {
        setCurrentUser((previous) => (isDemoUser(previous) ? previous : null));
        setIsAuthLoading(false);
        return;
      }

      try {
        const profileUser = await loadAuthenticatedProfile(authUser);
        if (!mounted || revision !== sessionRevision) return;

        try {
          const snapshot = await loadOperationalSnapshot(profileUser.id);
          if (!mounted || revision !== sessionRevision) return;
          applyOperationalSnapshot(snapshot);
          setDataError(null);
          setIsSupabaseLive(true);
        } catch (error) {
          if (!mounted || revision !== sessionRevision) return;
          setUsers([]);
          setTrackers([]);
          setGeofences([]);
          setActivities([]);
          setAttendance([]);
          setNotifications([]);
          reportDataError(error, 'Could not load operational data from Supabase.');
        }

        if (!mounted || revision !== sessionRevision) return;
        setCurrentUser(profileUser);
        setAuthNotice(null);
      } catch (error) {
        if (!mounted || revision !== sessionRevision) return;

        setCurrentUser(null);
        setAuthNotice(error instanceof Error ? error.message : 'Could not verify your account profile.');
        void supabase.auth.signOut({ scope: 'local' });
      } finally {
        if (mounted && revision === sessionRevision) {
          setIsAuthLoading(false);
        }
      }
    };

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, session) => {
      // Defer Supabase calls until after its auth callback completes.
      window.setTimeout(() => {
        if (!mounted) return;

        if (event === 'SIGNED_OUT') {
          sessionRevision += 1;
          setCurrentUser((previous) => (isDemoUser(previous) ? previous : null));
          setIsAuthLoading(false);
          return;
        }

        if (event === 'INITIAL_SESSION' || event === 'SIGNED_IN' || event === 'USER_UPDATED') {
          setIsAuthLoading(true);
        }

        if (session?.user) {
          void syncSessionUser(session.user);
        } else if (event === 'INITIAL_SESSION') {
          void syncSessionUser(null);
        }
      }, 0);
    });

    return () => {
      mounted = false;
      subscription.unsubscribe();
    };
  }, []);

  // Initial positions around Tacloban City
  const [liveLocations, setLiveLocations] = useState<Record<string, LocationRecord>>(() => {
    const now = new Date().toISOString();
    return {
      'demo-parolee': {
        id: 'loc-init-1',
        trackerId: 'TRK-001',
        paroleeId: 'demo-parolee',
        latitude: APP_CONFIG.taclobanLat + 0.00015,
        longitude: APP_CONFIG.taclobanLng + 0.00015,
        accuracy: 4.8,
        speed: 2.1,
        heading: 45,
        batteryLevel: 84,
        recordedAt: now,
        source: 'simulated',
      },
      'demo-parolee-2': {
        id: 'loc-init-2',
        trackerId: 'TRK-002',
        paroleeId: 'demo-parolee-2',
        latitude: 11.2360,
        longitude: 125.0110,
        accuracy: 12.0,
        speed: 0.0,
        batteryLevel: 14,
        recordedAt: new Date(Date.now() - 35 * 60 * 1000).toISOString(),
        source: 'esp32',
      },
      'demo-parolee-3': {
        id: 'loc-init-3',
        trackerId: 'TRK-003',
        paroleeId: 'demo-parolee-3',
        latitude: APP_CONFIG.taclobanLat - 0.00025,
        longitude: APP_CONFIG.taclobanLng + 0.00020,
        accuracy: 5.2,
        speed: 3.4,
        heading: 180,
        batteryLevel: 68,
        recordedAt: now,
        source: 'simulated',
      },
    };
  });

  const [locationHistories, setLocationHistories] = useState<Record<string, LocationRecord[]>>(() => {
    const now = Date.now();
    const generateHistory = (paroleeId: string, trackerId: string, centerLat: number, centerLng: number) => {
      const records: LocationRecord[] = [];
      for (let i = 12; i >= 0; i--) {
        const angle = i * 0.5;
        records.push({
          id: `hist-${paroleeId}-${i}`,
          trackerId,
          paroleeId,
          latitude: centerLat + Math.sin(angle) * 0.0004,
          longitude: centerLng + Math.cos(angle) * 0.0004,
          accuracy: 5.0,
          speed: 1.5 + (i % 3),
          batteryLevel: 80 - Math.floor(i / 2),
          recordedAt: new Date(now - i * 5 * 60 * 1000).toISOString(),
          source: 'simulated',
        });
      }
      return records;
    };

    return {
      'demo-parolee': generateHistory('demo-parolee', 'TRK-001', APP_CONFIG.taclobanLat, APP_CONFIG.taclobanLng),
      'demo-parolee-2': generateHistory('demo-parolee-2', 'TRK-002', 11.2360, 125.0110),
      'demo-parolee-3': generateHistory('demo-parolee-3', 'TRK-003', APP_CONFIG.taclobanLat, APP_CONFIG.taclobanLng),
    };
  });

  // Supabase Real-Time Location Listener & Initial Log Fetch
  useEffect(() => {
    if (!isSupabaseConfigured) return;

    // 1. Fetch latest location logs recorded by ESP32 firmware
    void supabase
      .from('location_logs')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(50)
      .then(({ data, error }) => {
        if (!error && data && data.length > 0) {
          setIsSupabaseLive(true);
          const latest = data[0];
          const targetParoleeId = (latest as any).parolee_id || 'demo-parolee';

          const mappedLatest: LocationRecord = {
            id: `sb-${latest.id || Date.now()}`,
            trackerId: (latest as any).tracker_id || 'TRK-001',
            paroleeId: targetParoleeId,
            latitude: Number(latest.latitude),
            longitude: Number(latest.longitude),
            accuracy: Number((latest as any).accuracy || 4.2),
            speed: Number((latest as any).speed || 0),
            batteryLevel: (latest as any).battery_level ? Number((latest as any).battery_level) : undefined,
            recordedAt: (latest as any).created_at || new Date().toISOString(),
            source: 'esp32',
          };

          setLiveLocations((prev) => ({ ...prev, [targetParoleeId]: mappedLatest }));
          setLocationHistories((prev) => ({
            ...prev,
            [targetParoleeId]: data.map((d: any) => ({
              id: `sb-${d.id || Math.random()}`,
              trackerId: d.tracker_id || 'TRK-001',
              paroleeId: d.parolee_id || targetParoleeId,
              latitude: Number(d.latitude),
              longitude: Number(d.longitude),
              accuracy: Number(d.accuracy || 4.5),
              speed: Number(d.speed || 0),
              batteryLevel: d.battery_level ? Number(d.battery_level) : undefined,
              recordedAt: d.created_at || new Date().toISOString(),
              source: 'esp32',
            })),
          }));
        }
      });

    // 2. Real-time Subscription to location_logs from ESP32
    const channel = supabase
      .channel('public:location_logs')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'location_logs' },
        (payload) => {
          const row: any = payload.new;
          if (!row) return;

          setIsSupabaseLive(true);
          const pId = row.parolee_id || 'demo-parolee';
          const newLoc: LocationRecord = {
            id: `sb-realtime-${row.id || Date.now()}`,
            trackerId: row.tracker_id || 'TRK-001',
            paroleeId: pId,
            latitude: Number(row.latitude),
            longitude: Number(row.longitude),
            accuracy: Number(row.accuracy || 4.5),
            speed: Number(row.speed || 0),
            batteryLevel: row.battery_level ? Number(row.battery_level) : undefined,
            recordedAt: row.created_at || new Date().toISOString(),
            source: 'esp32',
          };

          setLiveLocations((prev) => ({ ...prev, [pId]: newLoc }));
          setLocationHistories((prev) => ({
            ...prev,
            [pId]: [newLoc, ...(prev[pId] || [])].slice(0, 50),
          }));

          // Notify officer if real reading crosses 50m check-in radius
          const dist = calculateDistanceMeters(
            Number(row.latitude),
            Number(row.longitude),
            APP_CONFIG.taclobanLat,
            APP_CONFIG.taclobanLng
          );
          if (dist <= APP_CONFIG.proximityRadiusMeters) {
            setNotifications((prev) => [
              {
                id: `notif-sb-prox-${Date.now()}`,
                title: 'Live Hardware Proximity Ping',
                message: `Hardware Beacon reported within ${dist}m of PPA Tacloban Check-in Office.`,
                type: 'proximity',
                timestamp: new Date().toISOString(),
                isRead: false,
                paroleeId: pId,
              },
              ...prev.slice(0, 20),
            ]);
          }
        }
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, []);

  // Sync state to localStorage
  useEffect(() => {
    if (currentUser) {
      localStorage.setItem('ppa_tac_user', JSON.stringify(currentUser));
    } else {
      localStorage.removeItem('ppa_tac_user');
    }
  }, [currentUser]);

  useEffect(() => {
    if (!currentUser || !isDemoUser(currentUser)) return;
    localStorage.setItem('ppa_tac_users', JSON.stringify(users));
  }, [currentUser, users]);

  useEffect(() => {
    if (!currentUser || !isDemoUser(currentUser)) return;
    localStorage.setItem('ppa_tac_trackers', JSON.stringify(trackers));
  }, [currentUser, trackers]);

  useEffect(() => {
    if (!currentUser || !isDemoUser(currentUser)) return;
    localStorage.setItem('ppa_tac_geofences', JSON.stringify(geofences));
  }, [currentUser, geofences]);

  useEffect(() => {
    if (!currentUser || !isDemoUser(currentUser)) return;
    localStorage.setItem('ppa_tac_activities', JSON.stringify(activities));
  }, [currentUser, activities]);

  useEffect(() => {
    if (!currentUser || !isDemoUser(currentUser)) return;
    localStorage.setItem('ppa_tac_attendance', JSON.stringify(attendance));
  }, [currentUser, attendance]);

  useEffect(() => {
    if (!currentUser || !isDemoUser(currentUser)) return;
    localStorage.setItem('ppa_tac_notifications', JSON.stringify(notifications));
  }, [currentUser, notifications]);

  // Background GPS simulation loop (when live ESP32 is idle or offline)
  useEffect(() => {
    if (!isSimulating) return;

    const interval = setInterval(() => {
      setTick((prev) => prev + 1);

      setLiveLocations((prev) => {
        const next = { ...prev };
        const now = new Date().toISOString();
        const t = tick + 1;

        // Juan Dela Cruz (demo-parolee) orbits close to the 50m check-in radius
        const angle1 = t * 0.25;
        const orbit1 = 0.00042 + Math.sin(t * 0.1) * 0.0001;
        const lat1 = APP_CONFIG.taclobanLat + Math.sin(angle1) * orbit1;
        const lng1 = APP_CONFIG.taclobanLng + Math.cos(angle1) * orbit1;

        const juanRecord: LocationRecord = {
          id: `loc-juan-${t}`,
          trackerId: 'TRK-001',
          paroleeId: 'demo-parolee',
          latitude: Number(lat1.toFixed(6)),
          longitude: Number(lng1.toFixed(6)),
          accuracy: Number((4.0 + Math.sin(t) * 1.5).toFixed(1)),
          speed: Number((2.5 + Math.cos(t) * 1.2).toFixed(1)),
          heading: Math.floor((angle1 * 180) / Math.PI) % 360,
          batteryLevel: Math.max(15, 84 - Math.floor(t / 20)),
          recordedAt: now,
          source: 'simulated',
        };
        next['demo-parolee'] = juanRecord;

        // Elena Garcia (demo-parolee-3)
        const angle3 = t * 0.2 + 2.1;
        const orbit3 = 0.00035;
        const lat3 = APP_CONFIG.taclobanLat + Math.sin(angle3) * orbit3;
        const lng3 = APP_CONFIG.taclobanLng + Math.cos(angle3) * orbit3;

        const elenaRecord: LocationRecord = {
          id: `loc-elena-${t}`,
          trackerId: 'TRK-003',
          paroleeId: 'demo-parolee-3',
          latitude: Number(lat3.toFixed(6)),
          longitude: Number(lng3.toFixed(6)),
          accuracy: 5.1,
          speed: 1.8,
          heading: Math.floor((angle3 * 180) / Math.PI) % 360,
          batteryLevel: 68,
          recordedAt: now,
          source: 'simulated',
        };
        next['demo-parolee-3'] = elenaRecord;

        // Append to history
        setLocationHistories((h) => {
          const newHist = { ...h };
          newHist['demo-parolee'] = [juanRecord, ...(newHist['demo-parolee'] || [])].slice(0, 50);
          newHist['demo-parolee-3'] = [elenaRecord, ...(newHist['demo-parolee-3'] || [])].slice(0, 50);
          return newHist;
        });

        // Trigger proximity alert if crossed
        const dist = calculateDistanceMeters(lat1, lng1, APP_CONFIG.taclobanLat, APP_CONFIG.taclobanLng);
        if (dist <= APP_CONFIG.proximityRadiusMeters && t % 12 === 0) {
          setNotifications((notifs) => [
            {
              id: `notif-prox-${Date.now()}`,
              title: 'Check-in Proximity Alert',
              message: `Parolee Juan Dela Cruz is within ${dist} meters of PPA Tacloban Office.`,
              type: 'proximity',
              timestamp: now,
              isRead: false,
              paroleeId: 'demo-parolee',
            },
            ...notifs.slice(0, 20),
          ]);
        }

        return next;
      });
    }, 4000);

    return () => clearInterval(interval);
  }, [isSimulating, tick]);

  // Auth Methods
  const login = async (email: string, pass: string, role: UserRole): Promise<boolean> => {
    const normalized = email.trim().toLowerCase();
    setAuthNotice(null);

    const demoUser = INITIAL_USERS.find((user) => user.email.toLowerCase() === normalized);
    if (demoUser && (pass === DEMO_CREDENTIALS.password || pass === 'password')) {
      if (demoUser.role !== role) {
        throw new Error(`Role mismatch. Please select the '${demoUser.role}' role tab.`);
      }

      if (isSupabaseConfigured) {
        const { error } = await supabase.auth.signOut({ scope: 'local' });
        if (error) {
          throw new Error(`Could not end the previous account session: ${error.message}`);
        }
      }

      setCurrentUser(demoUser);
      restoreDemoSnapshot();
      return true;
    }

    if (!isSupabaseConfigured) {
      throw new Error('Invalid demo email or password. Use the demo credentials shown on the sign-in screen.');
    }

    const { data, error } = await supabase.auth.signInWithPassword({
      email: normalized,
      password: pass,
    });

    if (error) {
      if (error.message.toLowerCase().includes('email not confirmed')) {
        throw new Error(
          'Your email is not confirmed yet. Please check your inbox for the Brevo confirmation link before signing in.'
        );
      }
      throw new Error(error.message);
    }
    if (!data.user) {
      throw new Error('Supabase did not return an authenticated account.');
    }

    let profileUser: AppUser;
    try {
      profileUser = await loadAuthenticatedProfile(data.user);
    } catch (profileError) {
      await supabase.auth.signOut({ scope: 'local' });
      throw profileError;
    }

    try {
      const snapshot = await loadOperationalSnapshot(profileUser.id);
      applyOperationalSnapshot(snapshot);
      setDataError(null);
      setIsSupabaseLive(true);
    } catch (error) {
      setUsers([]);
      setTrackers([]);
      setGeofences([]);
      setActivities([]);
      setAttendance([]);
      setNotifications([]);
      reportDataError(error, 'Could not load operational data from Supabase.');
    }

    if (profileUser.role !== role) {
      await supabase.auth.signOut({ scope: 'local' });
      throw new Error(`Role mismatch. Please select the '${profileUser.role}' role tab.`);
    }

    setIsSupabaseLive(true);
    setUsers((previous) => {
      const existingIndex = previous.findIndex((user) => user.id === profileUser.id);
      if (existingIndex < 0) return [...previous, profileUser];
      const next = [...previous];
      next[existingIndex] = profileUser;
      return next;
    });
    setCurrentUser(profileUser);
    return true;
  };

  const signUp = async (
    email: string,
    pass: string,
    fullName: string,
    role: UserRole
  ): Promise<{ needEmailConfirmation: boolean; message: string }> => {
    const normalized = email.trim().toLowerCase();

    if (!isSupabaseConfigured) {
      throw new Error('Supabase client is not configured.');
    }

    const { data, error } = await supabase.auth.signUp({
      email: normalized,
      password: pass,
      options: {
        data: {
          full_name: fullName,
          role,
        },
      },
    });

    if (error) {
      throw new Error(error.message);
    }

    const needConfirmation = !data.session;
    return {
      needEmailConfirmation: needConfirmation,
      message: needConfirmation
        ? `Confirmation email sent via Brevo SMTP to ${normalized}. Please check your inbox (and spam folder) to verify before logging in.`
        : 'Account created successfully! You can now sign in.',
    };
  };

  const logout = () => {
    const signingOutSupabaseUser = currentUser !== null && !isDemoUser(currentUser);
    setCurrentUser(null);
    setAuthNotice(null);
    if (signingOutSupabaseUser && isSupabaseConfigured) {
      void supabase.auth.signOut({ scope: 'local' });
    }
  };

  const quickSwitchRole = (role: UserRole) => {
    if (!isDemoUser(currentUser)) return;
    const target = INITIAL_USERS.find((user) => user.role === role);
    if (target) {
      restoreDemoSnapshot();
      setCurrentUser(target);
    }
  };

  // User Actions
  const toggleUserActive = (userId: string, isActive: boolean) => {
    if (currentUser && !isDemoUser(currentUser)) {
      reportDataError(new Error('Account activation changes require an administrator and were not saved.'), '');
      return;
    }
    if (currentUser?.id === userId && !isDemoUser(currentUser)) return;
    setUsers((prev) => prev.map((u) => (u.id === userId ? { ...u, isActive } : u)));
    if (currentUser?.id === userId) {
      setCurrentUser((prev) => (prev ? { ...prev, isActive } : null));
    }
  };

  const deleteUser = (userId: string): boolean => {
    if (currentUser && !isDemoUser(currentUser)) {
      reportDataError(new Error('Deleting accounts requires an administrator and was not saved.'), '');
      return false;
    }
    if (currentUser?.id === userId) return false;
    setUsers((prev) => prev.filter((u) => u.id !== userId));
    setTrackers((prev) =>
      prev.map((t) => (t.paroleeId === userId ? { ...t, paroleeId: undefined, paroleeName: undefined, status: 'unassigned' } : t))
    );
    return true;
  };

  const assignOfficer = (paroleeId: string, officerId: string) => {
    if (currentUser && !isDemoUser(currentUser)) {
      reportDataError(new Error('Changing officer assignments requires an administrator and was not saved.'), '');
      return;
    }
    setUsers((prev) => prev.map((u) => (u.id === paroleeId ? { ...u, officerId } : u)));
  };

  const removeOfficer = (paroleeId: string) => {
    if (currentUser && !isDemoUser(currentUser)) {
      reportDataError(new Error('Changing officer assignments requires an administrator and was not saved.'), '');
      return;
    }
    setUsers((prev) => prev.map((u) => (u.id === paroleeId ? { ...u, officerId: undefined } : u)));
  };

  // Tracker Actions
  const assignTracker = async (trackerId: string, paroleeId: string) => {
    const targetParolee = users.find((u) => u.id === paroleeId);
    if (!targetParolee) return;

    if (currentUser && !isDemoUser(currentUser)) {
      try {
        await assignTrackerRecord(trackerId, paroleeId);
        const refreshed = await loadOperationalSnapshot(currentUser.id);
        applyOperationalSnapshot(refreshed);
        setDataError(null);
        setIsSupabaseLive(true);
      } catch (error) {
        reportDataError(error, 'Could not assign the GPS tracker.');
      }
      return;
    }

    setTrackers((prev) =>
      prev.map((t) => {
        if (t.id === trackerId) {
          return {
            ...t,
            paroleeId: targetParolee.id,
            paroleeName: targetParolee.fullName,
            status: 'active',
            assignedAt: new Date().toISOString(),
          };
        }
        if (t.paroleeId === paroleeId && t.id !== trackerId) {
          return { ...t, paroleeId: undefined, paroleeName: undefined, status: 'unassigned' };
        }
        return t;
      })
    );

    setUsers((prev) => prev.map((u) => (u.id === paroleeId ? { ...u, trackerId } : u)));
  };

  const unassignTracker = async (trackerId: string) => {
    const tracker = trackers.find((t) => t.id === trackerId);
    if (!tracker) return;

    if (currentUser && !isDemoUser(currentUser)) {
      try {
        await unassignTrackerRecord(trackerId);
        const refreshed = await loadOperationalSnapshot(currentUser.id);
        applyOperationalSnapshot(refreshed);
        setDataError(null);
        setIsSupabaseLive(true);
      } catch (error) {
        reportDataError(error, 'Could not unassign the GPS tracker.');
      }
      return;
    }

    setTrackers((prev) =>
      prev.map((t) => (t.id === trackerId ? { ...t, paroleeId: undefined, paroleeName: undefined, status: 'unassigned' } : t))
    );

    if (tracker.paroleeId) {
      setUsers((prev) => prev.map((u) => (u.id === tracker.paroleeId ? { ...u, trackerId: undefined } : u)));
    }
  };

  const createTracker = async (trackerId: string, deviceIdentifier: string): Promise<boolean> => {
    const newTracker: GpsTracker = {
      id: trackerId,
      deviceIdentifier: deviceIdentifier || `dev-${trackerId.toLowerCase()}`,
      deviceName: `ESP32 Tracker ${trackerId}`,
      deviceType: 'Wearable Ankle Tracker',
      serialNumber: `SN-TAC-${Date.now().toString().slice(-6)}`,
      status: 'unassigned',
      batteryLevel: 100,
      createdAt: new Date().toISOString(),
    };
    if (currentUser && !isDemoUser(currentUser)) {
      try {
        const savedTracker = await createTrackerRecord(trackerId, deviceIdentifier);
        setTrackers((prev) => [savedTracker, ...prev.filter((tracker) => tracker.id !== savedTracker.id)]);
        setDataError(null);
        setIsSupabaseLive(true);
        return true;
      } catch (error) {
        reportDataError(error, 'Could not save the GPS tracker.');
        return false;
      }
    }
    setTrackers((prev) => [newTracker, ...prev]);
    return true;
  };

  const assignGeofence = async (data: Omit<Geofence, 'id'>): Promise<boolean> => {
    const newGf: Geofence = {
      ...data,
      id: `gf-${Date.now()}`,
    };
    if (currentUser && !isDemoUser(currentUser)) {
      try {
        const savedGeofence = await createGeofenceRecord(data);
        setGeofences((prev) => [savedGeofence, ...prev]);
        setDataError(null);
        setIsSupabaseLive(true);
        return true;
      } catch (error) {
        reportDataError(error, 'Could not save the geofence.');
        return false;
      }
    }
    setGeofences((prev) => [...prev, newGf]);
    return true;
  };

  // Activity Actions with Supabase Sync
  const createActivity = async (data: {
    title: string;
    type: ActivityType;
    description: string;
    location: string;
    scheduleDate: string;
    assignedParoleeIds: string[];
  }): Promise<boolean> => {
    const newAct: ActivityModel = {
      id: `act-${Date.now()}`,
      title: data.title,
      type: data.type,
      description: data.description,
      location: data.location,
      scheduleDate: data.scheduleDate,
      assignedParoleeIds: data.assignedParoleeIds,
      assignedOfficerId: currentUser?.id || 'demo-officer',
      officerName: currentUser?.fullName || 'Maria Santos',
      status: 'pending',
      createdAt: new Date().toISOString(),
      completedParoleeIds: [],
    };
    if (currentUser && !isDemoUser(currentUser)) {
      try {
        const savedActivity = await createActivityRecord(data, currentUser);
        setActivities((prev) => [savedActivity, ...prev]);
        setDataError(null);
        setIsSupabaseLive(true);
        return true;
      } catch (error) {
        reportDataError(error, 'Could not save the activity.');
        return false;
      }
    }
    setActivities((prev) => [newAct, ...prev]);
    return true;
  };

  const updateActivityStatus = async (activityId: string, status: ActivityStatus) => {
    if (currentUser && !isDemoUser(currentUser)) {
      try {
        await updateActivityRecordStatus(activityId, status);
        setDataError(null);
        setIsSupabaseLive(true);
      } catch (error) {
        reportDataError(error, 'Could not update the activity.');
        return;
      }
    }
    setActivities((prev) => prev.map((a) => (a.id === activityId ? { ...a, status } : a)));
  };

  // Attendance Actions with Supabase Sync
  const persistAttendanceRecord = async (record: AttendanceRecord) => {
    if (!isSupabaseConfigured || (currentUser && isDemoUser(currentUser))) return;

    const { error } = await supabase.from('attendance_records').insert({
      ticket_id: record.ticketId,
      parolee_id: record.paroleeId,
      officer_id: record.officerId,
      status: record.status,
      check_in_time: record.checkInTime || null,
      location: record.location,
      verified: record.verified,
    });

    if (error) {
      setIsSupabaseLive(false);
      throw new Error(`Could not save attendance to Supabase: ${error.message}`);
    }

    setIsSupabaseLive(true);
  };

  const issueActivityQr = async (activityId: string, rotate = false): Promise<string> => {
    if (!currentUser) throw new Error('Sign in before requesting an activity QR ticket.');

    if (isDemoUser(currentUser)) {
      const activity = activities.find((item) => item.id === activityId);
      if (!activity || !activity.assignedParoleeIds.includes(currentUser.id)) {
        throw new Error('Select an activity assigned to your account.');
      }
      return JSON.stringify({
        ticketId: `AT-2026-${Math.floor(1000 + Math.random() * 9000)}`,
        paroleeId: currentUser.id,
        paroleeName: currentUser.fullName,
        activityId,
        timestamp: new Date().toISOString(),
      });
    }

    try {
      const payload = await issueActivityQrRecord(activityId, rotate);
      setDataError(null);
      setIsSupabaseLive(true);
      return payload;
    } catch (error) {
      reportDataError(error, 'Could not issue an activity QR ticket.');
      throw error;
    }
  };

  const verifyAttendanceByQr = async (payloadString: string, expectedActivityId?: string) => {
    try {
      let parsed: {
        ticketId?: string;
        paroleeId?: string;
        activityId?: string;
        t?: string;
        token?: string;
        a?: string;
      };
      try {
        parsed = JSON.parse(payloadString);
      } catch {
        return {
          success: false,
          message: 'This is not a complete check-in QR payload. Scan the parolee QR code or paste its full payload.',
        };
      }

      if (currentUser && !isDemoUser(currentUser)) {
        const token = parsed.t || parsed.token;
        const activityId = parsed.a || parsed.activityId;
        if (!token || !activityId) {
          return {
            success: false,
            message: 'This QR code is not a server-issued activity ticket. Ask the parolee to refresh their activity QR.',
          };
        }
        if (!expectedActivityId || activityId !== expectedActivityId) {
          return { success: false, message: 'This QR code does not match the selected activity.' };
        }
        const activity = activities.find((item) => item.id === activityId);
        if (!activity || activity.assignedOfficerId !== currentUser.id) {
          return { success: false, message: 'This activity is not assigned to your account.' };
        }

        const record = await recordActivityQr(payloadString, expectedActivityId, users);
        const nextCompletedIds = activity.completedParoleeIds.includes(record.paroleeId)
          ? activity.completedParoleeIds
          : [...activity.completedParoleeIds, record.paroleeId];
        const nextStatus =
          nextCompletedIds.length >= activity.assignedParoleeIds.length ? 'completed' : 'ongoing';
        if (nextStatus !== activity.status) {
          await updateActivityRecordStatus(activity.id, nextStatus);
        }
        setAttendance((prev) => [record, ...prev.filter((item) => item.id !== record.id)]);
        setActivities((prev) =>
          prev.map((item) =>
            item.id === activity.id
              ? { ...item, completedParoleeIds: nextCompletedIds, status: nextStatus }
              : item,
          ),
        );
        setDataError(null);
        setIsSupabaseLive(true);
        return {
          success: true,
          message: `Verified check-in for ${record.paroleeName} (activity ticket accepted).`,
          record,
        };
      }

      if (!parsed.ticketId || !parsed.paroleeId) {
        return { success: false, message: 'The QR code is missing its ticket or parolee ID.' };
      }

      const pId = parsed.paroleeId;
      const parolee = users.find((u) => u.id === pId);
      if (!parolee) {
        return { success: false, message: 'The QR code belongs to an unknown parolee.' };
      }

      const actId = parsed.activityId;
      const activity = activities.find((a) => a.id === actId);

      const ticketId = parsed.ticketId;

      const newRecord: AttendanceRecord = {
        id: `att-${Date.now()}`,
        ticketId,
        paroleeId: pId,
        paroleeName: parolee.fullName,
        officerId: currentUser?.id || 'demo-officer',
        status: 'checkedIn',
        checkInTime: new Date().toISOString(),
        scheduledTime: activity?.scheduleDate || new Date().toISOString(),
        location: activity?.location || 'PPA Tacloban Office',
        verified: true,
        qrPayload: payloadString,
        activityId: actId,
        activityTitle: activity?.title || 'Scheduled Check-in',
      };

      setAttendance((prev) => [newRecord, ...prev.filter((r) => r.ticketId !== ticketId)]);

      if (actId) {
        setActivities((prev) =>
          prev.map((a) => {
            if (a.id === actId) {
              const comp = a.completedParoleeIds.includes(pId)
                ? a.completedParoleeIds
                : [...a.completedParoleeIds, pId];
              return {
                ...a,
                completedParoleeIds: comp,
                status: comp.length >= a.assignedParoleeIds.length ? 'completed' : 'ongoing',
              };
            }
            return a;
          })
        );
      }

      return {
        success: true,
        message: `Verified check-in for ${parolee?.fullName || 'Parolee'} (Ticket: ${ticketId})`,
        record: newRecord,
      };
    } catch (e) {
      if (currentUser && !isDemoUser(currentUser)) setIsSupabaseLive(false);
      return {
        success: false,
        message: e instanceof Error ? e.message : 'QR validation failed',
      };
    }
  };

  const markAttendanceManual = async (activityId: string, paroleeId: string, status: AttendanceStatus) => {
    const parolee = users.find((u) => u.id === paroleeId);
    const activity = activities.find((a) => a.id === activityId);
    if (!parolee || !activity) throw new Error('The selected parolee or activity could not be found.');

    if (currentUser && !isDemoUser(currentUser)) {
      try {
        const record = await markActivityAttendanceRecord(activityId, paroleeId, status, users);
        const nextCompletedIds =
          status === 'checkedIn' || status === 'confirmed'
            ? activity.completedParoleeIds.includes(paroleeId)
              ? activity.completedParoleeIds
              : [...activity.completedParoleeIds, paroleeId]
            : activity.completedParoleeIds.filter((id) => id !== paroleeId);
        const nextStatus =
          nextCompletedIds.length >= activity.assignedParoleeIds.length ? 'completed' : 'ongoing';
        if (nextStatus !== activity.status) {
          await updateActivityRecordStatus(activityId, nextStatus);
        }
        setAttendance((prev) => [
          record,
          ...prev.filter((item) => !(item.activityId === activityId && item.paroleeId === paroleeId)),
        ]);
        setActivities((prev) =>
          prev.map((item) =>
            item.id === activityId
              ? { ...item, completedParoleeIds: nextCompletedIds, status: nextStatus }
              : item,
          ),
        );
        setDataError(null);
        setIsSupabaseLive(true);
      } catch (error) {
        reportDataError(error, 'Could not save manual attendance.');
        throw error;
      }
      return;
    }

    const ticketId = `AT-2026-${Math.floor(1000 + Math.random() * 9000)}`;
    const newRecord: AttendanceRecord = {
      id: `att-${Date.now()}`,
      ticketId,
      paroleeId,
      paroleeName: parolee.fullName,
      officerId: currentUser?.id || 'demo-officer',
      status,
      checkInTime: status === 'checkedIn' ? new Date().toISOString() : undefined,
      scheduledTime: activity.scheduleDate,
      location: activity.location,
      verified: status === 'checkedIn',
      activityId,
      activityTitle: activity.title,
    };

    await persistAttendanceRecord(newRecord);

    setAttendance((prev) => [newRecord, ...prev]);

    if (status === 'checkedIn') {
      setActivities((prev) =>
        prev.map((a) => {
          if (a.id === activityId) {
            const comp = a.completedParoleeIds.includes(paroleeId)
              ? a.completedParoleeIds
              : [...a.completedParoleeIds, paroleeId];
            return {
              ...a,
              completedParoleeIds: comp,
              status: comp.length >= a.assignedParoleeIds.length ? 'completed' : 'ongoing',
            };
          }
          return a;
        })
      );
    }

  };

  const submitParoleeSelfCheckIn = async (activityId: string): Promise<AttendanceRecord> => {
    if (!currentUser) throw new Error('Not logged in');
    if (!isDemoUser(currentUser)) {
      throw new Error('Use the server-issued activity QR ticket for check-in.');
    }
    const act = activities.find((a) => a.id === activityId) || activities[0];
    const ticketId = `AT-2026-${Math.floor(1000 + Math.random() * 9000)}`;

    const newRecord: AttendanceRecord = {
      id: `att-${Date.now()}`,
      ticketId,
      paroleeId: currentUser.id,
      paroleeName: currentUser.fullName,
      officerId: currentUser.officerId || 'demo-officer',
      status: 'pending',
      scheduledTime: act?.scheduleDate || new Date().toISOString(),
      location: act?.location || 'PPA Tacloban Office',
      verified: false,
      activityId: act?.id,
      activityTitle: act?.title,
    };

    await persistAttendanceRecord(newRecord);
    setAttendance((prev) => [newRecord, ...prev]);

    return newRecord;
  };

  // Location & Proximity Helpers
  const shareParoleeLocation = (paroleeId: string, lat: number, lng: number) => {
    const loc: LocationRecord = {
      id: `loc-mobile-${Date.now()}`,
      trackerId: 'MOBILE-GPS',
      paroleeId,
      latitude: lat,
      longitude: lng,
      accuracy: 6.0,
      recordedAt: new Date().toISOString(),
      source: 'mobile',
    };
    setLiveLocations((prev) => ({ ...prev, [paroleeId]: loc }));
    setLocationHistories((prev) => ({
      ...prev,
      [paroleeId]: [loc, ...(prev[paroleeId] || [])],
    }));

    if (isSupabaseConfigured) {
      void supabase
        .from('location_logs')
        .insert({
          parolee_id: paroleeId,
          tracker_id: 'MOBILE-GPS',
          latitude: lat,
          longitude: lng,
          accuracy: 6.0,
          speed: 0,
        })
        .then(({ error }) => {
          if (error) {
            console.warn('[Supabase] location_logs insert note:', error.message);
          }
        });
    }
  };

  const getParoleeSummary = useCallback(
    (paroleeId: string): ParoleeTrackingSummary | null => {
      const p = users.find((u) => u.id === paroleeId);
      if (!p) return null;

      const tracker = trackers.find((t) => t.paroleeId === paroleeId || t.id === p.trackerId);
      const loc = liveLocations[paroleeId];
      const pGeofences = geofences.filter((g) => g.paroleeId === paroleeId);

      let geofenceStatus: GeofenceStatus = 'unknown';
      if (pGeofences.length === 0) {
        geofenceStatus = 'noGeofence';
      } else if (loc) {
        const monitoringZone = pGeofences.find((g) => !g.name.toLowerCase().includes('check-in'));
        if (monitoringZone) {
          const d = calculateDistanceMeters(loc.latitude, loc.longitude, monitoringZone.centerLat, monitoringZone.centerLng);
          geofenceStatus = d <= monitoringZone.radiusMeters ? 'inside' : 'outside';
        } else {
          geofenceStatus = 'inside';
        }
      }

      const checkInZone = pGeofences.find((g) => g.name.toLowerCase().includes('check-in')) || {
        centerLat: APP_CONFIG.taclobanLat,
        centerLng: APP_CONFIG.taclobanLng,
        name: 'PPA Tacloban Check-in Office',
      };

      const dist = loc
        ? calculateDistanceMeters(loc.latitude, loc.longitude, checkInZone.centerLat, checkInZone.centerLng)
        : 9999;

      const checkInProximity: CheckInProximity = {
        isWithinProximity: dist <= APP_CONFIG.proximityRadiusMeters,
        distanceMeters: dist,
        isSimulated: loc?.source === 'simulated',
        targetLat: checkInZone.centerLat,
        targetLng: checkInZone.centerLng,
        targetName: checkInZone.name,
        timestamp: loc?.recordedAt || new Date().toISOString(),
      };

      return {
        paroleeId: p.id,
        fullName: p.fullName,
        caseNumber: p.caseNumber || 'N/A',
        officerId: p.officerId || '',
        trackingStatus: tracker?.status || 'unassigned',
        tracker,
        latestLocation: loc,
        geofenceStatus,
        geofences: pGeofences,
        checkInProximity,
      };
    },
    [users, trackers, geofences, liveLocations]
  );

  const stats: DashboardStats = useMemo(() => {
    const parolees = users.filter((u) => u.role === 'parolee');
    const checkedIn = attendance.filter((a) => a.status === 'checkedIn').length;
    const pending = attendance.filter((a) => a.status === 'pending').length;
    const missed = attendance.filter((a) => a.status === 'missed').length;

    return {
      totalCases: parolees.length,
      checkedIn,
      pending,
      missed,
    };
  }, [users, attendance]);

  const markNotificationRead = async (id: string) => {
    if (currentUser && !isDemoUser(currentUser)) {
      try {
        await markNotificationReadRecord(id, currentUser.id);
        setDataError(null);
        setIsSupabaseLive(true);
      } catch (error) {
        reportDataError(error, 'Could not update the notification.');
        return;
      }
    }
    setNotifications((prev) => prev.map((n) => (n.id === id ? { ...n, isRead: true } : n)));
  };

  const clearNotifications = async () => {
    if (currentUser && !isDemoUser(currentUser)) {
      try {
        await clearNotificationRecords(currentUser.id);
        setDataError(null);
        setIsSupabaseLive(true);
      } catch (error) {
        reportDataError(error, 'Could not clear notifications.');
        return;
      }
    }
    setNotifications([]);
  };

  return (
    <AppContext.Provider
      value={{
        currentUser,
        isAuthLoading,
        authNotice,
        dataError,
        dismissDataError: () => setDataError(null),
        canQuickSwitchRole: isDemoUser(currentUser),
        users,
        trackers,
        geofences,
        activities,
        attendance,
        notifications,
        liveLocations,
        locationHistories,
        stats,
        isSimulating,
        isSupabaseLive,
        setIsSimulating,
        login,
        logout,
        quickSwitchRole,
        signUp,
        toggleUserActive,
        deleteUser,
        assignOfficer,
        removeOfficer,
        assignTracker,
        unassignTracker,
        createTracker,
        assignGeofence,
        createActivity,
        issueActivityQr,
        updateActivityStatus,
        verifyAttendanceByQr,
        markAttendanceManual,
        submitParoleeSelfCheckIn,
        shareParoleeLocation,
        getParoleeSummary,
        markNotificationRead,
        clearNotifications,
      }}
    >
      {children}
    </AppContext.Provider>
  );
};

export const useApp = () => {
  const context = useContext(AppContext);
  if (!context) {
    throw new Error('useApp must be used within an AppProvider');
  }
  return context;
};
