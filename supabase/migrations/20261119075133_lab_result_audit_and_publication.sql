create table if not exists public.lab_result_revisions (
  id uuid primary key default gen_random_uuid(),
  result_id uuid not null references public.lab_results(id) on delete restrict,
  sample_id uuid not null references public.lab_samples(id) on delete restrict,
  analyte_id uuid not null references public.analytes(id) on delete restrict,
  old_value_numeric numeric not null,new_value_numeric numeric not null,
  old_unit_id uuid not null references public.units(id) on delete restrict,
  new_unit_id uuid not null references public.units(id) on delete restrict,
  old_detection_limit numeric null,new_detection_limit numeric null,
  old_result_note text null,new_result_note text null,
  change_reason text null,
  changed_by uuid null references public.user_profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);
create index if not exists lab_result_revisions_result_idx on public.lab_result_revisions(result_id,changed_at desc);
create index if not exists lab_result_revisions_sample_idx on public.lab_result_revisions(sample_id,changed_at desc);
alter table public.lab_result_revisions enable row level security;
create policy lab_result_revisions_admin_select on public.lab_result_revisions
for select to authenticated using (app_private.has_role('admin'));
grant select on public.lab_result_revisions to authenticated;

create policy lab_results_admin_update on public.lab_results
for update to authenticated using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
grant update on public.lab_results to authenticated;

create or replace function app_private.audit_lab_result_update()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  insert into public.lab_result_revisions
    (result_id,sample_id,analyte_id,old_value_numeric,new_value_numeric,old_unit_id,new_unit_id,
     old_detection_limit,new_detection_limit,old_result_note,new_result_note,change_reason,changed_by)
  values
    (old.id,old.sample_id,old.analyte_id,old.value_numeric,new.value_numeric,old.unit_id,new.unit_id,
     old.detection_limit,new.detection_limit,old.result_note,new.result_note,
     nullif(current_setting('app.lab_result_change_reason',true),''),auth.uid());
  return new;
end;
$function$;
revoke all on function app_private.audit_lab_result_update() from public,anon;
drop trigger if exists lab_result_update_audit on public.lab_results;
create trigger lab_result_update_audit after update on public.lab_results
for each row execute function app_private.audit_lab_result_update();

create or replace function app_private.sync_service_request_lab_review()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_request_id uuid; v_all_approved boolean;
begin
  if new.approval_status<>'approved' then return new; end if;
  select s.service_request_id into v_request_id from public.lab_samples s where s.id=new.sample_id;
  if v_request_id is null then return new; end if;
  select not exists (
    select 1 from public.lab_samples s
    left join public.lab_sample_processing p on p.sample_id=s.id
    where s.service_request_id=v_request_id and coalesce(p.approval_status,'pending')<>'approved'
  ) into v_all_approved;
  if v_all_approved then
    update public.service_requests set status='awaiting_final_approval',fulfillment_status='awaiting_approval'
    where id=v_request_id and status not in ('completed','cancelled','rejected');
  end if;
  return new;
end;
$function$;
drop trigger if exists lab_sample_processing_sync_request_review on public.lab_sample_processing;
create trigger lab_sample_processing_sync_request_review after insert or update of approval_status
on public.lab_sample_processing for each row execute function app_private.sync_service_request_lab_review();

create or replace function app_private.sync_service_request_lab_publication()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if new.service_request_id is not null and new.report_published_at is not null
     and old.report_published_at is distinct from new.report_published_at then
    if not exists(select 1 from public.lab_samples s
      where s.service_request_id=new.service_request_id and s.report_published_at is null) then
      update public.service_requests
      set status='completed',fulfillment_status='completed',completed_at=coalesce(completed_at,now())
      where id=new.service_request_id and status not in ('cancelled','rejected');
    end if;
  end if;
  return new;
end;
$function$;
drop trigger if exists lab_sample_publication_sync_request on public.lab_samples;
create trigger lab_sample_publication_sync_request after update of report_published_at
on public.lab_samples for each row execute function app_private.sync_service_request_lab_publication();

create or replace view public.service_request_customer_lab_results
with (security_barrier=true,security_invoker=true)
as
select s.service_request_id as request_id,s.id as sample_id,s.sample_code,s.sample_type,s.sampled_at,
 s.report_published_at,a.code as analyte_code,a.title_fa as analyte_title,lr.value_numeric,
 u.code as unit_code,u.title_fa as unit_title,lr.replicate_no,lr.detection_limit,lr.result_note
from public.lab_samples s join public.lab_results lr on lr.sample_id=s.id
join public.analytes a on a.id=lr.analyte_id join public.units u on u.id=lr.unit_id
where s.service_request_id is not null and s.report_published_at is not null;
grant select on public.service_request_customer_lab_results to authenticated;
comment on view public.service_request_customer_lab_results is 'نتایج ساختاریافته آزمایش فقط پس از انتشار گزارش قابل مشاهده است.';
comment on table public.lab_result_revisions is 'تاریخچه تغییرات نتایج آزمایش؛ نسخه قبلی و جدید، زمان و کاربر تغییر‌دهنده ثبت می‌شود.';
