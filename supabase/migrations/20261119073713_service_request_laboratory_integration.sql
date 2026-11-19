-- Add sample receipt, laboratory processing and immutable event history to service requests.
alter table public.service_requests
  add constraint service_requests_id_greenhouse_id_key unique(id,greenhouse_id);

alter table public.lab_samples
  add column if not exists service_request_id uuid null,
  add column if not exists sample_code text null,
  add column if not exists sample_receipt_method text null,
  add column if not exists received_at timestamptz null,
  add column if not exists quality_status text not null default 'pending',
  add column if not exists report_published_at timestamptz null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='lab_samples_service_request_greenhouse_fkey' and conrelid='public.lab_samples'::regclass) then
    alter table public.lab_samples add constraint lab_samples_service_request_greenhouse_fkey
      foreign key (service_request_id,greenhouse_id)
      references public.service_requests(id,greenhouse_id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname='lab_samples_receipt_method_check' and conrelid='public.lab_samples'::regclass) then
    alter table public.lab_samples add constraint lab_samples_receipt_method_check
      check (sample_receipt_method is null or sample_receipt_method in ('in_person','courier','postal','other'));
  end if;
  if not exists (select 1 from pg_constraint where conname='lab_samples_quality_status_check' and conrelid='public.lab_samples'::regclass) then
    alter table public.lab_samples add constraint lab_samples_quality_status_check
      check (quality_status in ('pending','accepted','rejected','resampling_required'));
  end if;
end $$;

create unique index if not exists lab_samples_sample_code_unique_idx on public.lab_samples(sample_code) where sample_code is not null;
create index if not exists lab_samples_service_request_idx on public.lab_samples(service_request_id) where service_request_id is not null;

create table if not exists public.lab_sample_processing (
  sample_id uuid primary key references public.lab_samples(id) on delete cascade,
  received_by uuid null references public.user_profiles(id) on delete set null,
  analyst_user_id uuid null references public.user_profiles(id) on delete set null,
  analysis_method text null,
  quality_note text null,
  reviewed_by uuid null references public.user_profiles(id) on delete set null,
  reviewed_at timestamptz null,
  approval_status text not null default 'pending'
    check (approval_status in ('pending','approved','rejected','changes_requested')),
  updated_at timestamptz not null default now()
);

create table if not exists public.lab_sample_events (
  id uuid primary key default gen_random_uuid(),
  sample_id uuid not null references public.lab_samples(id) on delete restrict,
  event_type text not null check (event_type in ('received','quality_check','analysis_started','analysis_completed','interpretation_completed','reviewed','report_published','report_corrected')),
  event_status text null,
  note_internal text null,
  performed_by uuid not null references public.user_profiles(id) on delete restrict,
  occurred_at timestamptz not null default now()
);
create index if not exists lab_sample_events_sample_idx on public.lab_sample_events(sample_id,occurred_at desc);

create or replace function app_private.can_process_lab_sample(p_sample_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists(select 1 from public.lab_samples s where s.id=p_sample_id
    and (app_private.has_role('admin')
      or (s.service_request_id is not null and app_private.is_assigned_service_staff(s.service_request_id))
      or (s.case_id is not null and app_private.is_assigned_expert(s.case_id))));
$function$;

create or replace function app_private.can_access_lab_sample(p_sample_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists(select 1 from public.lab_samples s where s.id=p_sample_id
    and (app_private.has_role('admin')
      or app_private.owns_greenhouse(s.greenhouse_id)
      or (s.case_id is not null and app_private.can_access_case(s.case_id))
      or (s.service_request_id is not null and app_private.is_assigned_service_staff(s.service_request_id))));
$function$;

revoke all on function app_private.can_process_lab_sample(uuid) from public,anon;
grant execute on function app_private.can_process_lab_sample(uuid) to authenticated,service_role;

drop policy if exists lab_samples_insert_authorized on public.lab_samples;
create policy lab_samples_insert_authorized on public.lab_samples
for insert to authenticated
with check (recorded_by=(select auth.uid()) and (
  app_private.has_role('admin')
  or (service_request_id is null and app_private.owns_greenhouse(greenhouse_id))
  or (case_id is not null and app_private.is_assigned_expert(case_id))
  or (service_request_id is not null and app_private.is_assigned_service_staff(service_request_id))
));

drop policy if exists lab_samples_select_authorized on public.lab_samples;
create policy lab_samples_select_authorized on public.lab_samples
for select to authenticated
using (app_private.has_role('admin') or app_private.owns_greenhouse(greenhouse_id)
  or (case_id is not null and app_private.can_access_case(case_id))
  or (service_request_id is not null and app_private.is_assigned_service_staff(service_request_id)));

drop policy if exists lab_samples_update_staff on public.lab_samples;
create policy lab_samples_update_staff on public.lab_samples
for update to authenticated
using (app_private.has_role('admin')
  or (case_id is not null and app_private.is_assigned_expert(case_id))
  or (service_request_id is not null and app_private.is_assigned_service_staff(service_request_id)))
with check (app_private.has_role('admin')
  or (case_id is not null and app_private.is_assigned_expert(case_id))
  or (service_request_id is not null and app_private.is_assigned_service_staff(service_request_id)));

drop policy if exists lab_results_insert_authorized on public.lab_results;
create policy lab_results_insert_authorized on public.lab_results
for insert to authenticated
with check (app_private.has_role('admin') or exists (
  select 1 from public.lab_samples s where s.id=lab_results.sample_id and (
    (s.service_request_id is not null and app_private.is_assigned_service_staff(s.service_request_id))
    or (s.case_id is not null and app_private.is_assigned_expert(s.case_id))
    or (s.service_request_id is null and s.case_id is null and app_private.owns_greenhouse(s.greenhouse_id))
  )
));

alter table public.lab_sample_processing enable row level security;
alter table public.lab_sample_events enable row level security;

create policy lab_sample_processing_staff_select on public.lab_sample_processing
for select to authenticated using (app_private.can_process_lab_sample(sample_id));
create policy lab_sample_processing_staff_insert on public.lab_sample_processing
for insert to authenticated with check (app_private.can_process_lab_sample(sample_id));
create policy lab_sample_processing_staff_update on public.lab_sample_processing
for update to authenticated using (app_private.can_process_lab_sample(sample_id))
with check (app_private.can_process_lab_sample(sample_id));

create policy lab_sample_events_staff_select on public.lab_sample_events
for select to authenticated using (app_private.can_process_lab_sample(sample_id));
create policy lab_sample_events_staff_insert on public.lab_sample_events
for insert to authenticated
with check (performed_by=(select auth.uid()) and app_private.can_process_lab_sample(sample_id));

grant select,insert,update on public.lab_sample_processing to authenticated;
grant select,insert on public.lab_sample_events to authenticated;

comment on column public.lab_samples.sample_type is 'برای آب، irrigation_water و drainage به‌صورت دو نوع نمونه مستقل ثبت شوند؛ عنوان رابط کاربری: تجزیه آب آبیاری و زهاب.';
comment on column public.lab_samples.service_request_id is 'درخواست خدمات تخصصی مرتبط با این نمونه.';
comment on table public.lab_sample_processing is 'اطلاعات داخلی پذیرش، کنترل کیفیت، روش تجزیه و بازبینی؛ فقط مدیر و کارکنان تخصیص‌یافته.';
comment on table public.lab_sample_events is 'تاریخچه غیرقابل‌ویرایش رویدادهای نمونه برای ردیابی مسئول و زمان انجام.';
