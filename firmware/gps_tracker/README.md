# ESP32 GPS tracker

The firmware sends GPS readings to the PPA-TAC Supabase Edge Function. It does
not write directly to PostgREST, and it does not contain a Supabase
service-role key. HTTPS certificate verification is enabled.

## Hardware and libraries

- ESP32 DevKit / NodeMCU
- NEO-6M, NEO-7M, NEO-M8N, Quectel L86, or another NMEA GPS module
- Wi-Fi (the included firmware currently uses Wi-Fi; GSM needs a separate
  modem transport implementation)
- `TinyGPSPlus` by Mikal Hart
- `ArduinoJson` 6.x or 7.x

GPS serial defaults to 9600 baud on ESP32 UART1: ESP32 RX GPIO 16 connects to
GPS TX, ESP32 TX GPIO 17 connects to GPS RX, and the boards share ground. Check
the GPS board's rated supply voltage before powering it.

## One-time Supabase setup

Run these in the Supabase SQL Editor, in this order, after reviewing them
against the live schema:

1. `supabase/setup_location_logs.sql`
2. `supabase/setup_attendance_records.sql`
3. `supabase/setup_esp32_trackers.sql`
4. `supabase/setup_access_policies.sql`
5. `supabase/verify_schema.sql` (read-only confirmation)

The access-policy script also changes profile and attendance permissions. It
does not erase existing records, but review it before applying. The credential
hash table is not readable by the app's anon or authenticated roles. Do not
loosen location-table RLS to make the ESP32 work.

## Deploy the upload endpoint

Install and authenticate the Supabase CLI on a trusted computer, then from the
project root:

```sh
supabase link --project-ref iqltrfkyzbeepfpmsxci
supabase functions deploy esp32-location
```

`supabase/config.toml` disables Supabase user-JWT verification for this one
function because an ESP32 has no user session. The function instead requires a
64-character, per-device token, checks its SHA-256 hash, verifies that the
tracker is active, and saves the reading for the tracker’s current assignee.
The Supabase service-role key is used only inside the Edge Function runtime.

## Register a tracker and its credential

1. In the app, create a tracker. Note both its tracker row ID (`id`) and device
   identifier (`device_id`). The ESP32 must send the exact `device_id`; location
   rows are linked to the tracker's row ID automatically.
2. On a trusted computer, generate a private token and its hash:

   ```sh
   DEVICE_TOKEN="$(openssl rand -hex 32)"
   printf 'Copy this private token to device_secrets.h: %s\n' "$DEVICE_TOKEN"
   printf 'Copy this SHA-256 hash into the Supabase SQL below: '
   printf '%s' "$DEVICE_TOKEN" | sha256sum
   unset DEVICE_TOKEN
   ```

   Copy the token directly into the local, ignored `device_secrets.h`. Never
   paste the raw token into SQL, commit it, or print/share it in a support
   request. The 64-character hash is safe to store in Supabase.
3. In Supabase SQL Editor, replace the placeholders with the tracker row ID and
   the SHA-256 digest:

   ```sql
   INSERT INTO public.gps_tracker_credentials (tracker_id, token_hash)
   VALUES ('<TRACKER_ROW_ID>', '<64_CHARACTER_SHA256_HASH>')
   ON CONFLICT (tracker_id) DO UPDATE
   SET token_hash = EXCLUDED.token_hash,
       is_active = true,
       rotated_at = now();
   ```

   Revoke a device immediately with:

   ```sql
   UPDATE public.gps_tracker_credentials
   SET is_active = false
   WHERE tracker_id = '<TRACKER_ROW_ID>';
   ```

## Configure and flash

1. Copy `device_secrets.example.h` to `device_secrets.h` in this folder. This
   real file is ignored by Git. Set `DEVICE_ID` to the tracker `device_id`
   (not the tracker row `id` used in `gps_tracker_credentials`),
   `DEVICE_TOKEN` to its raw token, and enter the Wi-Fi name and password.
2. Open `gps_tracker.ino` in Arduino IDE, install the libraries listed above,
   select **ESP32 Dev Module** and the correct serial port, then upload.
3. Open Serial Monitor at 115200 baud. A valid GPS fix and internet connection
   should result in `[GPS upload] Accepted (HTTP 201)`.
4. Assign the tracker to a parolee in the app. Uploads are rejected until it is
   assigned and its status is `active`. Check the Flutter tracking screen and
   `location_logs` in Supabase for the new server-timestamped readings.

If uploads are rejected, Serial Monitor shows the Edge Function's short error
code. An HTTP 401 usually means the device identifier or token does not match a
registered tracker; HTTP 403 means the tracker is inactive or unassigned. A
successful credential upsert only confirms the hash row was saved: it does not
confirm that the Edge Function is deployed, that `DEVICE_ID` matches
`gps_trackers.device_id`, or that the tracker has an active parolee assignment.

The firmware sends battery, accuracy, speed, and coordinates. Location
timestamps in the database are server receipt times, not device-supplied
timestamps. The firmware only accepts a GPS location updated within the last
10 seconds; older readings and queued uploads are discarded rather than
presented as live. The offline queue is RAM-only and is lost if the ESP32
reboots.

## TLS and token notes

`tls_root_ca.h` contains the public Google Trust Services Root R4 certificate
that chains to the project's Supabase HTTPS certificate as checked on
October 19, 2026. It is a trust anchor, not a credential. If Supabase changes
its certificate issuer, update the trust anchor from the new verified chain.
The ESP32 does not use `setInsecure()`.

The anon key in `device_config.h` is public and is sent only as the Supabase
project routing key. Device authorization is the separate random token. Never
put a service-role key in firmware.
