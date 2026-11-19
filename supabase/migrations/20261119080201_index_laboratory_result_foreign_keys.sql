create index if not exists analytes_default_unit_idx on public.analytes(default_unit_id);
create index if not exists lab_results_analyte_idx on public.lab_results(analyte_id);
create index if not exists lab_results_unit_idx on public.lab_results(unit_id);
