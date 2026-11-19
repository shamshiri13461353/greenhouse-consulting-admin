-- Secure service-request reads with invoker views and column-level customer access.
drop policy if exists service_request_items_admin on public.service_request_items;
create policy service_request_items_select_participants on public.service_request_items
for select to authenticated
using (app_private.has_role('admin')
  or exists(select 1 from public.service_requests r where r.id=request_id and r.created_by=(select auth.uid()))
  or app_private.is_assigned_service_staff(request_id));

drop policy if exists service_request_quote_versions_admin on public.service_request_quote_versions;
create policy service_request_quote_versions_select_owner_admin on public.service_request_quote_versions
for select to authenticated
using (app_private.has_role('admin')
  or exists(select 1 from public.service_requests r where r.id=request_id and r.created_by=(select auth.uid())));

drop policy if exists service_request_assignments_admin_write on public.service_request_assignments;
create policy service_request_assignments_admin_insert on public.service_request_assignments
for insert to authenticated with check (app_private.has_role('admin'));
create policy service_request_assignments_admin_update on public.service_request_assignments
for update to authenticated using (app_private.has_role('admin')) with check (app_private.has_role('admin'));

drop policy if exists service_request_reviews_admin_write on public.service_request_reviews;
create policy service_request_reviews_admin_insert on public.service_request_reviews
for insert to authenticated with check (app_private.has_role('admin'));
create policy service_request_reviews_admin_update on public.service_request_reviews
for update to authenticated using (app_private.has_role('admin')) with check (app_private.has_role('admin'));

revoke select on public.service_request_items from authenticated;
grant select (request_id,item_code_snapshot,item_title_snapshot,quantity)
  on public.service_request_items to authenticated;

revoke select on public.service_request_quote_versions from authenticated;
grant select (request_id,version_no,final_amount,currency_code,status,issued_at,approved_at)
  on public.service_request_quote_versions to authenticated;

revoke select on public.service_request_payments from authenticated;
grant select (request_id,amount,currency_code,status,gateway_code,created_at,gateway_verified_at)
  on public.service_request_payments to authenticated;

create or replace view public.service_request_customer_items
with (security_barrier=true, security_invoker=true)
as select i.request_id,i.item_code_snapshot,i.item_title_snapshot,i.quantity
from public.service_request_items i;

create or replace view public.service_request_customer_quotes
with (security_barrier=true, security_invoker=true)
as select q.request_id,q.version_no,q.final_amount,q.currency_code,q.status,q.issued_at,q.approved_at
from public.service_request_quote_versions q where q.status in ('issued','accepted');

create or replace view public.service_request_customer_payments
with (security_barrier=true, security_invoker=true)
as select p.request_id,p.amount,p.currency_code,p.status,p.gateway_code,p.created_at,p.gateway_verified_at
from public.service_request_payments p;

create or replace view public.service_request_expert_earnings
with (security_barrier=true, security_invoker=true)
as select a.request_id,a.amount,a.currency_code,a.status,a.created_at
from public.service_request_allocations a
where a.beneficiary_type='expert' and a.beneficiary_user_id=(select auth.uid());

create or replace view public.service_request_admin_financials
with (security_barrier=true, security_invoker=true)
as select r.id as request_id,r.request_number,r.final_amount,r.currency_code,
coalesce(sum(c.total_cost),0)::numeric(14,2) as internal_cost_total
from public.service_requests r left join public.service_cost_components c on c.request_id=r.id
where app_private.has_role('admin')
group by r.id,r.request_number,r.final_amount,r.currency_code;
