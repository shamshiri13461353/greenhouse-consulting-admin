alter table public.service_requests
  add constraint service_requests_id_crop_cycle_id_key unique(id,crop_cycle_id);

do $$
begin
  if not exists (select 1 from pg_constraint where conname='lab_samples_service_request_crop_cycle_fkey' and conrelid='public.lab_samples'::regclass) then
    alter table public.lab_samples add constraint lab_samples_service_request_crop_cycle_fkey
      foreign key (service_request_id,crop_cycle_id)
      references public.service_requests(id,crop_cycle_id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname='lab_samples_service_request_requires_cycle_check' and conrelid='public.lab_samples'::regclass) then
    alter table public.lab_samples add constraint lab_samples_service_request_requires_cycle_check
      check (service_request_id is null or crop_cycle_id is not null);
  end if;
end $$;

create index if not exists lab_samples_service_request_crop_cycle_idx
  on public.lab_samples(service_request_id,crop_cycle_id)
  where service_request_id is not null;

create or replace function app_private.validate_service_request_lab_sample()
returns trigger language plpgsql set search_path = ''
as $function$
declare v_allowed boolean;
begin
  if new.service_request_id is null then return new; end if;
  if new.crop_cycle_id is null then
    raise exception 'نمونه مرتبط با درخواست خدمات باید به دوره کشت متصل باشد' using errcode='23514';
  end if;
  select exists (
    select 1 from public.service_request_selections ss
    where ss.request_id=new.service_request_id and (
      (ss.service_code_snapshot='irrigation_water_drainage_analysis' and new.sample_type::text in ('irrigation_water','drainage'))
      or (ss.service_code_snapshot='soil_analysis' and new.sample_type::text='soil')
      or (ss.service_code_snapshot='substrate_analysis' and new.sample_type::text='substrate')
      or (ss.service_code_snapshot='plant_tissue_analysis' and new.sample_type::text='plant_tissue')
      or (ss.service_code_snapshot='combined_lab_nutrition' and new.sample_type::text in
        ('irrigation_water','drainage','soil','substrate','plant_tissue','nutrient_solution','other'))
    )
  ) into v_allowed;
  if not v_allowed then
    raise exception 'نوع نمونه با خدمات انتخاب‌شده در این درخواست مطابقت ندارد' using errcode='23514';
  end if;
  return new;
end;
$function$;

drop trigger if exists lab_samples_validate_service_request on public.lab_samples;
create trigger lab_samples_validate_service_request
before insert or update of service_request_id,crop_cycle_id,sample_type
on public.lab_samples for each row
execute function app_private.validate_service_request_lab_sample();

comment on constraint lab_samples_service_request_crop_cycle_fkey on public.lab_samples is 'دوره کشت نمونه باید دقیقاً با دوره کشت درخواست خدمات یکسان باشد.';
