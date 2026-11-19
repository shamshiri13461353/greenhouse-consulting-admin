create sequence if not exists public.lab_sample_code_seq;

create or replace function app_private.admin_receive_lab_samples(
  p_request_id uuid,p_sample_types text[],p_receipt_method text,p_sampled_at date default null,
  p_sampling_location text default null,p_notes text default null,p_analyst_user_id uuid default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  v_request public.service_requests%rowtype; v_type text; v_sample_id uuid; v_sample_code text;
  v_suffix text; v_results jsonb:='[]'::jsonb;
begin
  if auth.uid() is null or not app_private.has_role('admin') then
    raise exception 'فقط مدیر سامانه می‌تواند پذیرش نمونه را ثبت کند' using errcode='42501';
  end if;
  if p_sample_types is null or cardinality(p_sample_types)=0 or cardinality(p_sample_types)>10 then
    raise exception 'نوع نمونه معتبر انتخاب نشده است' using errcode='22023';
  end if;
  if p_receipt_method not in ('in_person','courier','postal','other') then
    raise exception 'روش دریافت نمونه معتبر نیست' using errcode='22023';
  end if;
  if exists(select 1 from unnest(p_sample_types) x group by x having count(*)>1) then
    raise exception 'نوع نمونه تکراری انتخاب شده است' using errcode='22023';
  end if;
  select * into v_request from public.service_requests where id=p_request_id for update;
  if not found then raise exception 'درخواست خدمات پیدا نشد' using errcode='P0002'; end if;
  if v_request.payment_status not in ('paid','not_required') or v_request.status not in ('confirmed','in_progress') then
    raise exception 'پذیرش نمونه پس از تأیید درخواست و تسویه مبلغ خدمت امکان‌پذیر است' using errcode='22023';
  end if;
  if v_request.crop_cycle_id is null then raise exception 'دوره کشت برای این درخواست ثبت نشده است' using errcode='23514'; end if;
  if p_analyst_user_id is not null and not exists(
    select 1 from public.service_request_assignments a
    where a.request_id=p_request_id and a.assigned_user_id=p_analyst_user_id
      and a.assignment_role='lab_analyst' and a.status='active'
  ) then raise exception 'مسئول آزمایشگاه باید ابتدا به این درخواست تخصیص داده شود' using errcode='22023'; end if;

  foreach v_type in array p_sample_types loop
    v_suffix:=case v_type when 'irrigation_water' then 'IW' when 'drainage' then 'DR'
      when 'soil' then 'SO' when 'substrate' then 'SB' when 'plant_tissue' then 'PT'
      when 'nutrient_solution' then 'NS' else 'OT' end;
    v_sample_code:='PG-'||v_request.request_number::text||'-'||v_suffix||'-'||lpad(nextval('public.lab_sample_code_seq')::text,5,'0');
    insert into public.lab_samples
      (greenhouse_id,crop_cycle_id,service_request_id,sample_type,sampled_at,sampling_location,notes,
       recorded_by,sample_code,sample_receipt_method,received_at,quality_status)
    values
      (v_request.greenhouse_id,v_request.crop_cycle_id,p_request_id,v_type::public.sample_type,p_sampled_at,
       nullif(btrim(p_sampling_location),''),nullif(btrim(p_notes),''),auth.uid(),v_sample_code,
       p_receipt_method,now(),'pending')
    returning id into v_sample_id;
    insert into public.lab_sample_processing(sample_id,received_by,analyst_user_id,approval_status,quality_note)
    values(v_sample_id,auth.uid(),p_analyst_user_id,'pending',nullif(btrim(p_notes),'' ));
    insert into public.lab_sample_events(sample_id,event_type,event_status,note_internal,performed_by)
    values(v_sample_id,'received','pending_quality_check',nullif(btrim(p_notes),''),auth.uid());
    v_results:=v_results||jsonb_build_array(jsonb_build_object('sample_id',v_sample_id,'sample_code',v_sample_code,'sample_type',v_type));
  end loop;
  update public.service_requests set status='in_progress',fulfillment_status='sample_received' where id=p_request_id;
  return v_results;
end;
$function$;
revoke all on function app_private.admin_receive_lab_samples(uuid,text[],text,date,text,text,uuid) from public,anon;
grant execute on function app_private.admin_receive_lab_samples(uuid,text[],text,date,text,text,uuid) to authenticated,service_role;

create or replace function public.receive_lab_samples(
 p_request_id uuid,p_sample_types text[],p_receipt_method text,p_sampled_at date default null,
 p_sampling_location text default null,p_notes text default null,p_analyst_user_id uuid default null
)
returns jsonb language sql security invoker set search_path = ''
as $function$
 select app_private.admin_receive_lab_samples(p_request_id,p_sample_types,p_receipt_method,p_sampled_at,p_sampling_location,p_notes,p_analyst_user_id);
$function$;
revoke all on function public.receive_lab_samples(uuid,text[],text,date,text,text,uuid) from public,anon;
grant execute on function public.receive_lab_samples(uuid,text[],text,date,text,text,uuid) to authenticated;
