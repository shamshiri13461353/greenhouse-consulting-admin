-- Consolidate review insertion authorization and index new foreign-key columns.
drop policy if exists service_request_reviews_admin_insert on public.service_request_reviews;
drop policy if exists service_request_reviews_assigned_insert on public.service_request_reviews;
create policy service_request_reviews_insert_authorized on public.service_request_reviews
for insert to authenticated
with check (
  app_private.has_role('admin')
  or (reviewer_user_id=(select auth.uid()) and app_private.is_assigned_service_staff(request_id))
);

create index if not exists service_requests_created_by_idx on public.service_requests(created_by);
create index if not exists service_requests_greenhouse_idx on public.service_requests(greenhouse_id);
create index if not exists service_requests_crop_cycle_greenhouse_idx on public.service_requests(crop_cycle_id,greenhouse_id);
create index if not exists service_requests_case_crop_cycle_idx on public.service_requests(case_id,crop_cycle_id);
create index if not exists service_price_versions_created_by_idx on public.service_price_versions(created_by);
create index if not exists service_allocation_rules_created_by_idx on public.service_allocation_rules(created_by);
create index if not exists service_request_items_price_version_idx on public.service_request_items(price_version_id);
create index if not exists service_request_quote_versions_created_by_idx on public.service_request_quote_versions(created_by);
create index if not exists service_cost_components_created_by_idx on public.service_cost_components(created_by);
create index if not exists service_request_assignments_assigned_by_idx on public.service_request_assignments(assigned_by);
create index if not exists service_request_reviews_reviewer_idx on public.service_request_reviews(reviewer_user_id);
create index if not exists service_request_selections_service_idx on public.service_request_selections(service_id);
create index if not exists service_request_allocations_rule_idx on public.service_request_allocations(allocation_rule_id);
create index if not exists service_request_adjustments_created_by_idx on public.service_request_adjustments(created_by);
create index if not exists service_request_adjustments_approved_by_idx on public.service_request_adjustments(approved_by);
create index if not exists service_request_disputes_submitted_by_idx on public.service_request_disputes(submitted_by);
create index if not exists service_request_disputes_resolved_by_idx on public.service_request_disputes(resolved_by);
create index if not exists financial_ledger_entries_allocation_idx on public.financial_ledger_entries(allocation_id);
create index if not exists financial_ledger_entries_created_by_idx on public.financial_ledger_entries(created_by);
create index if not exists service_request_allocation_snapshots_rule_idx on public.service_request_allocation_snapshots(allocation_rule_id);
create index if not exists service_request_allocation_snapshots_service_idx on public.service_request_allocation_snapshots(service_id);
create index if not exists lab_sample_events_performed_by_idx on public.lab_sample_events(performed_by);
create index if not exists lab_sample_processing_analyst_idx on public.lab_sample_processing(analyst_user_id);
create index if not exists lab_sample_processing_received_by_idx on public.lab_sample_processing(received_by);
create index if not exists lab_sample_processing_reviewed_by_idx on public.lab_sample_processing(reviewed_by);
create index if not exists lab_samples_laboratory_idx on public.lab_samples(laboratory_id);
create index if not exists lab_samples_recorded_by_idx on public.lab_samples(recorded_by);
create index if not exists lab_samples_service_request_greenhouse_idx on public.lab_samples(service_request_id,greenhouse_id);
