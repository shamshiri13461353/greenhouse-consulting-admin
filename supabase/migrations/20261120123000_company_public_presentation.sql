-- Public company presentation content, managed by active administrators.
create table if not exists public.company_public_profile (
  id boolean primary key default true check (id = true),
  company_name text not null default 'پیوندگستر پارسان',
  short_intro text not null default '',
  history text not null default '',
  mission text not null default '',
  activities text not null default '',
  capabilities text not null default '',
  achievements text not null default '',
  is_published boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

insert into public.company_public_profile (id)
values (true)
on conflict (id) do nothing;

create table if not exists public.company_team_members (
  id uuid primary key default gen_random_uuid(),
  member_group text not null check (member_group in ('board','expert')),
  full_name text not null,
  position_title text not null default '',
  academic_degree text not null default '',
  academic_title text not null default '',
  specialty text not null default '',
  biography text not null default '',
  photo_url text,
  sort_order integer not null default 0,
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create index if not exists company_team_members_public_order_idx
  on public.company_team_members (member_group, sort_order, created_at)
  where is_published = true;

alter table public.company_public_profile enable row level security;
alter table public.company_team_members enable row level security;

grant select on public.company_public_profile, public.company_team_members to anon, authenticated;
grant insert, update, delete on public.company_public_profile, public.company_team_members to authenticated;
grant all on public.company_public_profile, public.company_team_members to service_role;

drop policy if exists company_public_profile_public_read on public.company_public_profile;
create policy company_public_profile_public_read
  on public.company_public_profile for select to anon
  using (is_published = true);

drop policy if exists company_public_profile_authenticated_read on public.company_public_profile;
create policy company_public_profile_authenticated_read
  on public.company_public_profile for select to authenticated
  using (is_published = true or (select app_private.has_role('admin')));

drop policy if exists company_public_profile_admin_manage on public.company_public_profile;
create policy company_public_profile_admin_manage
  on public.company_public_profile for all to authenticated
  using ((select app_private.has_role('admin')))
  with check ((select app_private.has_role('admin')));

drop policy if exists company_team_members_public_read on public.company_team_members;
create policy company_team_members_public_read
  on public.company_team_members for select to anon
  using (is_published = true);

drop policy if exists company_team_members_authenticated_read on public.company_team_members;
create policy company_team_members_authenticated_read
  on public.company_team_members for select to authenticated
  using (is_published = true or (select app_private.has_role('admin')));

drop policy if exists company_team_members_admin_manage on public.company_team_members;
create policy company_team_members_admin_manage
  on public.company_team_members for all to authenticated
  using ((select app_private.has_role('admin')))
  with check ((select app_private.has_role('admin')));
