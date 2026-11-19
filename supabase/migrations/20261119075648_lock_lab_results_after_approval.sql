create or replace function app_private.guard_lab_result_writes()
returns trigger language plpgsql set search_path = ''
as $function$
declare v_published_at timestamptz;v_approval_status text;
begin
  select s.report_published_at,p.approval_status into v_published_at,v_approval_status
  from public.lab_samples s left join public.lab_sample_processing p on p.sample_id=s.id
  where s.id=new.sample_id;
  if v_published_at is not null then
    raise exception 'نتایج پس از انتشار گزارش قفل می‌شوند' using errcode='55000';
  end if;
  if v_approval_status='approved' then
    raise exception 'پس از تأیید تخصصی، نتایج قفل می‌شوند' using errcode='55000';
  end if;
  return new;
end;
$function$;
drop trigger if exists lab_result_write_guard on public.lab_results;
create trigger lab_result_write_guard before insert or update on public.lab_results
for each row execute function app_private.guard_lab_result_writes();

create or replace function app_private.sync_service_request_lab_analysis_progress()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_request_id uuid;
begin
  select s.service_request_id into v_request_id from public.lab_samples s where s.id=new.sample_id;
  if v_request_id is not null then
    update public.service_requests
    set status='in_progress',fulfillment_status='analysis_in_progress',completed_at=null
    where id=v_request_id and status not in ('cancelled','rejected');
  end if;
  return new;
end;
$function$;
drop trigger if exists lab_result_sync_request_progress on public.lab_results;
create trigger lab_result_sync_request_progress after insert or update on public.lab_results
for each row execute function app_private.sync_service_request_lab_analysis_progress();

comment on function app_private.guard_lab_result_writes() is 'نتایج پس از تأیید تخصصی یا انتشار گزارش قابل تغییر نیستند.';
