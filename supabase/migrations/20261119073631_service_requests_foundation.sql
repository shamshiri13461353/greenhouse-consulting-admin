-- Applied to Supabase project tnf... on 2026-11-19.
-- General service-request foundation. Existing consultation/payment tables are retained.
create sequence if not exists public.service_request_number_seq;

alter table public.services
  add column if not exists service_group text not null default 'consultation',
  add column if not exists requires_case boolean not null default false,
  add column if not exists requires_sample boolean not null default false,
  add column if not exists is_bundle boolean not null default false;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='services_service_group_check' and conrelid='public.services'::regclass) then
    alter table public.services add constraint services_service_group_check
      check (service_group in ('consultation','laboratory','nutrition','bundle'));
  end if;
end $$;

insert into public.services
(code,title_fa,description,base_price,currency_code,is_active,service_group,requires_case,requires_sample,is_bundle)
values
('consultation_case','مشاوره تخصصی گلخانه‌ای','بررسی تخصصی موردی مسائل گلخانه و ارائه راهکار.',0,'IRR',false,'consultation',true,false,false),
('irrigation_water_drainage_analysis','تجزیه آب آبیاری و زهاب','تجزیه مستقل آب آبیاری و زهاب برای مقایسه ورودی و زهکش.',0,'IRR',false,'laboratory',false,true,false),
('soil_analysis','تجزیه خاک','تجزیه آزمایشگاهی نمونه خاک.',0,'IRR',false,'laboratory',false,true,false),
('substrate_analysis','تجزیه بستر کشت','تجزیه آزمایشگاهی بستر کشت.',0,'IRR',false,'laboratory',false,true,false),
('plant_tissue_analysis','تجزیه برگ و بافت گیاهی','تجزیه عناصر غذایی برگ و بافت گیاهی.',0,'IRR',false,'laboratory',false,true,false),
('nutrition_recommendation','توصیه تغذیه‌ای و برنامه کوددهی','تفسیر داده‌ها و ارائه توصیه تغذیه‌ای و برنامه کوددهی.',0,'IRR',false,'nutrition',false,false,false),
('combined_lab_nutrition','بسته ترکیبی آزمایش، تفسیر و توصیه','خدمت ترکیبی آزمایش، تفسیر تخصصی و توصیه تغذیه‌ای.',0,'IRR',false,'bundle',false,true,true)
on conflict (code) do nothing;

create table if not exists public.service_requests (
  id uuid primary key default gen_random_uuid(),
  request_number bigint not null default nextval('public.service_request_number_seq'),
  created_by uuid not null references public.user_profiles(id) on delete restrict,
  greenhouse_id uuid not null references public.greenhouses(id) on delete restrict,
  crop_cycle_id uuid null,
  case_id uuid null,
  request_group text not null default 'laboratory'
    check (request_group in ('consultation','laboratory','nutrition','bundle')),
  status text not null default 'submitted'
    check (status in ('submitted','under_review','quoted','awaiting_customer_approval','awaiting_payment','confirmed','in_progress','awaiting_final_approval','completed','cancelled','rejected')),
  payment_status text not null default 'not_required'
    check (payment_status in ('not_required','pending','paid','failed','partially_refunded','refunded')),
  fulfillment_status text not null default 'not_started'
    check (fulfillment_status in ('not_started','sample_pending','sample_received','analysis_in_progress','interpretation_in_progress','awaiting_approval','released','completed','cancelled')),
  dispute_status text not null default 'none'
    check (dispute_status in ('none','open','under_review','resolved','rejected')),
  final_amount numeric(14,2) null check (final_amount is null or final_amount >= 0),
  currency_code char(3) not null default 'IRR',
  customer_note text null,
  submitted_at timestamptz not null default now(),
  quoted_at timestamptz null,
  customer_approved_at timestamptz null,
  paid_at timestamptz null,
  completed_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint service_requests_request_number_key unique (request_number),
  constraint service_requests_case_requires_crop_cycle check (case_id is null or crop_cycle_id is not null)
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname='crop_cycles_id_greenhouse_id_key' and conrelid='public.crop_cycles'::regclass) then
    alter table public.crop_cycles add constraint crop_cycles_id_greenhouse_id_key unique (id,greenhouse_id);
  end if;
  if not exists (select 1 from pg_constraint where conname='cases_id_crop_cycle_id_key' and conrelid='public.cases'::regclass) then
    alter table public.cases add constraint cases_id_crop_cycle_id_key unique (id,crop_cycle_id);
  end if;
  if not exists (select 1 from pg_constraint where conname='service_requests_crop_cycle_greenhouse_fkey' and conrelid='public.service_requests'::regclass) then
    alter table public.service_requests add constraint service_requests_crop_cycle_greenhouse_fkey
      foreign key (crop_cycle_id,greenhouse_id) references public.crop_cycles(id,greenhouse_id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname='service_requests_case_crop_cycle_fkey' and conrelid='public.service_requests'::regclass) then
    alter table public.service_requests add constraint service_requests_case_crop_cycle_fkey
      foreign key (case_id,crop_cycle_id) references public.cases(id,crop_cycle_id) on delete restrict;
  end if;
end $$;

create table if not exists public.service_price_versions (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete restrict,
  version_no integer not null check (version_no > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  currency_code char(3) not null default 'IRR',
  effective_from timestamptz not null default now(),
  effective_until timestamptz null,
  is_active boolean not null default false,
  created_by uuid null references public.user_profiles(id) on delete set null,
  notes text null,
  created_at timestamptz not null default now(),
  constraint service_price_versions_service_version_key unique(service_id,version_no),
  constraint service_price_versions_dates_check check (effective_until is null or effective_until > effective_from)
);
create unique index if not exists service_price_versions_one_active_idx on public.service_price_versions(service_id) where is_active;
create index if not exists service_price_versions_service_idx on public.service_price_versions(service_id);

create table if not exists public.service_allocation_rules (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete restrict,
  rule_code text not null,
  beneficiary_type text not null check (beneficiary_type in ('company','expert','laboratory')),
  percentage numeric(7,4) null check (percentage is null or (percentage >= 0 and percentage <= 100)),
  fixed_amount numeric(14,2) null check (fixed_amount is null or fixed_amount >= 0),
  calculation_basis text not null,
  effective_from timestamptz not null default now(),
  effective_until timestamptz null,
  is_active boolean not null default false,
  created_by uuid null references public.user_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint service_allocation_rules_rule_code_key unique(service_id,rule_code),
  constraint service_allocation_rules_value_check check (percentage is not null or fixed_amount is not null),
  constraint service_allocation_rules_dates_check check (effective_until is null or effective_until > effective_from)
);
create index if not exists service_allocation_rules_service_idx on public.service_allocation_rules(service_id);

create table if not exists public.service_request_items (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  price_version_id uuid null references public.service_price_versions(id) on delete restrict,
  item_code_snapshot text not null,
  item_title_snapshot text not null,
  quantity numeric(12,3) not null default 1 check (quantity > 0),
  unit_price_snapshot numeric(14,2) not null check (unit_price_snapshot >= 0),
  discount_amount_snapshot numeric(14,2) not null default 0 check (discount_amount_snapshot >= 0),
  final_amount_snapshot numeric(14,2) not null check (final_amount_snapshot >= 0),
  created_at timestamptz not null default now(),
  constraint service_request_items_discount_limit check (discount_amount_snapshot <= quantity * unit_price_snapshot),
  constraint service_request_items_total_check check (final_amount_snapshot = round(quantity * unit_price_snapshot - discount_amount_snapshot,2))
);
create index if not exists service_request_items_request_idx on public.service_request_items(request_id);
create index if not exists service_request_items_service_idx on public.service_request_items(service_id);

create table if not exists public.service_request_quote_versions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete restrict,
  version_no integer not null check (version_no > 0),
  subtotal_amount numeric(14,2) not null check (subtotal_amount >= 0),
  discount_amount numeric(14,2) not null default 0 check (discount_amount >= 0),
  final_amount numeric(14,2) not null check (final_amount >= 0),
  currency_code char(3) not null default 'IRR',
  status text not null default 'draft' check (status in ('draft','issued','accepted','rejected','superseded','expired')),
  notes_internal text null,
  created_by uuid null references public.user_profiles(id) on delete set null,
  issued_at timestamptz null,
  approved_at timestamptz null,
  created_at timestamptz not null default now(),
  constraint service_request_quote_versions_amount_check check (discount_amount <= subtotal_amount),
  constraint service_request_quote_versions_request_version_key unique(request_id,version_no)
);
create unique index if not exists service_request_quote_versions_one_issued_idx on public.service_request_quote_versions(request_id) where status='issued';
create index if not exists service_request_quote_versions_request_idx on public.service_request_quote_versions(request_id);

create table if not exists public.service_cost_components (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete restrict,
  request_id uuid null references public.service_requests(id) on delete restrict,
  component_code text not null,
  title_internal text not null,
  cost_category text not null check (cost_category in ('materials','labor','depreciation','quality_control','interpretation','overhead','other')),
  quantity numeric(12,3) not null default 1 check (quantity >= 0),
  unit_cost numeric(14,2) not null check (unit_cost >= 0),
  total_cost numeric(14,2) generated always as (round(quantity * unit_cost,2)) stored,
  is_actual boolean not null default false,
  created_by uuid null references public.user_profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists service_cost_components_service_idx on public.service_cost_components(service_id);
create index if not exists service_cost_components_request_idx on public.service_cost_components(request_id);

create table if not exists public.service_request_assignments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  assigned_user_id uuid not null references public.user_profiles(id) on delete restrict,
  assignment_role text not null check (assignment_role in ('expert','lab_analyst','reviewer','manager')),
  status text not null default 'active' check (status in ('active','completed','removed')),
  assigned_by uuid null references public.user_profiles(id) on delete set null,
  assigned_at timestamptz not null default now(),
  completed_at timestamptz null,
  created_at timestamptz not null default now(),
  constraint service_request_assignments_unique unique(request_id,assigned_user_id,assignment_role)
);
create index if not exists service_request_assignments_user_idx on public.service_request_assignments(assigned_user_id,status);
create index if not exists service_request_assignments_request_idx on public.service_request_assignments(request_id,status);

create table if not exists public.service_request_reviews (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  reviewer_user_id uuid not null references public.user_profiles(id) on delete restrict,
  review_type text not null check (review_type in ('sample_intake','analysis_results','interpretation','final_report','dispute')),
  decision text not null check (decision in ('approved','rejected','changes_requested')),
  comments text null,
  created_at timestamptz not null default now()
);
create index if not exists service_request_reviews_request_idx on public.service_request_reviews(request_id,created_at desc);

create table if not exists public.service_request_payments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete restrict,
  gateway_code text not null,
  gateway_transaction_id text null,
  amount numeric(14,2) not null check (amount > 0),
  currency_code char(3) not null default 'IRR',
  status text not null default 'pending' check (status in ('pending','succeeded','failed','refunded','partially_refunded')),
  gateway_verified_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists service_request_payments_gateway_txn_idx on public.service_request_payments(gateway_code,gateway_transaction_id) where gateway_transaction_id is not null;
create index if not exists service_request_payments_request_idx on public.service_request_payments(request_id);

create table if not exists public.service_payment_gateway_events (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.service_request_payments(id) on delete restrict,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now()
);
create index if not exists service_payment_gateway_events_payment_idx on public.service_payment_gateway_events(payment_id,received_at desc);

create table if not exists public.service_request_allocations (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete restrict,
  allocation_rule_id uuid null references public.service_allocation_rules(id) on delete restrict,
  beneficiary_type text not null check (beneficiary_type in ('company','expert','laboratory')),
  beneficiary_user_id uuid null references public.user_profiles(id) on delete restrict,
  amount numeric(14,2) not null check (amount >= 0),
  currency_code char(3) not null default 'IRR',
  calculation_basis jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','payable','paid','cancelled')),
  created_at timestamptz not null default now(),
  constraint service_request_allocations_beneficiary_check check ((beneficiary_type='expert' and beneficiary_user_id is not null) or (beneficiary_type in ('company','laboratory')))
);
create index if not exists service_request_allocations_request_idx on public.service_request_allocations(request_id);
create index if not exists service_request_allocations_beneficiary_idx on public.service_request_allocations(beneficiary_user_id,status);

create table if not exists public.financial_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  request_id uuid null references public.service_requests(id) on delete restrict,
  allocation_id uuid null references public.service_request_allocations(id) on delete restrict,
  entry_type text not null check (entry_type in ('customer_receipt','company_revenue','expert_earning','laboratory_revenue','operating_cost','refund','adjustment','settlement')),
  direction text not null check (direction in ('debit','credit')),
  amount numeric(14,2) not null check (amount > 0),
  currency_code char(3) not null default 'IRR',
  beneficiary_type text null check (beneficiary_type is null or beneficiary_type in ('company','expert','laboratory')),
  beneficiary_user_id uuid null references public.user_profiles(id) on delete restrict,
  idempotency_key text not null unique,
  description_internal text null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid null references public.user_profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists financial_ledger_entries_request_idx on public.financial_ledger_entries(request_id,created_at);
create index if not exists financial_ledger_entries_beneficiary_idx on public.financial_ledger_entries(beneficiary_user_id,created_at);

create table if not exists public.settlement_items (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.settlements(id) on delete restrict,
  ledger_entry_id uuid not null references public.financial_ledger_entries(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  constraint settlement_items_pair_unique unique(settlement_id,ledger_entry_id)
);
create index if not exists settlement_items_settlement_idx on public.settlement_items(settlement_id);
create index if not exists settlement_items_ledger_idx on public.settlement_items(ledger_entry_id);

create table if not exists public.service_request_adjustments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete restrict,
  adjustment_type text not null check (adjustment_type in ('discount','refund','additional_charge','waiver','credit')),
  amount numeric(14,2) not null check (amount >= 0),
  reason_internal text not null,
  status text not null default 'proposed' check (status in ('proposed','approved','rejected','applied')),
  created_by uuid not null references public.user_profiles(id) on delete restrict,
  approved_by uuid null references public.user_profiles(id) on delete restrict,
  approved_at timestamptz null,
  applied_at timestamptz null,
  created_at timestamptz not null default now()
);
create index if not exists service_request_adjustments_request_idx on public.service_request_adjustments(request_id);

create table if not exists public.service_request_disputes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete restrict,
  submitted_by uuid not null references public.user_profiles(id) on delete restrict,
  category text not null check (category in ('service_quality','delay','billing','report','other')),
  description text not null,
  status text not null default 'open' check (status in ('open','under_review','resolved','rejected')),
  resolution_internal text null,
  resolved_by uuid null references public.user_profiles(id) on delete set null,
  resolved_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists service_request_disputes_request_idx on public.service_request_disputes(request_id,status);

create or replace function app_private.set_service_updated_at()
returns trigger language plpgsql set search_path = ''
as $function$
begin new.updated_at := now(); return new; end;
$function$;

create trigger service_requests_set_updated_at before update on public.service_requests
for each row execute function app_private.set_service_updated_at();
create trigger service_request_payments_set_updated_at before update on public.service_request_payments
for each row execute function app_private.set_service_updated_at();
create trigger service_request_disputes_set_updated_at before update on public.service_request_disputes
for each row execute function app_private.set_service_updated_at();

create or replace function app_private.is_assigned_service_staff(p_request_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select p_request_id is not null and exists (
    select 1 from public.service_request_assignments a
    join public.user_profiles up on up.id=a.assigned_user_id
    where a.request_id=p_request_id and a.assigned_user_id=auth.uid()
      and a.status='active' and up.account_status='active'
  );
$function$;

create or replace function app_private.can_access_service_request(p_request_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (select 1 from public.service_requests r where r.id=p_request_id
    and (r.created_by=auth.uid() or app_private.has_role('admin') or app_private.is_assigned_service_staff(r.id)));
$function$;

revoke all on function app_private.is_assigned_service_staff(uuid) from public,anon;
revoke all on function app_private.can_access_service_request(uuid) from public,anon;
grant execute on function app_private.is_assigned_service_staff(uuid) to authenticated,service_role;
grant execute on function app_private.can_access_service_request(uuid) to authenticated,service_role;

alter table public.service_requests enable row level security;
alter table public.service_price_versions enable row level security;
alter table public.service_allocation_rules enable row level security;
alter table public.service_request_items enable row level security;
alter table public.service_request_quote_versions enable row level security;
alter table public.service_cost_components enable row level security;
alter table public.service_request_assignments enable row level security;
alter table public.service_request_reviews enable row level security;
alter table public.service_request_payments enable row level security;
alter table public.service_payment_gateway_events enable row level security;
alter table public.service_request_allocations enable row level security;
alter table public.financial_ledger_entries enable row level security;
alter table public.settlement_items enable row level security;
alter table public.service_request_adjustments enable row level security;
alter table public.service_request_disputes enable row level security;

create policy service_requests_select_participants on public.service_requests for select to authenticated
using (created_by=(select auth.uid()) or app_private.has_role('admin') or app_private.is_assigned_service_staff(id));
create policy service_requests_insert_owner on public.service_requests for insert to authenticated
with check (created_by=(select auth.uid()) and app_private.has_role('grower') and app_private.owns_greenhouse(greenhouse_id)
  and (crop_cycle_id is null or exists(select 1 from public.crop_cycles cc where cc.id=crop_cycle_id and cc.greenhouse_id=greenhouse_id)));
create policy service_requests_admin_update on public.service_requests for update to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));

create policy service_price_versions_admin on public.service_price_versions for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_allocation_rules_admin on public.service_allocation_rules for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_request_items_admin on public.service_request_items for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_request_quote_versions_admin on public.service_request_quote_versions for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_cost_components_admin on public.service_cost_components for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_request_assignments_select_private on public.service_request_assignments for select to authenticated
using (app_private.has_role('admin') or assigned_user_id=(select auth.uid()));
create policy service_request_assignments_admin_write on public.service_request_assignments for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_request_reviews_select_staff on public.service_request_reviews for select to authenticated
using (app_private.has_role('admin') or reviewer_user_id=(select auth.uid()) or app_private.is_assigned_service_staff(request_id));
create policy service_request_reviews_admin_write on public.service_request_reviews for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_request_payments_select_owner_admin on public.service_request_payments for select to authenticated
using (app_private.has_role('admin') or exists(select 1 from public.service_requests r where r.id=request_id and r.created_by=(select auth.uid())));
create policy service_payment_gateway_events_admin on public.service_payment_gateway_events for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_request_allocations_select_beneficiary on public.service_request_allocations for select to authenticated
using (app_private.has_role('admin') or (beneficiary_type='expert' and beneficiary_user_id=(select auth.uid())));
create policy financial_ledger_entries_admin on public.financial_ledger_entries for select to authenticated
using (app_private.has_role('admin'));
create policy settlement_items_admin on public.settlement_items for select to authenticated
using (app_private.has_role('admin'));
create policy service_request_adjustments_admin on public.service_request_adjustments for all to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
create policy service_request_disputes_select_owner_admin on public.service_request_disputes for select to authenticated
using (app_private.has_role('admin') or submitted_by=(select auth.uid()));
create policy service_request_disputes_insert_owner on public.service_request_disputes for insert to authenticated
with check (submitted_by=(select auth.uid()) and status='open'
  and exists(select 1 from public.service_requests r where r.id=request_id and r.created_by=(select auth.uid())));
create policy service_request_disputes_admin_update on public.service_request_disputes for update to authenticated
using (app_private.has_role('admin')) with check (app_private.has_role('admin'));

grant usage,select on sequence public.service_request_number_seq to authenticated,service_role;
grant select,insert,update on public.service_requests to authenticated;
grant select on public.service_request_assignments,public.service_request_reviews,public.service_request_payments,
 public.service_request_allocations,public.service_request_disputes to authenticated;
grant insert on public.service_request_disputes to authenticated;
grant update on public.service_request_disputes to authenticated;
grant select on public.service_price_versions,public.service_allocation_rules,public.service_request_items,
 public.service_request_quote_versions,public.service_cost_components,public.service_payment_gateway_events,
 public.financial_ledger_entries,public.settlement_items,public.service_request_adjustments to authenticated;

create or replace view public.service_request_customer_items with (security_barrier=true)
as select i.request_id,i.item_code_snapshot,i.item_title_snapshot,i.quantity
from public.service_request_items i join public.service_requests r on r.id=i.request_id
where r.created_by=(select auth.uid()) or app_private.has_role('admin');

create or replace view public.service_request_customer_quotes with (security_barrier=true)
as select q.request_id,q.version_no,q.final_amount,q.currency_code,q.status,q.issued_at,q.approved_at
from public.service_request_quote_versions q join public.service_requests r on r.id=q.request_id
where (r.created_by=(select auth.uid()) or app_private.has_role('admin')) and q.status in ('issued','accepted');

create or replace view public.service_request_customer_payments with (security_barrier=true)
as select p.request_id,p.amount,p.currency_code,p.status,p.gateway_code,p.created_at,p.gateway_verified_at
from public.service_request_payments p join public.service_requests r on r.id=p.request_id
where r.created_by=(select auth.uid()) or app_private.has_role('admin');

create or replace view public.service_request_expert_earnings with (security_barrier=true)
as select a.request_id,a.amount,a.currency_code,a.status,a.created_at
from public.service_request_allocations a
where a.beneficiary_type='expert' and a.beneficiary_user_id=(select auth.uid());

create or replace view public.service_request_admin_financials with (security_barrier=true)
as select r.id as request_id,r.request_number,r.final_amount,r.currency_code,
coalesce(sum(c.total_cost),0)::numeric(14,2) as internal_cost_total
from public.service_requests r left join public.service_cost_components c on c.request_id=r.id
where app_private.has_role('admin')
group by r.id,r.request_number,r.final_amount,r.currency_code;

grant select on public.service_request_customer_items,public.service_request_customer_quotes,
 public.service_request_customer_payments,public.service_request_expert_earnings,
 public.service_request_admin_financials to authenticated;

comment on table public.service_requests is 'درخواست‌های عمومی خدمات تخصصی؛ وضعیت درخواست، پرداخت، انجام خدمت و اعتراض مستقل نگهداری می‌شوند.';
comment on table public.service_request_items is 'اقلام و قیمت‌های snapshot شده؛ فقط مدیر از طریق دسترسی داخلی مشاهده می‌کند.';
comment on table public.service_cost_components is 'بهای تمام‌شده محرمانه؛ فقط مدیر مجاز به مشاهده است.';
comment on table public.financial_ledger_entries is 'دفتر مالی رویدادمحور؛ اصلاحات با سند جدید ثبت شوند و رکوردها ویرایش یا حذف نشوند.';
