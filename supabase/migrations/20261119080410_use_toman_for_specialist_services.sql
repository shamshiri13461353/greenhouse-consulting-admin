
-- All new specialist-service amounts are stored and processed in toman.
-- Legacy consultation/payment tables remain unchanged to preserve historical currency semantics.

alter table public.services alter column currency_code set default 'IRT';
alter table public.service_requests alter column currency_code set default 'IRT';
alter table public.service_price_versions alter column currency_code set default 'IRT';
alter table public.service_request_quote_versions alter column currency_code set default 'IRT';
alter table public.service_request_payments alter column currency_code set default 'IRT';
alter table public.service_request_allocations alter column currency_code set default 'IRT';
alter table public.service_request_allocation_snapshots alter column currency_code set default 'IRT';
alter table public.financial_ledger_entries alter column currency_code set default 'IRT';
alter table public.service_request_customer_quotes alter column currency_code set default 'IRT';
alter table public.service_request_customer_payments alter column currency_code set default 'IRT';
alter table public.service_request_expert_earnings alter column currency_code set default 'IRT';

update public.services set currency_code='IRT';

create or replace function public.issue_service_request_quote(
  p_request_id uuid,p_items jsonb,p_discount_amount numeric default 0,
  p_currency_code character default 'IRT'::bpchar
)
returns uuid language sql set search_path to ''
as $function$
  select app_private.admin_issue_service_request_quote(p_request_id,p_items,p_discount_amount,p_currency_code);
$function$;

create or replace function app_private.admin_set_service_price(
  p_service_id uuid,p_unit_price numeric,p_activate_after_save boolean default false
)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare
  v_version_no integer;v_now timestamptz:=now();v_new_version_id uuid;
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
  update public.service_price_versions set is_active=false,
    effective_until=greatest(v_now,effective_from+interval '1 microsecond')
    where service_id=p_service_id and is_active=true;
  insert into public.service_price_versions
    (service_id,version_no,unit_price,currency_code,effective_from,is_active,created_by)
  values (p_service_id,v_version_no,p_unit_price,'IRT',v_now,true,auth.uid())
  returning id into v_new_version_id;
  if coalesce(p_activate_after_save,false) then
    update public.services set is_active=true where id=p_service_id;
  end if;
  return v_new_version_id;
end;
$function$;
