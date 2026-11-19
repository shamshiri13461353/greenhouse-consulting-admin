-- Atomic grower request submission and quote identifier for customer acceptance.
create or replace function app_private.submit_service_request(
  p_greenhouse_id uuid,p_crop_cycle_id uuid,p_case_id uuid,p_items jsonb,p_customer_note text default null
)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare
  v_item jsonb; v_service_id uuid; v_quantity numeric(12,3);
  v_service_group text; v_requires_case boolean; v_requires_sample boolean;
  v_request_group text; v_distinct_groups integer:=0; v_has_bundle boolean:=false;
  v_request_id uuid;
begin
  if auth.uid() is null or not app_private.has_role('grower') then
    raise exception 'فقط گلخانه‌دار فعال می‌تواند درخواست خدمات ثبت کند' using errcode='42501';
  end if;
  if not app_private.owns_greenhouse(p_greenhouse_id) then
    raise exception 'این گلخانه متعلق به حساب شما نیست' using errcode='42501';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>20 then
    raise exception 'فهرست خدمات انتخاب‌شده معتبر نیست' using errcode='22023';
  end if;
  if length(coalesce(p_customer_note,''))>5000 then
    raise exception 'توضیحات درخواست بیش از حد مجاز است' using errcode='22023';
  end if;
  if p_crop_cycle_id is not null and not exists (
    select 1 from public.crop_cycles c where c.id=p_crop_cycle_id and c.greenhouse_id=p_greenhouse_id
  ) then raise exception 'دوره کشت انتخاب‌شده با گلخانه مطابقت ندارد' using errcode='22023'; end if;
  if p_case_id is not null and not exists (
    select 1 from public.cases c where c.id=p_case_id and c.crop_cycle_id=p_crop_cycle_id and c.created_by=auth.uid()
  ) then raise exception 'پرونده مشاوره انتخاب‌شده معتبر نیست' using errcode='22023'; end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_service_id:=(v_item->>'service_id')::uuid;
    v_quantity:=coalesce((v_item->>'quantity')::numeric,1);
    if v_quantity<=0 or v_quantity>10000 then
      raise exception 'تعداد هر خدمت باید بین صفر و ۱۰۰۰۰ باشد' using errcode='22023';
    end if;
    select s.service_group,s.requires_case,s.requires_sample
      into v_service_group,v_requires_case,v_requires_sample
    from public.services s where s.id=v_service_id and s.is_active=true;
    if not found then raise exception 'یکی از خدمات انتخاب‌شده در حال حاضر قابل ثبت نیست' using errcode='22023'; end if;
    if v_requires_case and p_case_id is null then
      raise exception 'برای مشاوره تخصصی، انتخاب پرونده مشاوره مرتبط الزامی است' using errcode='22023';
    end if;
    if v_requires_sample and p_crop_cycle_id is null then
      raise exception 'برای خدمات آزمایشگاهی، انتخاب دوره کشت الزامی است' using errcode='22023';
    end if;
    if v_service_group='bundle' then v_has_bundle:=true; end if;
  end loop;

  select count(distinct s.service_group) into v_distinct_groups
  from jsonb_array_elements(p_items) j
  join public.services s on s.id=(j.value->>'service_id')::uuid
  where s.is_active=true;

  if v_has_bundle or v_distinct_groups>1 then
    v_request_group:='bundle';
  else
    select s.service_group into v_request_group
    from jsonb_array_elements(p_items) j
    join public.services s on s.id=(j.value->>'service_id')::uuid limit 1;
  end if;

  insert into public.service_requests(created_by,greenhouse_id,crop_cycle_id,case_id,request_group,customer_note)
  values(auth.uid(),p_greenhouse_id,p_crop_cycle_id,p_case_id,v_request_group,nullif(btrim(p_customer_note),''))
  returning id into v_request_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_service_id:=(v_item->>'service_id')::uuid;
    v_quantity:=coalesce((v_item->>'quantity')::numeric,1);
    insert into public.service_request_selections(request_id,service_id,quantity)
    values(v_request_id,v_service_id,v_quantity)
    on conflict(request_id,service_id)
    do update set quantity=service_request_selections.quantity+excluded.quantity;
  end loop;
  return v_request_id;
end;
$function$;

revoke all on function app_private.submit_service_request(uuid,uuid,uuid,jsonb,text) from public,anon;
grant execute on function app_private.submit_service_request(uuid,uuid,uuid,jsonb,text) to authenticated,service_role;

create or replace function public.submit_service_request(
 p_greenhouse_id uuid,p_crop_cycle_id uuid,p_case_id uuid,p_items jsonb,p_customer_note text default null
)
returns uuid language sql security invoker set search_path = ''
as $function$ select app_private.submit_service_request(p_greenhouse_id,p_crop_cycle_id,p_case_id,p_items,p_customer_note); $function$;
revoke all on function public.submit_service_request(uuid,uuid,uuid,jsonb,text) from public,anon;
grant execute on function public.submit_service_request(uuid,uuid,uuid,jsonb,text) to authenticated;

revoke select on public.service_request_quote_versions from authenticated;
grant select (id,request_id,version_no,final_amount,currency_code,status,issued_at,approved_at)
  on public.service_request_quote_versions to authenticated;

drop view public.service_request_customer_quotes;
create view public.service_request_customer_quotes with (security_barrier=true,security_invoker=true)
as select q.id,q.request_id,q.version_no,q.final_amount,q.currency_code,q.status,q.issued_at,q.approved_at
from public.service_request_quote_versions q where q.status in ('issued','accepted');
grant select on public.service_request_customer_quotes to authenticated;
