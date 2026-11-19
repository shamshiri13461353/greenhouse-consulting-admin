create table if not exists public.company_products (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 160),
  description text not null default '' check (char_length(description) <= 5000),
  image_url text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists company_products_active_order_idx on public.company_products (is_active, sort_order, created_at);
create table if not exists public.company_product_settings (
  id boolean primary key default true check (id = true),
  distribution_coming_soon_text text not null default 'به‌زودی' check (char_length(btrim(distribution_coming_soon_text)) between 1 and 120),
  updated_at timestamptz not null default now()
);
insert into public.company_product_settings (id, distribution_coming_soon_text) values (true, 'به‌زودی') on conflict (id) do nothing;
alter table public.company_products enable row level security;
alter table public.company_product_settings enable row level security;
grant select, insert, update, delete on public.company_products to authenticated;
grant select, update on public.company_product_settings to authenticated;
drop policy if exists company_products_read_active_or_admin on public.company_products;
create policy company_products_read_active_or_admin on public.company_products for select to authenticated using (is_active or app_private.has_role('admin'));
drop policy if exists company_products_admin_insert on public.company_products;
create policy company_products_admin_insert on public.company_products for insert to authenticated with check (app_private.has_role('admin'));
drop policy if exists company_products_admin_update on public.company_products;
create policy company_products_admin_update on public.company_products for update to authenticated using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
drop policy if exists company_products_admin_delete on public.company_products;
create policy company_products_admin_delete on public.company_products for delete to authenticated using (app_private.has_role('admin'));
drop policy if exists company_product_settings_read_authenticated on public.company_product_settings;
create policy company_product_settings_read_authenticated on public.company_product_settings for select to authenticated using (true);
drop policy if exists company_product_settings_admin_update on public.company_product_settings;
create policy company_product_settings_admin_update on public.company_product_settings for update to authenticated using (app_private.has_role('admin')) with check (app_private.has_role('admin'));
