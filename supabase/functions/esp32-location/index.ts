import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !serviceRoleKey) {
  throw new Error("The Supabase Edge Function environment is incomplete.");
}

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
});

const MAX_BODY_LENGTH = 2048;
const TOKEN_PATTERN = /^[0-9a-f]{64}$/;
const DEVICE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

function jsonResponse(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;

  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.includes("application/json")) {
    return jsonResponse(415, { error: "json_required" });
  }

  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_BODY_LENGTH) {
    return jsonResponse(413, { error: "payload_too_large" });
  }

  let rawBody: string;
  try {
    rawBody = await request.text();
  } catch {
    return jsonResponse(400, { error: "invalid_request" });
  }
  if (rawBody.length === 0 || rawBody.length > MAX_BODY_LENGTH) {
    return jsonResponse(rawBody.length > MAX_BODY_LENGTH ? 413 : 400, {
      error: rawBody.length > MAX_BODY_LENGTH
        ? "payload_too_large"
        : "invalid_request",
    });
  }

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(rawBody);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return jsonResponse(400, { error: "invalid_payload" });
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return jsonResponse(400, { error: "invalid_json" });
  }

  const deviceId = body.device_id;
  const latitude = body.latitude;
  const longitude = body.longitude;
  const accuracy = body.accuracy ?? null;
  const speed = body.speed ?? null;
  const batteryLevel = body.battery_level ?? null;
  const deviceToken = request.headers.get("x-device-token") ?? "";

  if (typeof deviceId !== "string" || !DEVICE_ID_PATTERN.test(deviceId)) {
    return jsonResponse(400, { error: "invalid_device_id" });
  }
  if (
    !isFiniteNumber(latitude) ||
    latitude < -90 ||
    latitude > 90 ||
    !isFiniteNumber(longitude) ||
    longitude < -180 ||
    longitude > 180 ||
    (latitude === 0 && longitude === 0)
  ) {
    return jsonResponse(400, { error: "invalid_coordinates" });
  }
  if (
    accuracy !== null &&
    (!isFiniteNumber(accuracy) || accuracy < 0 || accuracy > 10000)
  ) {
    return jsonResponse(400, { error: "invalid_accuracy" });
  }
  if (speed !== null && (!isFiniteNumber(speed) || speed < 0 || speed > 1000)) {
    return jsonResponse(400, { error: "invalid_speed" });
  }
  if (
    batteryLevel !== null &&
    (
      !isFiniteNumber(batteryLevel) ||
      !Number.isInteger(batteryLevel) ||
      batteryLevel < 0 ||
      batteryLevel > 100
    )
  ) {
    return jsonResponse(400, { error: "invalid_battery_level" });
  }
  if (!TOKEN_PATTERN.test(deviceToken)) {
    return jsonResponse(401, { error: "device_not_authorized" });
  }

  const presentedHash = await sha256Hex(deviceToken);
  const { data: tracker, error: trackerError } = await supabase
    .from("gps_trackers")
    .select("id")
    .eq("device_id", deviceId)
    .maybeSingle();

  if (trackerError) {
    console.error("ESP32 tracker lookup failed:", trackerError.code);
    return jsonResponse(500, { error: "upload_failed" });
  }
  if (!tracker) {
    return jsonResponse(401, { error: "device_not_authorized" });
  }

  const { data: credential, error: credentialError } = await supabase
    .from("gps_tracker_credentials")
    .select("token_hash, is_active")
    .eq("tracker_id", tracker.id)
    .maybeSingle();

  if (credentialError) {
    console.error("ESP32 credential lookup failed:", credentialError.code);
    return jsonResponse(500, { error: "upload_failed" });
  }
  if (
    !credential ||
    !credential.is_active ||
    typeof credential.token_hash !== "string" ||
    !constantTimeEqual(credential.token_hash, presentedHash)
  ) {
    return jsonResponse(401, { error: "device_not_authorized" });
  }

  const { error: insertError } = await supabase.rpc(
    "ppa_record_tracker_location",
    {
      p_tracker_id: tracker.id,
      p_token_hash: presentedHash,
      p_latitude: latitude,
      p_longitude: longitude,
      p_accuracy: accuracy,
      p_speed: speed,
      p_battery_level: batteryLevel,
    },
  );

  if (insertError) {
    if (insertError.code === "P0001") {
      return jsonResponse(403, { error: "tracker_inactive_or_unassigned" });
    }
    console.error("ESP32 location write failed:", insertError.code);
    return jsonResponse(500, { error: "upload_failed" });
  }

  return jsonResponse(201, { accepted: true });
});
