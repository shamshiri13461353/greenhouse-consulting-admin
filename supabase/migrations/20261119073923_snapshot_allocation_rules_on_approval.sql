-- Version revenue-sharing rules and snapshot the active rules at customer approval.
alter table public.service_allocation_rules
  add column if not exists version_no integer not null default 1;

alter table public.service_allocation_rules
  drop constraint if exists service_allocation_rules_rule_code_key;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='service_allocation_rules_service_rule_version_key' and conrelid='public.service_allocation_rules'::regclass) then
    alter table public.service_allocation_rules
      add constraint service_allocation_rules_service_rule_version_key
      unique(service_id,rule_code,version_no);
  end if;
end $$;

create table if not exists public.service_request_allocation_snapshots (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  allocation_rule_id uuid not null references public.service_allocation_rules(id) on delete restrict,
  rule_code text not null,
  rule_version_no integer not null,
  beneficiary_type text not null check (beneficiary_type in ('company','expert','laboratory')),
  percentage numeric(7,4) null check (percentage is null or (percentage>=0 and percentage<=100)),
  fixed_amount numeric(14,2) null check (fixed_amount is null or fixed_amount>=0),
  calculation_basis text not null,
  currency_code char(3) not null default 'IRR',
  captured_at timestamptz not null default now(),
  constraint service_request_allocation_snapshots_unique unique(request_id,allocation_rule_id)
);
create index if not exists service_request_allocation_snapshots_request_idx
  on public.service_request_allocation_snapshots(request_id);

alter table public.service_request_allocation_snapshots enable row level security;
create policy service_request_allocation_snapshots_admin_select on public.service_request_allocation_snapshots
for select to authenticated using (app_private.has_role('admin'));
grant select on public.service_request_allocation_snapshots to authenticated;

create or replace function app_private.admin_issue_service_request_quote(
  p_request_id uuid,p_items jsonb,p_discount_amount numeric default 0,p_currency_code char(3) default 'IRR'
)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare
  v_request public.service_requests%rowtype;
  v_item jsonb;
  v_service_id uuid;
  v_quantity numeric(12,3);
  v_price_version_id uuid;
  v_unit_price numeric(14,2);
  v_service_currency char(3);
  v_code text;
  v_title text;
  v_service_group text;
  v_requires_case boolean;
  v_subtotal numeric(14,2):=0;
  v_discount numeric(14,2);
  v_version_no integer;
  v_quote_id uuid;
begin
  if auth.uid() is null or not app_private.has_role('admin') then
    raise exception 'اجازه ثبت پیش‌فاکتور وجود ندارد' using errcode='42501';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'فهرست خدمات معتبر نیست' using errcode='22023';
  end if;
  if jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then
    raise exception 'تعداد اقلام درخواست معتبر نیست' using errcode='22023';
  end if;
  v_discount:=coalesce(p_discount_amount,0);
  if v_discount<0 then raise exception 'مبلغ تخفیف معتبر نیست' using errcode='22023'; end if;

  select * into v_request from public.service_requests where id=p_request_id for update;
  if not found then raise exception 'درخواست پیدا نشد' using errcode='P0002'; end if;
  if v_request.status not in ('submitted','under_review','quoted','awaiting_customer_approval') then
    raise exception 'وضعیت درخواست اجازه صدور پیش‌فاکتور جدید نمی‌دهد' using errcode='22023';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_service_id:=(v_item->>'service_id')::uuid;
    v_quantity:=coalesce((v_item->>'quantity')::numeric,1);
    if v_quantity<=0 then raise exception 'تعداد خدمت باید بیشتر از صفر باشد' using errcode='22023'; end if;

    select s.service_group,s.requires_case,pv.id,pv.unit_price,pv.currency_code
      into v_service_group,v_requires_case,v_price_version_id,v_unit_price,v_service_currency
    from public.services s join public.service_price_versions pv on pv.service_id=s.id
    where s.id=v_service_id and s.is_active=true and pv.is_active=true
      and pv.effective_from<=now() and (pv.effective_until is null or pv.effective_until>now())
    for share of s,pv;

    if not found then raise exception 'برای یکی از خدمات تعرفه فعال تعریف نشده است' using errcode='22023'; end if;
    if v_request.request_group<>'bundle' and v_service_group<>v_request.request_group then
      raise exception 'نوع خدمت با نوع درخواست مطابقت ندارد' using errcode='22023';
    end if;
    if v_requires_case and v_request.case_id is null then
      raise exception 'برای این خدمت باید پرونده مشاوره مرتبط باشد' using errcode='22023';
    end if;
    if v_service_currency<>p_currency_code then raise exception 'واحد پول تعرفه با واحد پول درخواست یکسان نیست' using errcode='22023'; end if;
    v_subtotal:=v_subtotal+round(v_quantity*v_unit_price,2);
  end loop;

  if v_discount>v_subtotal then raise exception 'تخفیف نمی‌تواند از مبلغ خدمات بیشتر باشد' using errcode='22023'; end if;
  select coalesce(max(version_no),0)+1 into v_version_no
    from public.service_request_quote_versions where request_id=p_request_id;
  update public.service_request_quote_versions set status='superseded'
    where request_id=p_request_id and status='issued';

  insert into public.service_request_quote_versions
    (request_id,version_no,subtotal_amount,discount_amount,final_amount,currency_code,status,created_by)
  values
    (p_request_id,v_version_no,v_subtotal,v_discount,round(v_subtotal-v_discount,2),p_currency_code,'draft',auth.uid())
  returning id into v_quote_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_service_id:=(v_item->>'service_id')::uuid;
    v_quantity:=coalesce((v_item->>'quantity')::numeric,1);
    select s.code,s.title_fa,pv.id,pv.unit_price into v_code,v_title,v_price_version_id,v_unit_price
    from public.services s join public.service_price_versions pv on pv.service_id=s.id
    where s.id=v_service_id and s.is_active=true and pv.is_active=true
      and pv.effective_from<=now() and (pv.effective_until is null or pv.effective_until>now())
    for share of s,pv;

    insert into public.service_request_items
      (request_id,quote_version_id,service_id,price_version_id,item_code_snapshot,item_title_snapshot,
       quantity,unit_price_snapshot,discount_amount_snapshot,final_amount_snapshot)
    values
      (p_request_id,v_quote_id,v_service_id,v_price_version_id,v_code,v_title,v_quantity,v_unit_price,0,round(v_quantity*v_unit_price,2));
  end loop;

  update public.service_request_quote_versions set status='issued',issued_at=now() where id=v_quote_id;
  return v_quote_id;
end;
$function$;

create or replace function app_private.accept_service_request_quote(p_quote_id uuid)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare v_request_id uuid; v_final_amount numeric(14,2); v_currency_code char(3);
begin
  if auth.uid() is null then raise exception 'ابتدا وارد سامانه شوید' using errcode='42501'; end if;
  select q.request_id,q.final_amount,q.currency_code into v_request_id,v_final_amount,v_currency_code
  from public.service_request_quote_versions q join public.service_requests r on r.id=q.request_id
  where q.id=p_quote_id and q.status='issued' and r.created_by=auth.uid() and r.status='quoted'
  for update of q,r;
  if not found then raise exception 'پیش‌فاکتور معتبر یا قابل تأیید نیست' using errcode='22023'; end if;

  update public.service_request_quote_versions set status='accepted',approved_at=now() where id=p_quote_id;

  insert into public.service_request_allocation_snapshots
    (request_id,service_id,allocation_rule_id,rule_code,rule_version_no,beneficiary_type,
     percentage,fixed_amount,calculation_basis,currency_code)
  select distinct v_request_id,i.service_id,ar.id,ar.rule_code,ar.version_no,ar.beneficiary_type,
    ar.percentage,ar.fixed_amount,ar.calculation_basis,v_currency_code
  from public.service_request_items i
  join public.service_allocation_rules ar on ar.service_id=i.service_id
  where i.quote_version_id=p_quote_id and ar.is_active=true
    and ar.effective_from<=now() and (ar.effective_until is null or ar.effective_until>now())
  on conflict (request_id,allocation_rule_id) do nothing;

  update public.service_requests
  set status=case when v_final_amount=0 then 'confirmed' else 'awaiting_payment' end,
      payment_status=case when v_final_amount=0 then 'not_required' else 'pending' end,
      customer_approved_at=now(),paid_at=case when v_final_amount=0 then now() else null end,
      fulfillment_status=case when request_group in ('laboratory','bundle') then 'sample_pending' else fulfillment_status end
  where id=v_request_id;
  return v_request_id;
end;
$function$;
