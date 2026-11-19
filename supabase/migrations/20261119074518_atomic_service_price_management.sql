create or replace function app_private.admin_set_service_price(
  p_service_id uuid,p_unit_price numeric,p_activate_after_save boolean default false
)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare v_version_no integer; v_now timestamptz:=now(); v_new_version_id uuid;
begin
  if auth.uid() is null or not app_private.has_role('admin') then
    raise exception 'اجازه مدیریت تعرفه خدمات وجود ندارد' using errcode='42501';
  end if;
  if p_unit_price is null or p_unit_price<0 then
    raise exception 'مبلغ تعرفه معتبر نیست' using errcode='22023';
  end if;
  perform 1 from public.services where id=p_service_id for update;
  if not found then raise exception 'خدمت موردنظر پیدا نشد' using errcode='P0002'; end if;
  select coalesce(max(version_no),0)+1 into v_version_no
    from public.service_price_versions where service_id=p_service_id;
  update public.service_price_versions
    set is_active=false,effective_until=greatest(v_now,effective_from+interval '1 microsecond')
    where service_id=p_service_id and is_active=true;
  insert into public.service_price_versions
    (service_id,version_no,unit_price,currency_code,effective_from,is_active,created_by)
  values (p_service_id,v_version_no,p_unit_price,'IRR',v_now,true,auth.uid())
  returning id into v_new_version_id;
  if coalesce(p_activate_after_save,false) then
    update public.services set is_active=true where id=p_service_id;
  end if;
  return v_new_version_id;
end;
$function$;

revoke all on function app_private.admin_set_service_price(uuid,numeric,boolean) from public,anon;
grant execute on function app_private.admin_set_service_price(uuid,numeric,boolean) to authenticated,service_role;

create or replace function public.set_service_price(
 p_service_id uuid,p_unit_price numeric,p_activate_after_save boolean default false
)
returns uuid language sql security invoker set search_path = ''
as $function$ select app_private.admin_set_service_price(p_service_id,p_unit_price,p_activate_after_save); $function$;
revoke all on function public.set_service_price(uuid,numeric,boolean) from public,anon;
grant execute on function public.set_service_price(uuid,numeric,boolean) to authenticated;
