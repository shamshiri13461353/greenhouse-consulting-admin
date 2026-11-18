-- Move final-response approval and publication authority from the expert to the administrator.
alter table public.final_responses
  add column if not exists review_status text not null default 'submitted',
  add column if not exists review_note text;

-- Backfill legacy rows while bypassing the old publication guard; this changes review metadata only.
alter table public.final_responses disable trigger final_response_publish_guard;
update public.final_responses
set review_status = case when is_published then 'approved' else 'submitted' end;
alter table public.final_responses enable trigger final_response_publish_guard;

alter table public.final_responses
  drop constraint if exists final_responses_review_status_check;
alter table public.final_responses
  add constraint final_responses_review_status_check
  check (review_status in ('draft','submitted','changes_requested','approved'));

create or replace function app_private.guard_final_response()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null
       or new.prepared_by is distinct from auth.uid()
       or not app_private.is_lead_expert(new.case_id) then
      raise exception 'only the assigned expert may submit a final response';
    end if;
    if new.is_published then
      raise exception 'experts cannot publish final responses';
    end if;
    new.review_status := 'submitted';
    new.review_note := null;
    new.approved_by := null;
    new.published_at := null;
    return new;
  end if;

  if old.is_published then
    raise exception 'published responses are immutable; create a new version';
  end if;

  if new.id is distinct from old.id
     or new.case_id is distinct from old.case_id
     or new.version is distinct from old.version
     or new.prepared_by is distinct from old.prepared_by then
    raise exception 'response identity fields are immutable';
  end if;

  if new.is_published then
    if auth.uid() is null or not app_private.has_role('admin') then
      raise exception 'only an administrator may publish the final response';
    end if;
    if new.approved_by is distinct from auth.uid()
       or new.review_status <> 'approved' then
      raise exception 'approval must be recorded by the current administrator';
    end if;
    new.published_at := coalesce(new.published_at, now());
    new.review_note := null;
    return new;
  end if;

  new.published_at := null;
  new.approved_by := null;

  if app_private.has_role('admin') then
    if new.response_text is distinct from old.response_text
       or new.recommendations is distinct from old.recommendations
       or new.warnings is distinct from old.warnings then
      raise exception 'administrators may review but may not rewrite expert content';
    end if;
    if new.review_status <> 'changes_requested'
       or nullif(btrim(new.review_note), '') is null then
      raise exception 'administrator must return the response with a correction note';
    end if;
    return new;
  end if;

  if auth.uid() is null
     or auth.uid() is distinct from old.prepared_by
     or not app_private.is_lead_expert(old.case_id) then
    raise exception 'only the assigned expert may edit this response';
  end if;

  if old.review_status not in ('draft','changes_requested')
     or new.review_status <> 'submitted' then
    raise exception 'response is not available for expert editing';
  end if;

  new.review_note := null;
  return new;
end;
$function$;

-- Keep the case lifecycle aligned with the response review lifecycle.
create or replace function app_private.sync_case_status_for_final_response_review()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.is_published then
    return new;
  end if;

  if tg_op = 'INSERT' or new.review_status is distinct from old.review_status then
    if new.review_status = 'submitted' then
      update public.cases
         set status = 'awaiting_final_approval'
       where id = new.case_id
         and status in ('assigned','under_review','awaiting_expert_input');
    elsif new.review_status = 'changes_requested' then
      update public.cases
         set status = 'under_review'
       where id = new.case_id
         and status = 'awaiting_final_approval';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists final_response_sync_review_case_status on public.final_responses;
create trigger final_response_sync_review_case_status
after insert or update of review_status on public.final_responses
for each row execute function app_private.sync_case_status_for_final_response_review();
