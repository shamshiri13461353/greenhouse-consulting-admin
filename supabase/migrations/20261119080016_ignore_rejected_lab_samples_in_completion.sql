create or replace function app_private.sync_service_request_lab_review()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_request_id uuid;v_expected text[];v_has_all_expected boolean;v_all_approved boolean;v_sample_count integer;
begin
  if new.approval_status<>'approved' then return new; end if;
  select s.service_request_id into v_request_id from public.lab_samples s where s.id=new.sample_id;
  if v_request_id is null then return new; end if;
  v_expected:=app_private.expected_lab_sample_types(v_request_id);
  select count(*) into v_sample_count from public.lab_samples s
    where s.service_request_id=v_request_id and s.quality_status not in ('rejected','resampling_required');
  if cardinality(v_expected)>0 then
    select not exists(select 1 from unnest(v_expected) e(sample_type)
      where not exists(select 1 from public.lab_samples s where s.service_request_id=v_request_id
        and s.sample_type::text=e.sample_type and s.quality_status not in ('rejected','resampling_required')))
    into v_has_all_expected;
  else v_has_all_expected:=v_sample_count>0; end if;
  select not exists(select 1 from public.lab_samples s left join public.lab_sample_processing p on p.sample_id=s.id
    where s.service_request_id=v_request_id and s.quality_status not in ('rejected','resampling_required')
      and coalesce(p.approval_status,'pending')<>'approved') into v_all_approved;
  if v_has_all_expected and v_all_approved then
    update public.service_requests set status='awaiting_final_approval',fulfillment_status='awaiting_approval'
    where id=v_request_id and status not in ('completed','cancelled','rejected');
  end if;
  return new;
end;
$function$;

create or replace function app_private.sync_service_request_lab_publication()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_expected text[];v_has_all_expected boolean;v_all_published boolean;v_sample_count integer;
begin
  if new.service_request_id is null or new.report_published_at is null
     or old.report_published_at is not distinct from new.report_published_at then return new; end if;
  v_expected:=app_private.expected_lab_sample_types(new.service_request_id);
  select count(*) into v_sample_count from public.lab_samples s
    where s.service_request_id=new.service_request_id and s.quality_status not in ('rejected','resampling_required');
  if cardinality(v_expected)>0 then
    select not exists(select 1 from unnest(v_expected) e(sample_type)
      where not exists(select 1 from public.lab_samples s where s.service_request_id=new.service_request_id
        and s.sample_type::text=e.sample_type and s.quality_status not in ('rejected','resampling_required')))
    into v_has_all_expected;
  else v_has_all_expected:=v_sample_count>0; end if;
  select not exists(select 1 from public.lab_samples s where s.service_request_id=new.service_request_id
    and s.quality_status not in ('rejected','resampling_required') and s.report_published_at is null)
    into v_all_published;
  if v_has_all_expected and v_all_published then
    update public.service_requests set status='completed',fulfillment_status='completed',completed_at=coalesce(completed_at,now())
    where id=new.service_request_id and status not in ('cancelled','rejected');
  end if;
  return new;
end;
$function$;
