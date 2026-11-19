alter table public.company_products
  add column if not exists description_group text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'company_products_description_group_check'
      and conrelid = 'public.company_products'::regclass
  ) then
    alter table public.company_products
      add constraint company_products_description_group_check
      check (description_group is null or description_group = 'behrost');
  end if;
end
$$;

alter table public.company_product_settings
  add column if not exists behrost_shared_description text not null default '';

-- Keep the existing individual description intact while assigning known BehRost
-- products to the shared-description group.
update public.company_products
set description_group = 'behrost',
    updated_at = now()
where description ilike '%بهرست%'
  and description_group is null;

-- Initialize the shared text from the first existing BehRost product only
-- when the setting has not already been populated.
update public.company_product_settings settings
set behrost_shared_description = product.description,
    updated_at = now()
from (
  select description
  from public.company_products
  where description_group = 'behrost'
    and coalesce(description, '') <> ''
  order by sort_order, created_at
  limit 1
) product
where settings.id = true
  and coalesce(settings.behrost_shared_description, '') = '';
