create or replace function app_private.can_send_case_message(
  p_case_id uuid,
  p_sender_role text,
  p_recipient_user_id uuid,
  p_recipient_role text
)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null
     or p_case_id is null
     or p_recipient_user_id is null
     or p_recipient_user_id = v_uid
     or p_sender_role is null
     or p_recipient_role is null then
    return false;
  end if;

  if p_sender_role = 'grower'
     and app_private.has_role('grower')
     and app_private.is_case_owner(p_case_id) then
    if p_recipient_role = 'admin' then
      return exists (
        select 1
        from public.user_roles ur
        join public.user_profiles up on up.id = ur.user_id
        where ur.user_id = p_recipient_user_id
          and ur.role_code = 'admin'
          and up.account_status = 'active'
      );
    elsif p_recipient_role = 'expert' then
      return exists (
        select 1
        from public.case_assignments ca
        join public.expert_profiles ep on ep.user_id = ca.expert_user_id
        join public.user_profiles up on up.id = ep.user_id
        join public.user_roles ur on ur.user_id = ep.user_id
        where ca.case_id = p_case_id
          and ca.expert_user_id = p_recipient_user_id
          and ca.status = 'active'
          and ep.is_verified = true
          and ep.invitation_status = 'accepted'
          and up.account_status = 'active'
          and ur.role_code = 'expert'
      );
    end if;
  elsif p_sender_role = 'expert'
        and app_private.has_role('expert')
        and app_private.is_assigned_expert(p_case_id) then
    if p_recipient_role = 'admin' then
      return exists (
        select 1
        from public.user_roles ur
        join public.user_profiles up on up.id = ur.user_id
        where ur.user_id = p_recipient_user_id
          and ur.role_code = 'admin'
          and up.account_status = 'active'
      );
    elsif p_recipient_role = 'grower' then
      return exists (
        select 1
        from public.cases cs
        join public.crop_cycles cc on cc.id = cs.crop_cycle_id
        join public.greenhouses gh on gh.id = cc.greenhouse_id
        join public.user_profiles up on up.id = gh.owner_user_id
        where cs.id = p_case_id
          and gh.owner_user_id = p_recipient_user_id
          and up.account_status = 'active'
      );
    end if;
  elsif p_sender_role = 'admin'
        and app_private.has_role('admin') then
    if p_recipient_role = 'expert' then
      return exists (
        select 1
        from public.case_assignments ca
        join public.expert_profiles ep on ep.user_id = ca.expert_user_id
        join public.user_profiles up on up.id = ep.user_id
        join public.user_roles ur on ur.user_id = ep.user_id
        where ca.case_id = p_case_id
          and ca.expert_user_id = p_recipient_user_id
          and ca.status = 'active'
          and ep.is_verified = true
          and ep.invitation_status = 'accepted'
          and up.account_status = 'active'
          and ur.role_code = 'expert'
      );
    elsif p_recipient_role = 'grower' then
      return exists (
        select 1
        from public.cases cs
        join public.crop_cycles cc on cc.id = cs.crop_cycle_id
        join public.greenhouses gh on gh.id = cc.greenhouse_id
        join public.user_profiles up on up.id = gh.owner_user_id
        where cs.id = p_case_id
          and gh.owner_user_id = p_recipient_user_id
          and up.account_status = 'active'
      );
    end if;
  end if;

  return false;
end;
$function$;

revoke all on function app_private.can_send_case_message(uuid,text,uuid,text) from public, anon;
grant execute on function app_private.can_send_case_message(uuid,text,uuid,text) to authenticated;

drop policy if exists messages_insert_directed_participant on public.case_messages;

create policy messages_insert_directed_participant
on public.case_messages
for insert
to authenticated
with check (
  sender_user_id = (select auth.uid())
  and is_official = true
  and recipient_user_id is not null
  and recipient_user_id <> sender_user_id
  and app_private.can_send_case_message(
    case_id,
    sender_role,
    recipient_user_id,
    recipient_role
  )
);
