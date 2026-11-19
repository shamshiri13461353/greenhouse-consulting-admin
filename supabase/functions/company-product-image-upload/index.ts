import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.58.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "company-product-images";
const MAX_FILE_SIZE = 4 * 1024 * 1024;
const ALLOWED = new Map([
  ["image/jpeg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
]);
const corsHeaders = {
  "Access-Control-Allow-Origin": "https://app.peyvandgostar.com",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function validImageSignature(bytes: Uint8Array, mime: string) {
  if (mime === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (mime === "image/png") return bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  if (mime === "image/webp") return bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP";
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
    if (!token) return json({ error: "برای بارگذاری تصویر ابتدا وارد پنل مدیریت شوید." }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const { data: authData, error: authError } = await admin.auth.getUser(token);
    const user = authData?.user;
    if (authError || !user) return json({ error: "نشست معتبر نیست؛ دوباره وارد پنل مدیریت شوید." }, 401);

    const [{ data: roles, error: roleError }, { data: profiles, error: profileError }] = await Promise.all([
      admin.from("user_roles").select("role_code").eq("user_id", user.id).eq("role_code", "admin").limit(1),
      admin.from("user_profiles").select("account_status").eq("id", user.id).limit(1),
    ]);
    if (roleError || profileError) throw new Error("بررسی دسترسی مدیر ناموفق بود.");
    if (!roles?.length || profiles?.[0]?.account_status !== "active") return json({ error: "فقط مدیر فعال سامانه مجاز به بارگذاری تصویر است." }, 403);

    const form = await req.formData();
    const file = form.get("file");
    if (!(file instanceof File)) return json({ error: "فایل تصویر دریافت نشد." }, 400);
    const extension = ALLOWED.get(file.type);
    if (!extension) return json({ error: "فقط تصاویر JPG، PNG و WebP مجاز هستند." }, 415);
    if (file.size <= 0 || file.size > MAX_FILE_SIZE) return json({ error: "حجم تصویر باید کمتر از ۴ مگابایت باشد." }, 413);

    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!validImageSignature(bytes, file.type)) return json({ error: "محتوای فایل با نوع تصویر اعلام‌شده مطابقت ندارد." }, 415);

    const { data: buckets, error: bucketsError } = await admin.storage.listBuckets();
    if (bucketsError) throw new Error("بررسی فضای ذخیره‌سازی تصاویر ناموفق بود.");
    if (!buckets?.some((bucket) => bucket.name === BUCKET)) {
      const { error: createError } = await admin.storage.createBucket(BUCKET, {
        public: true,
        fileSizeLimit: MAX_FILE_SIZE,
        allowedMimeTypes: [...ALLOWED.keys()],
      });
      if (createError && !String(createError.message || "").toLowerCase().includes("already")) throw new Error("ایجاد فضای تصاویر ناموفق بود.");
    }

    const path = "products/" + crypto.randomUUID() + "." + extension;
    const { error: uploadError } = await admin.storage.from(BUCKET).upload(path, bytes, {
      contentType: file.type,
      cacheControl: "31536000",
      upsert: false,
    });
    if (uploadError) throw new Error("ذخیره تصویر انجام نشد.");
    const { data: publicData } = admin.storage.from(BUCKET).getPublicUrl(path);
    return json({ ok: true, path, publicUrl: publicData.publicUrl });
  } catch (error) {
    console.error("company-product-image-upload error", error);
    return json({ error: error instanceof Error ? error.message : "بارگذاری تصویر انجام نشد." }, 500);
  }
});
