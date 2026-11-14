-- =====================================================================
-- Sistema Siembra tu Futuro — 03_niveles_grupos.sql
-- Ejecutar DESPUÉS de 01 y 02. Se puede volver a ejecutar sin problema.
-- Administradores, niveles, grupos y posiciones (fase 2: grupos fundadores a mano).
-- =====================================================================

-- =====================================================================
-- 1. ADMINISTRADORES
-- =====================================================================
create table if not exists public.administradores (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  creado_en timestamptz not null default now()
);

comment on table public.administradores is 'Usuarios con acceso a admin.html. Se agregan a mano desde el SQL Editor.';

-- Para hacerte administrador (ejecútalo aparte, con tu correo real):
-- insert into public.administradores (user_id) select id from auth.users where email = 'CORREO_DEL_ADMIN';

create or replace function public.es_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.administradores a where a.user_id = (select auth.uid())
  );
$$;

-- =====================================================================
-- 2. NIVELES
-- =====================================================================
create table if not exists public.niveles (
  id          integer primary key,
  orden       integer not null unique check (orden > 0),
  nombre      text    not null unique,
  meta_tareas numeric not null check (meta_tareas > 0)
);

insert into public.niveles (id, orden, nombre, meta_tareas) values
  (1,  1,  'Terreno',     1.5),
  (2,  2,  'Preparar',    5),
  (3,  3,  'Sembrar',     15),
  (4,  4,  'Crecer',      100),
  (5,  5,  'Cuidar',      200),
  (6,  6,  'Producir',    400),
  (7,  7,  'Recoger',     800),
  (8,  8,  'Expandir',    1600),
  (9,  9,  'Prosperar',   3200),
  (10, 10, 'Abundancia',  5000)
-- Al re-ejecutar NO se toca "orden": 08_nivel_plantar.sql lo cambió (Plantar, id 11, va en orden 4)
-- y volver a poner 1..10 chocaría con la restricción unique de orden.
on conflict (id) do update
  set nombre = excluded.nombre, meta_tareas = excluded.meta_tareas;

-- =====================================================================
-- 3. GRUPOS
-- =====================================================================
create table if not exists public.grupos (
  id        uuid primary key default gen_random_uuid(),
  nivel_id  integer not null references public.niveles (id),
  estado    text not null default 'activo' check (estado in ('activo', 'completado')),
  creado_en timestamptz not null default now(),
  -- Necesario para que posiciones copie el nivel de su grupo sin poder equivocarse
  constraint grupos_id_nivel_uk unique (id, nivel_id)
);

create index if not exists grupos_nivel_idx on public.grupos (nivel_id);

-- =====================================================================
-- 4. POSICIONES (7 casillas por grupo)
--            regalador_1 ┐                ┌ regalador_3
--                        ├ constructor_1 ─ RECIBIDOR ─ constructor_2 ┤
--            regalador_2 ┘                └ regalador_4
-- =====================================================================
create table if not exists public.posiciones (
  id           uuid primary key default gen_random_uuid(),
  grupo_id     uuid not null,
  -- Copia del nivel del grupo (lo garantiza la FK compuesta). Permite "una posición por nivel".
  nivel_id     integer not null,
  posicion     text not null check (posicion in (
                 'recibidor', 'constructor_1', 'constructor_2',
                 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4')),
  -- De qué casilla cuelga cada una (calculado, no se puede editar)
  cuelga_de    text generated always as (
                 case posicion
                   when 'constructor_1' then 'recibidor'
                   when 'constructor_2' then 'recibidor'
                   when 'regalador_1'   then 'constructor_1'
                   when 'regalador_2'   then 'constructor_1'
                   when 'regalador_3'   then 'constructor_2'
                   when 'regalador_4'   then 'constructor_2'
                 end) stored,
  user_id      uuid references public.perfiles (id) on delete set null,
  estado_tarea text not null default 'sin_tarea'
               check (estado_tarea in ('sin_tarea', 'pendiente', 'confirmada')),
  asignado_en  timestamptz,
  constraint posiciones_grupo_fk foreign key (grupo_id, nivel_id)
    references public.grupos (id, nivel_id) on delete cascade,
  -- Cada casilla existe una sola vez por grupo
  constraint posiciones_grupo_posicion_uk unique (grupo_id, posicion),
  -- Un usuario solo puede estar en una posición por nivel (varias casillas vacías sí se permiten)
  constraint posiciones_usuario_nivel_uk unique (user_id, nivel_id)
);

create index if not exists posiciones_user_idx on public.posiciones (user_id);
create index if not exists posiciones_nivel_idx on public.posiciones (nivel_id);

-- =====================================================================
-- 5. FUNCIONES AUXILIARES (security definer: evitan abrir tablas)
-- =====================================================================

-- Grupos donde participa el usuario actual (usada por las políticas RLS; evita recursión)
create or replace function public.mis_grupos()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct p.grupo_id from public.posiciones p where p.user_id = (select auth.uid());
$$;

-- Las 7 casillas de un grupo con el nombre de usuario de cada persona.
-- Solo devuelve filas si quien pregunta es administrador o participa en ese grupo.
create or replace function public.posiciones_de_grupo(p_grupo_id uuid)
returns table (
  posicion_id    uuid,
  posicion       text,
  cuelga_de      text,
  user_id        uuid,
  nombre_usuario text,
  estado_tarea   text,
  asignado_en    timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select po.id, po.posicion, po.cuelga_de, po.user_id, pe.nombre_usuario, po.estado_tarea, po.asignado_en
  from public.posiciones po
  left join public.perfiles pe on pe.id = po.user_id
  where po.grupo_id = p_grupo_id
    and (
      public.es_admin()
      or exists (
        select 1 from public.posiciones yo
        where yo.grupo_id = p_grupo_id and yo.user_id = (select auth.uid())
      )
    )
  order by array_position(
    array['recibidor', 'constructor_1', 'constructor_2',
          'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'],
    po.posicion);
$$;

-- WhatsApp de una persona. Solo lo obtiene: el administrador, la propia persona,
-- o alguien de su mismo grupo (si la persona aceptó que su grupo lo vea).
create or replace function public.whatsapp_de(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select pe.whatsapp
  from public.perfiles pe
  where pe.id = p_user_id
    and (
      public.es_admin()
      or pe.id = (select auth.uid())
      or (
        pe.acepta_whatsapp_visible
        and exists (
          select 1
          from public.posiciones yo
          join public.posiciones otro on otro.grupo_id = yo.grupo_id
          where yo.user_id = (select auth.uid()) and otro.user_id = p_user_id
        )
      )
    );
$$;

-- =====================================================================
-- 6. ACCIONES DEL ADMINISTRADOR (security invoker: respetan RLS)
--    Los mensajes de error están en español porque se muestran tal cual en la web.
-- =====================================================================

-- Crea un grupo fundador con sus 7 casillas vacías.
create or replace function public.admin_crear_grupo(p_nivel_id integer)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_grupo uuid;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede crear grupos.';
  end if;
  if not exists (select 1 from public.niveles n where n.id = p_nivel_id) then
    raise exception 'El nivel elegido no existe.';
  end if;

  insert into public.grupos (nivel_id) values (p_nivel_id) returning id into v_grupo;

  insert into public.posiciones (grupo_id, nivel_id, posicion)
  select v_grupo, p_nivel_id, p
  from unnest(array['recibidor', 'constructor_1', 'constructor_2',
                    'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4']) as p;

  return v_grupo;
end;
$$;

-- Asigna (o reemplaza) a la persona de una casilla.
-- Orden para casillas vacías: Recibidor -> Constructor 1 -> Constructor 2 -> Regaladores.
create or replace function public.admin_asignar_posicion(p_posicion_id uuid, p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pos public.posiciones%rowtype;
  v_requisito text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede asignar posiciones.';
  end if;

  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if not exists (select 1 from public.perfiles where id = p_user_id) then
    raise exception 'Ese usuario no existe.';
  end if;
  if v_pos.user_id = p_user_id then
    raise exception 'Esa persona ya está en esta casilla.';
  end if;
  if exists (select 1 from public.posiciones
             where user_id = p_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'Ese usuario ya tiene una posición en este nivel.';
  end if;

  -- El orden de llenado solo aplica al ocupar una casilla vacía (no al reemplazar)
  if v_pos.user_id is null and v_pos.posicion <> 'recibidor' then
    select r.req into v_requisito
    from unnest(case v_pos.posicion
                  when 'constructor_1' then array['recibidor']
                  when 'constructor_2' then array['recibidor', 'constructor_1']
                  else array['recibidor', 'constructor_1', 'constructor_2']
                end) with ordinality as r(req, n)
    where not exists (
      select 1 from public.posiciones x
      where x.grupo_id = v_pos.grupo_id and x.posicion = r.req and x.user_id is not null
    )
    order by r.n
    limit 1;

    if v_requisito is not null then
      raise exception 'Primero asigna la casilla %.',
        case v_requisito
          when 'recibidor' then 'Recibidor'
          when 'constructor_1' then 'Constructor 1'
          else 'Constructor 2'
        end;
    end if;
  end if;

  update public.posiciones
     set user_id = p_user_id,
         asignado_en = now(),
         estado_tarea = case when posicion like 'regalador_%' then 'pendiente' else 'sin_tarea' end
   where id = p_posicion_id;
end;
$$;

-- Deja una casilla vacía.
create or replace function public.admin_quitar_posicion(p_posicion_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede quitar posiciones.';
  end if;

  update public.posiciones
     set user_id = null, asignado_en = null, estado_tarea = 'sin_tarea'
   where id = p_posicion_id;

  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
end;
$$;

-- Elimina un grupo, solo si todas sus casillas están vacías (para corregir errores).
create or replace function public.admin_eliminar_grupo(p_grupo_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede eliminar grupos.';
  end if;
  if exists (select 1 from public.posiciones where grupo_id = p_grupo_id and user_id is not null) then
    raise exception 'Solo se pueden eliminar grupos vacíos. Quita primero a las personas.';
  end if;

  delete from public.grupos where id = p_grupo_id;

  if not found then
    raise exception 'El grupo ya no existe. Recarga la página.';
  end if;
end;
$$;

-- =====================================================================
-- 7. RLS
-- =====================================================================
alter table public.administradores enable row level security;
alter table public.niveles         enable row level security;
alter table public.grupos          enable row level security;
alter table public.posiciones      enable row level security;

-- administradores: solo los administradores ven la lista (se edita desde el SQL Editor)
drop policy if exists "administradores: admin lee" on public.administradores;
create policy "administradores: admin lee"
  on public.administradores for select to authenticated
  using (public.es_admin());

-- niveles: lectura para todos con sesión; escritura solo admin
drop policy if exists "niveles: leer con sesión" on public.niveles;
create policy "niveles: leer con sesión"
  on public.niveles for select to authenticated
  using (true);

drop policy if exists "niveles: admin escribe" on public.niveles;
create policy "niveles: admin escribe"
  on public.niveles for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- grupos: admin todo; usuario lee solo los grupos donde participa
drop policy if exists "grupos: admin todo" on public.grupos;
create policy "grupos: admin todo"
  on public.grupos for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists "grupos: miembro lee" on public.grupos;
create policy "grupos: miembro lee"
  on public.grupos for select to authenticated
  using (id in (select public.mis_grupos()));

-- posiciones: admin todo; usuario lee solo las posiciones de sus grupos
drop policy if exists "posiciones: admin todo" on public.posiciones;
create policy "posiciones: admin todo"
  on public.posiciones for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

drop policy if exists "posiciones: miembro lee" on public.posiciones;
create policy "posiciones: miembro lee"
  on public.posiciones for select to authenticated
  using (grupo_id in (select public.mis_grupos()));

-- perfiles: el administrador puede leer todos (la política de "ver el propio" sigue igual)
drop policy if exists "perfiles: admin lee todos" on public.perfiles;
create policy "perfiles: admin lee todos"
  on public.perfiles for select to authenticated
  using (public.es_admin());

-- =====================================================================
-- 8. GRANTs (el proyecto NO expone tablas automáticamente)
--    Los permisos de escritura se dan a "authenticated", pero RLS solo deja escribir al admin.
-- =====================================================================
revoke all on table public.administradores, public.niveles, public.grupos, public.posiciones
  from anon, authenticated;

grant select on table public.administradores to authenticated;
grant select, insert, update, delete on table public.niveles    to authenticated;
grant select, insert, update, delete on table public.grupos     to authenticated;
grant select, insert, update, delete on table public.posiciones to authenticated;

-- Funciones: nadie sin sesión
revoke execute on function public.es_admin()                         from public, anon;
revoke execute on function public.mis_grupos()                       from public, anon;
revoke execute on function public.posiciones_de_grupo(uuid)          from public, anon;
revoke execute on function public.whatsapp_de(uuid)                  from public, anon;
revoke execute on function public.admin_crear_grupo(integer)         from public, anon;
revoke execute on function public.admin_asignar_posicion(uuid, uuid) from public, anon;
revoke execute on function public.admin_quitar_posicion(uuid)        from public, anon;
revoke execute on function public.admin_eliminar_grupo(uuid)         from public, anon;

grant execute on function public.es_admin()                         to authenticated;
grant execute on function public.mis_grupos()                       to authenticated;
grant execute on function public.posiciones_de_grupo(uuid)          to authenticated;
grant execute on function public.whatsapp_de(uuid)                  to authenticated;
grant execute on function public.admin_crear_grupo(integer)         to authenticated;
grant execute on function public.admin_asignar_posicion(uuid, uuid) to authenticated;
grant execute on function public.admin_quitar_posicion(uuid)        to authenticated;
grant execute on function public.admin_eliminar_grupo(uuid)         to authenticated;

notify pgrst, 'reload schema';
