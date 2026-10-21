# PPA-TAC: Parole & Probation Attendance & Tracking System

A comprehensive, production-grade web application rewritten in **React, TypeScript, Vite, Tailwind CSS, and Leaflet** for the Parole and Probation Administration (PPA) Tacloban Field Office.

## Overview

PPA-TAC enables biometric attendance verification, IoT wearable GPS tracking, geofence compliance monitoring, and community rehabilitation management for probation officers and parolees.

### Core Features

- **Role-Based Workflows**:
  - **Probation Officer Portal**: Complete supervision dashboard, caseload management, real-time GPS map tracking, 50-meter check-in proximity verification, geofencing configuration, activity management with QR attendance scanning, and official PPA audit report generation.
  - **Parolee Portal**: Supervision status countdown, scheduled community activities, instant QR check-in ticket generation, proximity verification, mobile GPS location sharing, and attendance history.
- **GPS Surveillance & Proximity Alerting**:
  - Real-time coordinates around Tacloban City (`11.240800, 125.003900`) with simulated or wearable IoT beacon telemetry.
  - Automatic alerts when a parolee enters the strict 50-meter perimeter of the PPA Tacloban Field Office.
  - Geofence zone violation evaluation (`INSIDE ASSIGNED AREA` vs `OUTSIDE ASSIGNED AREA`).
  - Route history breadcrumbs with interactive waypoint replay.
- **QR Code Attendance System**:
  - Secure QR tickets generated dynamically with Ticket IDs (`AT-2026-XXXX`).
  - Live camera QR scanning for officers, simulated test scans, and manual verification using the full QR payload.
- **Reporting & Compliance**:
  - Metric breakdown: Compliance Score (%), Attendance Rate (%), Total Check-ins, Missed, Pending.
  - Weekly attendance punctuality and 6-month compliance charts.
  - Printable official government report template formatted for the Department of Justice Parole and Probation Administration.

## Demo Accounts

| Role | Email | Password | Details |
|---|---|---|---|
| **Probation Officer** | `officer@ppa-attendance.com` | `password123` | Officer Maria Santos (District 4) |
| **Parolee** | `parolee@ppa-attendance.com` | `password123` | Juan Dela Cruz (Case # PP-2024-1847) |

Use the "Switch to Officer / Parolee" button in the top navigation to seamlessly toggle between experiences during testing.

## Technology Stack

- **Frontend**: React 19, TypeScript, Vite
- **Styling**: Tailwind CSS, Lucide Icons
- **Mapping**: Leaflet, OpenStreetMap
- **QR Code Engine**: `qrcode.react`
- **Port**: 3000 (`0.0.0.0`)

## Supabase

The React and Flutter apps use Supabase rather than Firebase. The React app uses Supabase Auth and the `public.location_logs`, `public.activities`, and `public.attendance_records` tables. Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` for the web app. The Flutter app initializes Supabase in `lib/core/utils/supabase_config.dart`.

Flutter activity QR check-in also requires [`supabase/setup_activity_attendance.sql`](supabase/setup_activity_attendance.sql). Review and run it after the `profiles` table and the base `activities` table exist. It adds missing activity assignment/status columns, creates the activity attendance table, and installs authenticated server functions for issuing five-minute, single-use QR tickets and recording scans. Existing activities receive an empty parolee assignment list and `pending` status only when those columns are newly added. The script is additive and is not applied automatically. Run `supabase/verify_schema.sql` afterward to check the tables, access rules, and functions.

For Flutter Android email confirmation, add `com.example.last://login-callback/` to **Supabase Dashboard → Authentication → URL Configuration → Redirect URLs**. The Android APK registers that callback and sends it with signup and resend requests. Users should open the confirmation email on the Android device with the APK installed. If the Android `applicationId` changes from `com.example.last`, update the callback URI in both the manifest and app code, and update the Supabase redirect allowlist.

Flutter Web confirmation emails redirect to the current browser origin. For local development, add `http://localhost:*/**` to the same Supabase Redirect URLs allowlist so links keep working when Flutter selects a different local port. For production, add the exact deployed web origin instead; do not use a localhost URL for real users.

To inspect the live schema, open your Supabase project, go to **SQL Editor**, and run [`supabase/verify_schema.sql`](supabase/verify_schema.sql). The query is read-only: it reports expected tables and columns, row-level security, required access policies, and Realtime publication for attendance, location logs, schedules, and notifications. It does not create or alter tables.

The latest schema check found the app tables, location/attendance/GPS columns, enabled RLS, and private tracker credentials. It found eight missing `profiles` columns: `avatar_initials`, `case_number`, `department`, `is_active`, `officer_id`, `supervision_end_date`, `supervision_is_suspended`, and `supervision_start_date`. The access-policy checks and `ppa_can_manage_tracker` are also missing because the policy script stopped at its initial profile-column check. Run the verifier first to distinguish missing objects from a stale API schema cache. If it confirms missing profile columns, run `setup_profiles.sql`; if it confirms location or attendance gaps, run `setup_location_logs.sql` and `setup_attendance_records.sql`. If `schedules` or `notifications` are missing, review and run [`supabase/setup_schedules_notifications.sql`](supabase/setup_schedules_notifications.sql) after the required `profiles` columns exist. That script creates both tables if needed, enables row-level security, limits records to an account’s own data or assigned caseload, and adds both tables to Realtime. Then rerun the verifier. These scripts preserve existing records and do not import data from another backend. `setup_profiles.sql` sets the added `is_active` column to true for existing profiles, matching the app's default, and copies existing assignments from `assigned_officer_id` to `officer_id` when that legacy column exists.

After the required tables and columns exist, review and run [`supabase/setup_esp32_trackers.sql`](supabase/setup_esp32_trackers.sql), then [`supabase/setup_access_policies.sql`](supabase/setup_access_policies.sql). The ESP32 setup creates the tracker inventory, a private table containing only device-token hashes, and a database function that inserts locations only for the tracker's current assignment. The access-policy script creates unassigned officer/parolee profiles from Auth signups, allows officers to manage unassigned tracker inventory and trackers within their caseload, limits location reads to the account owner, assigned officer, or administrator, restricts check-ins to the signed-in parolee, and allows only authenticated phone-location writes for that user's own account. Existing administrator profiles must be provisioned through a trusted Supabase admin path; users cannot promote themselves by changing user metadata or profile fields.

Officer dashboard summaries require [`supabase/setup_live_stats.sql`](supabase/setup_live_stats.sql) after `setup_access_policies.sql`. Tracker assignment and unassignment use authenticated database functions so the tracker update and its audit record commit or roll back together. Review and run [`supabase/setup_tracking_audit.sql`](supabase/setup_tracking_audit.sql) after `setup_access_policies.sql`, then run [`supabase/setup_web_data_flows.sql`](supabase/setup_web_data_flows.sql) after `setup_activity_attendance.sql` and the tracking audit setup. These scripts are additive and are not applied automatically. The audit table allows an account to add only events attributed to itself; assignment events are written by the database functions in the same transaction as the tracker changes. Run the read-only schema verifier afterward.

To share hardware inventory across active officers without exposing another officer's parolee identity or location history, review and run [`supabase/setup_shared_officer_trackers.sql`](supabase/setup_shared_officer_trackers.sql) after `setup_web_data_flows.sql`. It enables shared tracker status updates and audited transfers, while tracker assignment remains limited to the acting officer's caseload.

The ESP32 firmware uploads through the `esp32-location` Edge Function using verified TLS and a per-device token. The function validates the device and writes only to the parolee currently assigned to that tracker; the public anon key is only the Supabase project identifier, not device authentication. Follow [`firmware/gps_tracker/README.md`](firmware/gps_tracker/README.md) to apply the database scripts, deploy the function, provision a tracker token, and configure the ESP32. These database changes and the deployment must still be applied to the live Supabase project before hardware uploads can work.
