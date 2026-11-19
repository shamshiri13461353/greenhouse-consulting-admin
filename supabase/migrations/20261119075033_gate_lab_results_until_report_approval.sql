create or replace function app_private.can_review_lab_sample(p_sample_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.lab_samples s where s.id=p_sample_id and (
      app_private.has_role('admin')
      or (s.case_id is not null and app_private.is_assigned_expert(s.case_id))
      or (s.service_request_id is not null and exists (
        select 1 from public.service_request_assignments a
        where a.request_id=s.service_request_id and a.assigned_user_id=auth.uid()
          and a.status='active' and a.assignment_role in ('expert','reviewer','manager')
      ))
    )
  );
$function$;
revoke all on function app_private.can_review_lab_sample(uuid) from public,anon;
grant execute on function app_private.can_review_lab_sample(uuid) to authenticated,service_role;

create or replace function app_private.can_access_lab_sample(p_sample_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.lab_samples s where s.id=p_sample_id and (
      app_private.has_role('admin')
      or (s.service_request_id is not null and app_private.is_assigned_service_staff(s.service_request_id))
      or (s.case_id is not null and app_private.is_assigned_expert(s.case_id))
      or (s.report_published_at is not null and (
        app_private.owns_greenhouse(s.greenhouse_id)
        or (s.case_id is not null and app_private.can_access_case(s.case_id))
      ))
    )
  );
$function$;

drop policy if exists lab_results_insert_authorized on public.lab_results;
create policy lab_results_insert_authorized on public.lab_results
for insert to authenticated
with check (
  app_private.has_role('admin')
  or exists (select 1 from public.lab_samples s where s.id=lab_results.sample_id and (
    (s.service_request_id is not null and app_private.is_assigned_service_staff(s.service_request_id))
    or (s.case_id is not null and app_private.is_assigned_expert(s.case_id))
  ))
);

create or replace function app_private.guard_lab_sample_processing_approval()
returns trigger language plpgsql set search_path = ''
as $function$
declare v_approval_changed boolean;
begin
  if tg_op='INSERT' then
    v_approval_changed:=new.approval_status<>'pending' or new.reviewed_by is not null or new.reviewed_at is not null;
  else
    v_approval_changed:=new.approval_status is distinct from old.approval_status
      or new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at;
  end if;
  if v_approval_changed and not app_private.can_review_lab_sample(new.sample_id) then
    raise exception 'فقط مدیر یا متخصص مسئول می‌تواند نتیجه آزمایش را تأیید کند' using errcode='42501';
  end if;
  if new.approval_status='approved' then
    if not app_private.has_role('admin') and new.reviewed_by is not null and new.reviewed_by<>auth.uid() then
      raise exception 'ثبت‌کننده تأیید معتبر نیست' using errcode='42501';
    end if;
    new.reviewed_by:=coalesce(new.reviewed_by,auth.uid());
    new.reviewed_at:=coalesce(new.reviewed_at,now());
  end if;
  return new;
end;
$function$;

drop trigger if exists lab_sample_processing_approval_guard on public.lab_sample_processing;
create trigger lab_sample_processing_approval_guard before insert or update
on public.lab_sample_processing for each row
execute function app_private.guard_lab_sample_processing_approval();

create or replace function app_private.guard_lab_report_publication()
returns trigger language plpgsql set search_path = ''
as $function$
declare v_approved boolean;
begin
  if new.report_published_at is distinct from old.report_published_at
     or new.report_storage_path is distinct from old.report_storage_path then
    if not app_private.has_role('admin') then
      raise exception 'انتشار گزارش آزمایش فقط با مجوز مدیر انجام می‌شود' using errcode='42501';
    end if;
    if new.report_published_at is not null then
      select coalesce(p.approval_status='approved',false) into v_approved
      from public.lab_sample_processing p where p.sample_id=new.id;
      if not coalesce(v_approved,false) then
        raise exception 'گزارش تا پیش از تأیید مدیر یا متخصص مسئول قابل انتشار نیست' using errcode='23514';
      end if;
    end if;
    if new.report_storage_path is not null and new.report_published_at is null then
      raise exception 'مسیر گزارش پیش از انتشار نباید در دسترس قرار گیرد' using errcode='23514';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists lab_sample_report_publication_guard on public.lab_samples;
create trigger lab_sample_report_publication_guard
before update of report_published_at,report_storage_path on public.lab_samples
for each row execute function app_private.guard_lab_report_publication();

comment on function app_private.can_access_lab_sample(uuid) is 'دسترسی مالک گلخانه به نتایج آزمایش فقط پس از انتشار گزارش؛ مدیر و کارکنان تخصیص‌یافته دسترسی کاری دارند.';
comment on table public.lab_sample_processing is 'ثبت پذیرش و تجزیه؛ تأیید نتیجه فقط توسط مدیر یا متخصص مسئول امکان‌پذیر است.';
