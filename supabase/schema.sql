-- =====================================================================
-- GUARDIAS CARDIOLOGÍA · Esquema de base de datos y permisos
-- Pegar entero en Supabase → SQL Editor → Run. Se puede ejecutar
-- varias veces sin romper nada.
--
-- Reglas:
--   · Cualquiera (incluso sin login) puede VER todo: histórico público.
--   · Admin: asigna guardias, gestiona residentes/reglas, cierra meses.
--   · Residente: SOLO sus solicitudes (días libres / sin guardia) y sus
--     bajas. Nunca toca guardias asignadas.
--   · Mes cerrado = congelado: nadie puede modificar nada de ese mes.
-- =====================================================================

-- ---------- Limpieza del esquema de prueba de mayo -------------------
-- Borra las tablas antiguas SOLO si están vacías (los perfiles se
-- regeneran solos más abajo). Si alguna tiene datos, se para sin tocar nada.
do $$
declare t text; n bigint;
begin
  if to_regclass('public.meses') is null then  -- este esquema aún no está instalado
    foreach t in array array['residentes','asignaciones','solicitudes','ausencias'] loop
      if to_regclass('public.' || t) is not null then
        execute format('select count(*) from public.%I', t) into n;
        if n > 0 then
          raise exception 'La tabla % tiene % filas: no se borra nada. Avisa a Claude.', t, n;
        end if;
      end if;
    end loop;
    drop table if exists public.profiles, public.asignaciones, public.solicitudes,
      public.ausencias, public.config, public.residentes cascade;
  end if;
end $$;

-- ---------- Tablas ----------------------------------------------------

create table if not exists public.residentes (
  id         text primary key,
  nombre     text not null,
  anio       int,                      -- R1..R5
  color_idx  int default 0,
  extra      jsonb default '{}'::jsonb, -- rotaciones y otros datos
  activo     boolean default true
);

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  nombre       text,
  email        text,
  role         text not null default 'residente' check (role in ('admin','residente')),
  residente_id text references public.residentes(id) on delete set null
);

-- Guardias asignadas: una fila por día y puesto (guardia, guardia2, busca)
create table if not exists public.asignaciones (
  fecha        date not null,
  tipo         text not null,
  residente_id text not null references public.residentes(id) on delete cascade,
  primary key (fecha, tipo)
);

-- Solicitudes del residente: 'libre' (día de vacaciones) o 'sin_guardia'
create table if not exists public.solicitudes (
  fecha        date not null,
  residente_id text not null references public.residentes(id) on delete cascade,
  tipo         text not null check (tipo in ('libre','sin_guardia')),
  primary key (fecha, residente_id, tipo)
);

-- Bajas / ausencias
create table if not exists public.ausencias (
  id           text primary key,
  residente_id text not null references public.residentes(id) on delete cascade,
  tipo         text not null,
  motivo       text,
  inicio       date not null,
  fin          date not null,
  check (fin >= inicio)
);

-- Configuración de reglas de auto-asignación (una sola fila)
create table if not exists public.config (
  id     int primary key default 1 check (id = 1),
  reglas jsonb not null default '{}'::jsonb
);
insert into public.config (id) values (1) on conflict do nothing;

-- Meses: abierto / cerrado (histórico)
create table if not exists public.meses (
  anio        int not null,
  mes         int not null check (mes between 1 and 12),
  cerrado     boolean not null default false,
  cerrado_at  timestamptz,
  cerrado_por uuid references auth.users(id),
  primary key (anio, mes)
);

-- ---------- Funciones auxiliares -------------------------------------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.mi_residente() returns text
language sql stable security definer set search_path = public as $$
  select residente_id from profiles where id = auth.uid();
$$;

-- ¿Algún día entre d1 y d2 cae en un mes cerrado?
create or replace function public.mes_cerrado(d1 date, d2 date default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from meses m
    where m.cerrado
      and make_date(m.anio, m.mes, 1) <= coalesce(d2, d1)
      and (make_date(m.anio, m.mes, 1) + interval '1 month')::date > d1
  );
$$;

-- Crear perfil automáticamente al registrarse
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- La primera cuenta registrada es admin; el resto, residentes
  insert into profiles (id, nombre, email, role)
  values (new.id, new.raw_user_meta_data->>'nombre', new.email,
          case when exists (select 1 from profiles where role = 'admin') then 'residente' else 'admin' end)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Perfiles para cuentas que ya existieran de antes
insert into public.profiles (id, nombre, email)
select id, raw_user_meta_data->>'nombre', email from auth.users
on conflict (id) do nothing;

-- ---------- Permisos (Row Level Security) ----------------------------

alter table public.residentes   enable row level security;
alter table public.profiles     enable row level security;
alter table public.asignaciones enable row level security;
alter table public.solicitudes  enable row level security;
alter table public.ausencias    enable row level security;
alter table public.config       enable row level security;
alter table public.meses        enable row level security;

grant usage on schema public to anon, authenticated;
grant select on public.residentes, public.asignaciones, public.solicitudes,
                public.ausencias, public.config, public.meses to anon, authenticated;
grant select on public.profiles to authenticated;
grant insert, update, delete on public.residentes, public.asignaciones,
                public.solicitudes, public.ausencias, public.config,
                public.meses, public.profiles to authenticated;

-- Lectura pública
drop policy if exists "leer" on public.residentes;
create policy "leer" on public.residentes   for select using (true);
drop policy if exists "leer" on public.asignaciones;
create policy "leer" on public.asignaciones for select using (true);
drop policy if exists "leer" on public.solicitudes;
create policy "leer" on public.solicitudes  for select using (true);
drop policy if exists "leer" on public.ausencias;
create policy "leer" on public.ausencias    for select using (true);
drop policy if exists "leer" on public.config;
create policy "leer" on public.config       for select using (true);
drop policy if exists "leer" on public.meses;
create policy "leer" on public.meses        for select using (true);

-- Perfiles: cada uno ve el suyo; el admin ve y edita todos
drop policy if exists "ver perfil" on public.profiles;
create policy "ver perfil" on public.profiles for select
  using (id = auth.uid() or public.is_admin());
drop policy if exists "admin perfiles" on public.profiles;
create policy "admin perfiles" on public.profiles for all
  using (public.is_admin()) with check (public.is_admin());

-- Residentes, reglas y meses: solo admin
drop policy if exists "admin escribe" on public.residentes;
create policy "admin escribe" on public.residentes for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin escribe" on public.config;
create policy "admin escribe" on public.config for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin escribe" on public.meses;
create policy "admin escribe" on public.meses for all
  using (public.is_admin()) with check (public.is_admin());

-- Guardias: solo admin y solo en meses abiertos
drop policy if exists "admin escribe" on public.asignaciones;
create policy "admin escribe" on public.asignaciones for all
  using (public.is_admin() and not public.mes_cerrado(fecha))
  with check (public.is_admin() and not public.mes_cerrado(fecha));

-- Solicitudes: el propio residente (o admin), solo en meses abiertos
drop policy if exists "propias" on public.solicitudes;
create policy "propias" on public.solicitudes for all
  using ((public.is_admin() or residente_id = public.mi_residente())
         and not public.mes_cerrado(fecha))
  with check ((public.is_admin() or residente_id = public.mi_residente())
              and not public.mes_cerrado(fecha));

-- Bajas: el propio residente (o admin), sin tocar días de meses cerrados
drop policy if exists "propias" on public.ausencias;
create policy "propias" on public.ausencias for all
  using ((public.is_admin() or residente_id = public.mi_residente())
         and not public.mes_cerrado(inicio, fin))
  with check ((public.is_admin() or residente_id = public.mi_residente())
              and not public.mes_cerrado(inicio, fin));

-- =====================================================================
-- DESPUÉS de crear tu cuenta en la web, hazte admin ejecutando SOLO
-- esta línea (cambia el email por el tuyo):
--
--   update public.profiles set role = 'admin' where email = 'TU_EMAIL';
-- =====================================================================
