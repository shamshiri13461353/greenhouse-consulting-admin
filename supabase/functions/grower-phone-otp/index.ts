import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const allowedOrigins = new Set([
  "https://app.peyvandgostar.com",
  "https://shamshiri13461353.github.io",
  "http://localhost:5173",
  "http://localhost:4173",
]);

function corsHeaders(origin: string | null) {
  const allowed = origin && allowedOrigins.has(origin) ? origin : "https://app.peyvandgostar.com";
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(status: number, body: Record<string, unknown>, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function toEnglishDigits(value: string) {
  return value.replace(/[۰-۹]/g, (d) => String("۰۱۲۳۴۵۶۷۸۹".indexOf(d)))
    .replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)));
}

function normalizePhone(value: unknown): string | null {
  if (typeof value !== "string") return null;
  let phone = toEnglishDigits(value).replace(/[\s()-]/g, "");
  if (phone.startsWith("+98")) phone = "0" + phone.slice(3);
  else if (phone.startsWith("0098")) phone = "0" + phone.slice(4);
  else if (phone.startsWith("98") && phone.length === 12) phone = "0" + phone.slice(2);
  return /^09\d{9}$/.test(phone) ? phone : null;
}

function normalizeCode(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const code = toEnglishDigits(value).trim();
  return /^\d{6}$/.test(code) ? code : null;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" }, origin);

  const apiKey = Deno.env.get("OTPY_API_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!apiKey || !supabaseUrl || !serviceRoleKey) {
    console.error("grower-phone-otp: required server secrets are missing");
    return json(500, { error: "server_configuration_error" }, origin);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid_json" }, origin);
  }

  const action = body.action;
  const phone = normalizePhone(body.phone);
  if (!phone) return json(400, { error: "invalid_phone" }, origin);
  if (action !== "send" && action !== "verify") {
    return json(400, { error: "invalid_action" }, origin);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const verifications = admin.from("grower_phone_verifications");

  try {
    if (action === "send") {
      const { data: existingProfile, error: profileError } = await admin
        .from("user_profiles").select("id").eq("phone", phone)
        .neq("account_status", "disabled").limit(1).maybeSingle();
      if (profileError) {
        console.error("grower-phone-otp: profile lookup failed", profileError.message);
        return json(500, { error: "account_lookup_failed" }, origin);
      }
      if (existingProfile) return json(409, { error: "phone_already_registered" }, origin);

      // Also detect accounts created before profile.phone was populated.
      // Grower accounts use a deterministic, internal email alias for phone login.
      const alias = `${phone}@grower.peyvandgostar.com`;
      let aliasConflict = false;
      for (let page = 1; page <= 100; page++) {
        const { data: usersPage, error: usersError } = await admin.auth.admin.listUsers({
          page,
          perPage: 1000,
        });
        if (usersError) {
          console.error("grower-phone-otp: auth account lookup failed", usersError.message);
          return json(500, { error: "account_lookup_failed" }, origin);
        }
        const users = usersPage?.users || [];
        const aliasUser = users.find((user) => (user.email || "").toLowerCase() === alias.toLowerCase());
        if (aliasUser) {
          const { data: aliasProfile, error: aliasProfileError } = await admin
            .from("user_profiles").select("phone,account_status").eq("id", aliasUser.id).maybeSingle();
          if (aliasProfileError) {
            console.error("grower-phone-otp: alias profile lookup failed", aliasProfileError.message);
            return json(500, { error: "account_lookup_failed" }, origin);
          }
          // Reuse is permitted only when the existing alias belongs to a disabled
          // account whose stored phone exactly matches the newly verified number.
          aliasConflict = !(aliasProfile?.account_status === "disabled" && aliasProfile.phone === phone);
          break;
        }
        if (users.length < 1000) break;
      }
      if (aliasConflict) return json(409, { error: "phone_already_registered" }, origin);

      const { data: previous, error: previousError } = await verifications
        .select("created_at, verified_at, consumed_at")
        .eq("phone", phone).maybeSingle();
      if (previousError) {
        console.error("grower-phone-otp: verification lookup failed", previousError.message);
        return json(500, { error: "verification_lookup_failed" }, origin);
      }
      if (previous?.created_at) {
        const elapsed = Date.now() - new Date(previous.created_at).getTime();
        if (elapsed < 45_000) {
          return json(429, { error: "send_cooldown", retry_in: Math.ceil((45_000 - elapsed) / 1000) }, origin);
        }
      }

      const upstream = await fetch("https://api.otpy.ir/v1/otp/send", {
        method: "POST",
        headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ phone }),
        signal: AbortSignal.timeout(12_000),
      });
      const result = await upstream.json().catch(() => ({}));
      if (!upstream.ok || typeof result.request_id !== "string") {
        const upstreamCode = typeof result.error === "string" ? result.error : "sms_provider_error";
        const status = upstream.status === 429 ? 429 : upstream.status === 402 ? 402 : upstream.status === 401 ? 502 : 502;
        return json(status, { error: upstreamCode, ...(typeof result.retry_in === "number" ? { retry_in: result.retry_in } : {}) }, origin);
      }

      const ttl = typeof result.ttl_seconds === "number" ? Math.min(Math.max(result.ttl_seconds, 60), 600) : 300;
      const { error: saveError } = await verifications.upsert({
        phone,
        request_id: result.request_id,
        expires_at: new Date(Date.now() + ttl * 1000).toISOString(),
        verified_at: null,
        consumed_at: null,
        created_at: new Date().toISOString(),
      }, { onConflict: "phone" });
      if (saveError) {
        console.error("grower-phone-otp: could not persist send request", saveError.message);
        return json(500, { error: "verification_state_save_failed" }, origin);
      }

      return json(200, { success: true, ttl_seconds: ttl, free: result.free === true }, origin);
    }

    const code = normalizeCode(body.code);
    if (!code) return json(400, { error: "invalid_code_format" }, origin);

    const { data: pending, error: pendingError } = await verifications
      .select("expires_at, verified_at, consumed_at")
      .eq("phone", phone).maybeSingle();
    if (pendingError) {
      console.error("grower-phone-otp: pending lookup failed", pendingError.message);
      return json(500, { error: "verification_lookup_failed" }, origin);
    }
    if (!pending || new Date(pending.expires_at).getTime() <= Date.now() || pending.consumed_at) {
      return json(400, { error: "code_expired_or_not_requested" }, origin);
    }
    if (pending.verified_at) return json(200, { success: true, verified: true }, origin);

    const upstream = await fetch("https://api.otpy.ir/v1/otp/verify", {
      method: "POST",
      headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ phone, code }),
      signal: AbortSignal.timeout(12_000),
    });
    const result = await upstream.json().catch(() => ({}));
    if (!upstream.ok) {
      const upstreamCode = typeof result.error === "string" ? result.error : "sms_provider_error";
      const status = upstream.status === 429 ? 429 : upstream.status === 401 ? 502 : 400;
      return json(status, { error: upstreamCode, ...(typeof result.retry_in === "number" ? { retry_in: result.retry_in } : {}) }, origin);
    }
    if (result.verified !== true) return json(400, { error: "invalid_or_expired_code", verified: false }, origin);

    const { error: markError } = await verifications
      .update({ verified_at: new Date().toISOString() })
      .eq("phone", phone).is("verified_at", null).is("consumed_at", null);
    if (markError) {
      console.error("grower-phone-otp: could not persist verification", markError.message);
      return json(500, { error: "verification_state_save_failed" }, origin);
    }
    return json(200, { success: true, verified: true }, origin);
  } catch (error) {
    console.error("grower-phone-otp: unexpected server error", error instanceof Error ? error.message : "unknown");
    return json(502, { error: "temporary_service_error" }, origin);
  }
});