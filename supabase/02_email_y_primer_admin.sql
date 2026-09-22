-- =====================================================================
-- 02 · Email en perfiles + la primera cuenta registrada es admin
-- Pegar entero en Supabase → SQL Editor → Run. Se puede repetir.
-- =====================================================================

alter table public.profiles add column if not exists email text;

-- Al registrarse: guarda el email y, si todavía no hay ningún admin,
-- la cuenta nueva se convierte en admin.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, nombre, email, role)
  values (
    new.id,
    new.raw_user_meta_data->>'nombre',
    new.email,
    case when exists (select 1 from profiles where role = 'admin') then 'residente' else 'admin' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Cuentas que ya existan: rellenar email
update public.profiles p set email = u.email
from auth.users u where u.id = p.id and p.email is null;

-- Si ya hay cuentas pero ningún admin, la más antigua pasa a admin
update public.profiles set role = 'admin'
where not exists (select 1 from public.profiles where role = 'admin')
  and id = (select p.id from public.profiles p join auth.users u on u.id = p.id
            order by u.created_at limit 1);
