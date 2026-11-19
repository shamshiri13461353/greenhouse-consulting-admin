create index if not exists lab_result_revisions_analyte_idx on public.lab_result_revisions(analyte_id);
create index if not exists lab_result_revisions_changed_by_idx on public.lab_result_revisions(changed_by);
create index if not exists lab_result_revisions_new_unit_idx on public.lab_result_revisions(new_unit_id);
create index if not exists lab_result_revisions_old_unit_idx on public.lab_result_revisions(old_unit_id);
