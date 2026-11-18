-- Enforce case attachment limits for the private case-files bucket.
-- Applied to the linked Supabase project on 2026-11-18.

update storage.buckets
set file_size_limit = 1048576,
    allowed_mime_types = array[
      'image/jpeg',
      'image/png',
      'image/webp',
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    ]
where id = 'case-files';

create or replace function app_private.enforce_case_file_upload_limits()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_case_id text;
  v_file_size bigint;
  v_existing_count bigint;
  v_existing_bytes bigint;
begin
  if new.bucket_id <> 'case-files' then
    return new;
  end if;

  v_case_id := (storage.foldername(new.name))[1];
  if v_case_id is null or v_case_id = '' then
    raise exception 'پرونده پیوست معتبر نیست.';
  end if;

  v_file_size := coalesce(
    nullif(new.metadata->>'size', '')::bigint,
    nullif(new.metadata->>'contentLength', '')::bigint
  );
  if v_file_size is null then
    raise exception 'اندازه فایل قابل تشخیص نیست.';
  end if;
  if v_file_size > 1048576 then
    raise exception 'حداکثر حجم هر فایل ۱ مگابایت است.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(v_case_id));

  select count(*),
         coalesce(sum(coalesce(nullif(metadata->>'size', '')::bigint, 0)), 0)
    into v_existing_count, v_existing_bytes
  from storage.objects
  where bucket_id = 'case-files'
    and (storage.foldername(name))[1] = v_case_id;

  if v_existing_count >= 10 then
    raise exception 'حداکثر ۱۰ فایل برای هر پرونده مجاز است.';
  end if;

  if v_existing_bytes + v_file_size > 10485760 then
    raise exception 'حجم مجموع مدارک هر پرونده نمی‌تواند از ۱۰ مگابایت بیشتر شود.';
  end if;

  return new;
end;
$$;

revoke all on function app_private.enforce_case_file_upload_limits() from public, anon, authenticated;

drop trigger if exists enforce_case_file_upload_limits on storage.objects;
create trigger enforce_case_file_upload_limits
before insert on storage.objects
for each row
execute function app_private.enforce_case_file_upload_limits();
