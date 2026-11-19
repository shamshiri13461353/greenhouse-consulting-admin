-- Customer selections and controlled quote/payment lifecycle.
create table if not exists public.service_request_selections (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  quantity numeric(12,3) not null default 1 check (quantity > 0),
  selection_note text null,
  created_at timestamptz not null default now(),
  constraint service_request_selections_unique unique(request_id,service_id)
);
create index if not exists service_request_selections_request_idx on public.service_request_selections(request_id);

alter table public.service_request_items
  add column if not exists quote_version_id uuid null
  references public.service_request_quote_versions(id) on delete restrict;
create index if not exists service_request_items_quote_version_idx
  on public.service_request_items(quote_version_id) where quote_version_id is not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='service_request_quote_versions_final_amount_check' and conrelid='public.service_request_quote_versions'::regclass) then
    alter table public.service_request_quote_versions add constraint service_request_quote_versions_final_amount_check
      check (final_amount = round(subtotal_amount - discount_amount,2));
  end if;
end $$;

alter table public.service_request_selections enable row level security;
create policy service_request_selections_select_owner_admin on public.service_request_selections
for select to authenticated
using (app_private.has_role('admin') or exists(
  select 1 from public.service_requests r where r.id=request_id and r.created_by=(select auth.uid())
));
create policy service_request_selections_insert_owner on public.service_request_selections
for insert to authenticated
with check (exists(
  select 1 from public.service_requests r join public.services s on s.id=service_id
  where r.id=request_id and r.created_by=(select auth.uid()) and r.status='submitted'
    and s.is_active=true and (not s.requires_case or r.case_id is not null)
));
grant select,insert on public.service_request_selections to authenticated;

grant insert,update on public.service_price_versions to authenticated;
grant insert,update on public.service_allocation_rules to authenticated;
grant select,insert,update,delete on public.service_cost_components to authenticated;
grant insert,update on public.service_request_assignments to authenticated;
grant insert,update on public.service_request_reviews to authenticated;
grant insert,update on public.service_request_adjustments to authenticated;

create policy service_request_reviews_assigned_insert on public.service_request_reviews
for insert to authenticated
with check (reviewer_user_id=(select auth.uid()) and app_private.is_assigned_service_staff(request_id));

create or replace function app_private.sync_service_request_quote()
returns trigger language plpgsql set search_path = ''
as $function$
begin
  if new.status='issued' and (tg_op='INSERT' or old.status is distinct from 'issued') then
    update public.service_request_quote_versions set status='superseded'
    where request_id=new.request_id and id<>new.id and status='issued';
    update public.service_requests
    set status='quoted',final_amount=new.final_amount,currency_code=new.currency_code,
        quoted_at=coalesce(new.issued_at,now())
    where id=new.request_id;
  end if;
  return new;
end;
$function$;
drop trigger if exists service_request_quote_sync on public.service_request_quote_versions;
create trigger service_request_quote_sync after insert or update of status
on public.service_request_quote_versions for each row
execute function app_private.sync_service_request_quote();

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
  v_subtotal numeric(14,2):=0;
  v_discount numeric(14,2):=coalesce(p_discount_amount,0);
  v_version_no integer;
  v_quote_id uuid;
begin
  if auth.uid() is null or not app_private.has_role('admin') then
    raise exception 'اجازه ثبت پیش‌فاکتور وجود ندارد' using errcode='42501';
  end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then
    raise exception 'فهرست خدمات معتبر نیست' using errcode='22023';
  end if;
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
    select pv.id,pv.unit_price,pv.currency_code into v_price_version_id,v_unit_price,v_service_currency
    from public.services s join public.service_price_versions pv on pv.service_id=s.id
    where s.id=v_service_id and s.is_active=true and pv.is_active=true
      and pv.effective_from<=now() and (pv.effective_until is null or pv.effective_until>now());
    if not found then raise exception 'برای یکی از خدمات تعرفه فعال تعریف نشده است' using errcode='22023'; end if;
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
  values (p_request_id,v_version_no,v_subtotal,v_discount,round(v_subtotal-v_discount,2),p_currency_code,'draft',auth.uid())
  returning id into v_quote_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_service_id:=(v_item->>'service_id')::uuid;
    v_quantity:=coalesce((v_item->>'quantity')::numeric,1);
    select s.code,s.title_fa,pv.id,pv.unit_price into v_code,v_title,v_price_version_id,v_unit_price
    from public.services s join public.service_price_versions pv on pv.service_id=s.id
    where s.id=v_service_id and s.is_active=true and pv.is_active=true
      and pv.effective_from<=now() and (pv.effective_until is null or pv.effective_until>now());
    insert into public.service_request_items
      (request_id,quote_version_id,service_id,price_version_id,item_code_snapshot,item_title_snapshot,
       quantity,unit_price_snapshot,discount_amount_snapshot,final_amount_snapshot)
    values (p_request_id,v_quote_id,v_service_id,v_price_version_id,v_code,v_title,
       v_quantity,v_unit_price,0,round(v_quantity*v_unit_price,2));
  end loop;

  update public.service_request_quote_versions set status='issued',issued_at=now() where id=v_quote_id;
  return v_quote_id;
end;
$function$;

revoke all on function app_private.admin_issue_service_request_quote(uuid,jsonb,numeric,char) from public,anon;
grant execute on function app_private.admin_issue_service_request_quote(uuid,jsonb,numeric,char) to authenticated,service_role;

create or replace function public.issue_service_request_quote(
 p_request_id uuid,p_items jsonb,p_discount_amount numeric default 0,p_currency_code char(3) default 'IRR'
)
returns uuid language sql security invoker set search_path = ''
as $function$
 select app_private.admin_issue_service_request_quote(p_request_id,p_items,p_discount_amount,p_currency_code);
$function$;
revoke all on function public.issue_service_request_quote(uuid,jsonb,numeric,char) from public,anon;
grant execute on function public.issue_service_request_quote(uuid,jsonb,numeric,char) to authenticated;

create or replace function app_private.accept_service_request_quote(p_quote_id uuid)
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare v_request_id uuid; v_final_amount numeric(14,2);
begin
  if auth.uid() is null then raise exception 'ابتدا وارد سامانه شوید' using errcode='42501'; end if;
  select q.request_id,q.final_amount into v_request_id,v_final_amount
  from public.service_request_quote_versions q join public.service_requests r on r.id=q.request_id
  where q.id=p_quote_id and q.status='issued' and r.created_by=auth.uid() and r.status='quoted'
  for update of q,r;
  if not found then raise exception 'پیش‌فاکتور معتبر یا قابل تأیید نیست' using errcode='22023'; end if;
  update public.service_request_quote_versions set status='accepted',approved_at=now() where id=p_quote_id;
  update public.service_requests
  set status=case when v_final_amount=0 then 'confirmed' else 'awaiting_payment' end,
      payment_status=case when v_final_amount=0 then 'not_required' else 'pending' end,
      customer_approved_at=now(),paid_at=case when v_final_amount=0 then now() else null end,
      fulfillment_status=case when request_group in ('laboratory','bundle') then 'sample_pending' else fulfillment_status end
  where id=v_request_id;
  return v_request_id;
end;
$function$;
revoke all on function app_private.accept_service_request_quote(uuid) from public,anon;
grant execute on function app_private.accept_service_request_quote(uuid) to authenticated,service_role;

create or replace function public.accept_service_request_quote(p_quote_id uuid)
returns uuid language sql security invoker set search_path = ''
as $function$ select app_private.accept_service_request_quote(p_quote_id); $function$;
revoke all on function public.accept_service_request_quote(uuid) from public,anon;
grant execute on function public.accept_service_request_quote(uuid) to authenticated;

create or replace function app_private.sync_service_request_payment()
returns trigger language plpgsql set search_path = ''
as $function$
begin
  if new.status='succeeded' then
    update public.service_requests set payment_status='paid',
      status=case when status in ('awaiting_payment','quoted') then 'confirmed' else status end,
      paid_at=coalesce(paid_at,new.gateway_verified_at,now()),
      fulfillment_status=case when request_group in ('laboratory','bundle') and fulfillment_status='not_started' then 'sample_pending' else fulfillment_status end
    where id=new.request_id;
  elsif new.status='failed' then
    update public.service_requests set payment_status='failed' where id=new.request_id and payment_status<>'paid';
  elsif new.status='refunded' then
    update public.service_requests set payment_status='refunded' where id=new.request_id;
  elsif new.status='partially_refunded' then
    update public.service_requests set payment_status='partially_refunded' where id=new.request_id;
  end if;
  return new;
end;
$function$;
drop trigger if exists service_request_payment_sync on public.service_request_payments;
create trigger service_request_payment_sync after insert or update of status
on public.service_request_payments for each row execute function app_private.sync_service_request_payment();

comment on table public.service_request_selections is 'انتخاب خدمات توسط گلخانه‌دار؛ بدون دسترسی به قیمت‌های داخلی.';
comment on function public.accept_service_request_quote(uuid) is 'تأیید پیش‌فاکتور فقط توسط مالک درخواست؛ مبلغ نهایی به‌صورت شفاف نمایش داده می‌شود.';
comment on function public.issue_service_request_quote(uuid,jsonb,numeric,char) is 'صدور پیش‌فاکتور با کنترل نقش مدیر و snapshot تعرفه‌های فعال.';
