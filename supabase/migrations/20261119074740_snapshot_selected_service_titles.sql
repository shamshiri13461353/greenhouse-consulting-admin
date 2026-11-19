alter table public.service_request_selections
  add column if not exists service_code_snapshot text,
  add column if not exists service_title_snapshot text;

update public.service_request_selections ss
set service_code_snapshot=s.code,service_title_snapshot=s.title_fa
from public.services s
where s.id=ss.service_id and (ss.service_code_snapshot is null or ss.service_title_snapshot is null);

alter table public.service_request_selections
  alter column service_code_snapshot set not null,
  alter column service_title_snapshot set not null;

create or replace function app_private.snapshot_service_request_selection()
returns trigger language plpgsql set search_path = ''
as $function$
begin
  select s.code,s.title_fa into new.service_code_snapshot,new.service_title_snapshot
  from public.services s where s.id=new.service_id and s.is_active=true for share;
  if not found then raise exception 'خدمت انتخاب‌شده دیگر فعال نیست' using errcode='22023'; end if;
  return new;
end;
$function$;

drop trigger if exists service_request_selection_snapshot on public.service_request_selections;
create trigger service_request_selection_snapshot before insert on public.service_request_selections
for each row execute function app_private.snapshot_service_request_selection();

comment on column public.service_request_selections.service_title_snapshot is 'نام خدمت در زمان ثبت درخواست؛ تغییر یا غیرفعال‌شدن فهرست خدمات بر سوابق قبلی اثر نمی‌گذارد.';
