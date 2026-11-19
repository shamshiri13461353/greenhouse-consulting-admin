ALTER TABLE public.user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_phone_key;

CREATE UNIQUE INDEX IF NOT EXISTS user_profiles_phone_active_unique
  ON public.user_profiles (phone)
  WHERE phone IS NOT NULL AND account_status <> 'disabled';
