import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const allowedOrigins = new Set([
  "https://app.peyvandgostar.com",
  "https://shamshiri13461353.github.io",
  "http://localhost:5173",
  "http://localhost:4173",
]);

function corsHeaders(origin: string | null) {
  const allowed = origin && allowedOrigins.has(origin)
    ? origin
    : "https://app.peyvandgostar.com";
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
    headers: {
      ...corsHeaders(origin),
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" }, origin);

  const authorization = req.headers.get("Authorization") ?? "";
  const token = authorization.match(/^Bearer\\s+(.+)$/i)?.[1];
  if (!token) return json(401, { error: "authentication_required" }, origin);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) {
    return json(500, { error: "server_configuration_error" }, origin);
  }

  try {
    const caller = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: authData, error: authError } = await caller.auth.getUser(token);
    if (authError || !authData.user) {
      return json(401, { error: "invalid_or_expired_session" }, origin);
    }

    const adminId = authData.user.id;
    const [{ data: adminProfile, error: adminProfileError }, { data: adminRole, error: adminRoleError }] =
      await Promise.all([
        admin.from("user_profiles").select("account_status").eq("id", adminId).maybeSingle(),
        admin.from("user_roles").select("role_code").eq("user_id", adminId).eq("role_code", "admin").maybeSingle(),
      ]);

    if (adminProfileError || adminRoleError) {
      return json(500, { error: "could_not_verify_administrator" }, origin);
    }
    if (adminProfile?.account_status !== "active" || !adminRole) {
      return json(403, { error: "active_administrator_required" }, origin);
    }

    let body: Record<string, unknown>;
    try { body = await req.json(); }
    catch { return json(400, { error: "invalid_json" }, origin); }

    const targetId = typeof body.user_id === "string" ? body.user_id.trim() : "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetId)) {
      return json(400, { error: "invalid_user_id" }, origin);
    }
    if (targetId === adminId) return json(403, { error: "cannot_remove_own_administrator_account" }, origin);

    const [{ data: targetProfile, error: targetProfileError }, { data: targetRoles, error: targetRolesError },
      { data: expertProfile, error: expertProfileError }] = await Promise.all([
        admin.from("user_profiles").select("id,account_status,phone").eq("id", targetId).maybeSingle(),
        admin.from("user_roles").select("role_code").eq("user_id", targetId),
        admin.from("expert_profiles").select("user_id").eq("user_id", targetId).maybeSingle(),
      ]);

    if (targetProfileError || targetRolesError || expertProfileError) {
      return json(500, { error: "could_not_verify_target_account" }, origin);
    }
    if (!targetProfile) return json(404, { error: "grower_account_not_found" }, origin);

    const roleCodes = (targetRoles || []).map((row: { role_code: string }) => row.role_code);
    if (roleCodes.includes("admin") || roleCodes.includes("expert") || expertProfile) {
      return json(403, { error: "target_is_not_an_exclusive_grower_account" }, origin);
    }
    if (!roleCodes.includes("grower") && targetProfile.account_status !== "pending") {
      return json(403, { error: "target_is_not_a_grower_account" }, origin);
    }
    if (targetProfile.account_status === "disabled") {
      return json(200, { success: true, already_removed: true }, origin);
    }

    // Preserve all greenhouse, case, service, laboratory and financial history.
    // Remove account access instead of physically deleting referenced records.
    const { error: banError } = await admin.auth.admin.updateUserById(targetId, {
      ban_duration: "876000h",
    });
    if (banError) {
      console.error("admin-delete-grower: auth ban failed", banError.message);
      return json(500, { error: "could_not_block_authentication" }, origin);
    }

    const { error: profileUpdateError } = await admin.from("user_profiles")
      .update({ account_status: "disabled", updated_at: new Date().toISOString() })
      .eq("id", targetId);
    if (profileUpdateError) {
      await admin.auth.admin.updateUserById(targetId, { ban_duration: "none" });
      console.error("admin-delete-grower: profile disable failed", profileUpdateError.message);
      return json(500, { error: "could_not_mark_account_removed" }, origin);
    }

    if (roleCodes.includes("grower")) {
      const { error: roleDeleteError } = await admin.from("user_roles")
        .delete().eq("user_id", targetId).eq("role_code", "grower");
      if (roleDeleteError) {
        console.error("admin-delete-grower: grower role cleanup failed", roleDeleteError.message);
        return json(500, { error: "account_blocked_but_role_cleanup_failed" }, origin);
      }
    }

    return json(200, {
      success: true,
      account_status: "disabled",
      history_preserved: true,
    }, origin);
  } catch (error) {
    console.error("admin-delete-grower: unexpected error", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "unexpected_account_removal_error" }, origin);
  }
});
