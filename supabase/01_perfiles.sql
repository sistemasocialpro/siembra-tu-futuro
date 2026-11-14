-- =====================================================================
-- Sistema Siembra tu Futuro — 01_perfiles.sql
-- Ejecutar completo en Supabase > SQL Editor. Se puede volver a ejecutar sin problema.
-- =====================================================================

-- ---------- Tabla ----------
create table if not exists public.perfiles (
  id                uuid primary key references auth.users (id) on delete cascade,
  nombre_usuario    text not null unique
                    check (nombre_usuario ~ '^[a-z0-9_]{3,20}$'),
  codigo_invitacion text not null unique
                    check (codigo_invitacion ~ '^[A-Z0-9]{8}$'),
  invitado_por      uuid references public.perfiles (id) on delete set null,
  creado_en         timestamptz not null default now()
);

comment on table  public.perfiles is 'Perfil público de cada usuario registrado.';
comment on column public.perfiles.invitado_por is 'Perfil de quien invitó a este usuario (por su código ?ref=).';

create index if not exists perfiles_invitado_por_idx on public.perfiles (invitado_por);

-- ---------- Código de invitación aleatorio (8 caracteres, sin 0/O/1/I) ----------
create or replace function public.generar_codigo_invitacion()
returns text
language plpgsql
set search_path = ''
as $$
declare
  alfabeto constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  nuevo text;
begin
  loop
    nuevo := '';
    for i in 1..8 loop
      nuevo := nuevo || substr(alfabeto, 1 + floor(random() * length(alfabeto))::int, 1);
    end loop;
    exit when not exists (select 1 from public.perfiles where codigo_invitacion = nuevo);
  end loop;
  return nuevo;
end;
$$;

-- ---------- Trigger: crear el perfil al registrarse ----------
-- Lee raw_user_meta_data: { nombre_usuario, codigo_ref } enviados desde el registro.
create or replace function public.crear_perfil_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario   text := lower(trim(coalesce(new.raw_user_meta_data ->> 'nombre_usuario', '')));
  v_ref       text := upper(trim(coalesce(new.raw_user_meta_data ->> 'codigo_ref', '')));
  v_invitador uuid;
begin
  -- Usuarios creados sin nombre válido (p. ej. desde el panel de Supabase) reciben uno automático.
  if v_usuario !~ '^[a-z0-9_]{3,20}$' then
    v_usuario := 'u_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;

  if v_ref <> '' then
    select p.id into v_invitador from public.perfiles p where p.codigo_invitacion = v_ref;
  end if;

  -- Si el nombre ya existe, la restricción unique hace fallar el registro (no se crea la cuenta).
  insert into public.perfiles (id, nombre_usuario, codigo_invitacion, invitado_por)
  values (new.id, v_usuario, public.generar_codigo_invitacion(), v_invitador);

  return new;
end;
$$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario
  after insert on auth.users
  for each row execute function public.crear_perfil_nuevo_usuario();

-- ---------- Funciones públicas para el login/registro (sin sesión) ----------
-- Nombre de usuario de quien invita, a partir de su código (para "Te invitó: ...").
create or replace function public.usuario_por_codigo(p_codigo text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.nombre_usuario from public.perfiles p
  where p.codigo_invitacion = upper(trim(p_codigo));
$$;

-- ¿Está libre este nombre de usuario?
create or replace function public.usuario_disponible(p_usuario text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1 from public.perfiles p where p.nombre_usuario = lower(trim(p_usuario))
  );
$$;

-- ---------- Seguridad: RLS ----------
alter table public.perfiles enable row level security;

drop policy if exists "perfiles: ver el propio" on public.perfiles;
create policy "perfiles: ver el propio"
  on public.perfiles for select
  to authenticated
  using ((select auth.uid()) = id);

drop policy if exists "perfiles: actualizar el propio" on public.perfiles;
create policy "perfiles: actualizar el propio"
  on public.perfiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- ---------- GRANTs (el proyecto NO expone tablas automáticamente) ----------
grant usage on schema public to anon, authenticated;

revoke all on table public.perfiles from anon, authenticated;
grant select on table public.perfiles to authenticated;
-- Solo se puede cambiar el nombre de usuario; código e invitador quedan fijos.
grant update (nombre_usuario) on table public.perfiles to authenticated;

-- Funciones internas: nadie las llama directamente.
revoke execute on function public.generar_codigo_invitacion() from public, anon, authenticated;
revoke execute on function public.crear_perfil_nuevo_usuario() from public, anon, authenticated;

-- Funciones públicas (RPC) usadas por index.html.
revoke execute on function public.usuario_por_codigo(text) from public;
revoke execute on function public.usuario_disponible(text) from public;
grant execute on function public.usuario_por_codigo(text) to anon, authenticated;
grant execute on function public.usuario_disponible(text) to anon, authenticated;

-- Que la API (PostgREST) vea los cambios de inmediato.
notify pgrst, 'reload schema';
