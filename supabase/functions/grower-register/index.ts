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
  return value.replace(/[۰-۹]/g, d => String("۰۱۲۳۴۵۶۷۸۹".indexOf(d)))
    .replace(/[٠-٩]/g, d => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)));
}

function normalizePhone(value: unknown): string | null {
  if (typeof value !== "string") return null;
  let phone = toEnglishDigits(value).replace(/[\s()-]/g, "");
  if (phone.startsWith("+98")) phone = "0" + phone.slice(3);
  else if (phone.startsWith("0098")) phone = "0" + phone.slice(4);
  else if (phone.startsWith("98") && phone.length === 12) phone = "0" + phone.slice(2);
  return /^09\d{9}$/.test(phone) ? phone : null;
}

function cleanName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const s = value.trim().replace(/\s+/g, " ");
  return s ? s.slice(0, 80) : null;
}


async function notifyAdminsOfNewGrower(admin: any, supabaseUrl: string, newGrowerUserId: string) {
  try {
    const { data: admins, error: adminError } = await admin
      .from("user_roles")
      .select("user_id")
      .eq("role_code", "admin");
    if (adminError) throw new Error("admin lookup failed: " + adminError.message);
    const userIds = [...new Set((admins || []).map((row: any) => row.user_id).filter(Boolean))];
    if (!userIds.length) {
      console.warn("grower-register: no admin accounts found for push notification");
      return;
    }

    const notificationRows = userIds.map((userId: string) => ({
      user_id: userId,
      notification_type: "new_grower_registration",
      title: "ثبت‌نام گلخانه‌دار جدید",
      body: "یک گلخانه‌دار جدید در سامانه ثبت‌نام کرده است.",
      related_user_id: newGrowerUserId,
    }));
    const { error: historyError } = await admin.from("admin_notifications").insert(notificationRows);
    if (historyError) {
      console.error("grower-register: admin notification history insert failed", historyError.message);
    }

    const { data: dispatchSecret, error: secretError } = await admin.rpc("get_web_push_dispatch_secret");
    if (secretError || !dispatchSecret) {
      throw new Error("push dispatch secret unavailable: " + (secretError?.message || "missing secret"));
    }

    const response = await fetch(`${supabaseUrl}/functions/v1/push-dispatch`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-push-dispatch-secret": dispatchSecret,
      },
      body: JSON.stringify({
        user_ids: userIds,
        title: "ثبت‌نام گلخانه‌دار جدید",
        body: "یک گلخانه‌دار جدید در سامانه ثبت‌نام کرده است.",
        url: "/management/",
        event: "new-grower-registration",
      }),
    });

    if (!response.ok) {
      const detail = (await response.text()).slice(0, 300);
      throw new Error("push-dispatch returned " + response.status + ": " + detail);
    }
    const result = await response.json();
    console.log("grower registration push dispatched", {
      sent: result?.sent ?? 0,
      total: result?.total ?? 0,
    });
  } catch (error) {
    // Notification delivery must never roll back a successfully created grower account.
    console.error("grower-register: admin push notification failed", error instanceof Error ? error.message : "unknown");
  }
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" }, origin);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("grower-register: required server secrets are missing");
    return json(500, { error: "server_configuration_error" }, origin);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); }
  catch { return json(400, { error: "invalid_json" }, origin); }

  const phone = normalizePhone(body.phone);
  const password = typeof body.password === "string" ? body.password : "";
  if (!phone) return json(400, { error: "invalid_phone" }, origin);
  if (password.length < 8 || password.length > 72) {
    return json(400, { error: "password_length_invalid" }, origin);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const { data: existing, error: lookupError } = await admin
      .from("user_profiles").select("id").eq("phone", phone)
      .neq("account_status", "disabled").limit(1).maybeSingle();
    if (lookupError) {
      console.error("grower-register: phone lookup failed", lookupError.message);
      return json(500, { error: "account_lookup_failed" }, origin);
    }
    if (existing) return json(409, { error: "phone_already_registered" }, origin);

    const now = new Date().toISOString();
    const { data: claim, error: claimError } = await admin
      .from("grower_phone_verifications")
      .update({ consumed_at: now })
      .eq("phone", phone)
      .not("verified_at", "is", null)
      .is("consumed_at", null)
      .gt("expires_at", now)
      .select("phone")
      .maybeSingle();

    if (claimError) {
      console.error("grower-register: verification claim failed", claimError.message);
      return json(500, { error: "verification_claim_failed" }, origin);
    }
    if (!claim) return json(400, { error: "phone_not_verified_or_expired" }, origin);

    // Internal, non-deliverable email alias allows Supabase email/password auth
    // without requiring a real email address or enabling the Phone provider.
    const authEmail = `${phone}@grower.peyvandgostar.com`;

    // If this phone belonged to a disabled account, retire its old login alias
    // before creating a fresh auth user. The old user remains banned and all
    // historical rows remain attached to its original immutable user ID.
    let previousAliasUser: any = null;
    for (let page = 1; page <= 100; page++) {
      const { data: usersPage, error: usersError } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
      if (usersError) {
        console.error("grower-register: previous auth lookup failed", usersError.message);
        return json(500, { error: "account_lookup_failed" }, origin);
      }
      const users = usersPage?.users || [];
      previousAliasUser = users.find((user) => (user.email || "").toLowerCase() === authEmail.toLowerCase()) || null;
      if (previousAliasUser || users.length < 1000) break;
    }

    if (previousAliasUser) {
      const { data: previousProfile, error: previousProfileError } = await admin
        .from("user_profiles").select("id,phone,account_status")
        .eq("id", previousAliasUser.id).maybeSingle();
      if (previousProfileError) {
        console.error("grower-register: previous profile lookup failed", previousProfileError.message);
        return json(500, { error: "account_lookup_failed" }, origin);
      }
      if (previousProfile?.account_status !== "disabled" || previousProfile.phone !== phone) {
        return json(409, { error: "phone_already_registered" }, origin);
      }

      const retiredEmail = `retired-${previousAliasUser.id}@retired.grower.peyvandgostar.com`;
      const { error: retireError } = await admin.auth.admin.updateUserById(previousAliasUser.id, {
        email: retiredEmail,
        email_confirm: true,
        ban_duration: "876000h",
      });
      if (retireError) {
        console.error("grower-register: could not retire disabled account alias", retireError.message);
        return json(500, { error: "previous_account_release_failed" }, origin);
      }
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email: authEmail,
      password,
      email_confirm: true,
      user_metadata: { signup_source: "grower_phone_otp" },
    });

    if (createError || !created.user) {
      console.error("grower-register: auth user creation failed", createError?.message);
      return json(409, { error: "account_creation_failed_try_again" }, origin);
    }

    const userId = created.user.id;
    const { error: profileError } = await admin.from("user_profiles").update({
      phone,
      first_name: cleanName(body.first_name),
      last_name: cleanName(body.last_name),
      account_status: "active",
      updated_at: now,
    }).eq("id", userId);

    if (profileError) {
      console.error("grower-register: profile activation failed", profileError.message);
      await admin.from("user_profiles").delete().eq("id", userId);
      await admin.auth.admin.deleteUser(userId);
      return json(500, { error: "account_profile_setup_failed" }, origin);
    }

    const { error: roleError } = await admin.from("user_roles").insert({
      user_id: userId,
      role_code: "grower",
      assigned_by: null,
    });

    if (roleError) {
      console.error("grower-register: role assignment failed", roleError.message);
      await admin.from("user_profiles").delete().eq("id", userId);
      await admin.auth.admin.deleteUser(userId);
      return json(500, { error: "account_role_setup_failed" }, origin);
    }

    await notifyAdminsOfNewGrower(admin, supabaseUrl, userId);
    return json(201, { success: true, account_created: true }, origin);
  } catch (error) {
    console.error("grower-register: unexpected error", error instanceof Error ? error.message : "unknown");
    return json(500, { error: "registration_failed" }, origin);
  }
});
