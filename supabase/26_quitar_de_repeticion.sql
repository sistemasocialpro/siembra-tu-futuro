-- =====================================================================
-- 26_quitar_de_repeticion.sql  (va DESPUÉS de 25_repetir_nivel.sql)
-- Ajuste a "Repetir con mi equipo":
--   1) En un grupo repetido, el patrocinador (el recibidor) puede "Quitar de esta repetición" a uno
--      de sus constructores: sale SOLO de ese grupo (no de sus otras posiciones ni de la plataforma)
--      y no entra automático en las siguientes repeticiones de ese patrocinador.
--   2) El lugar queda libre y el patrocinador lo llena eligiendo a alguien de su lista de espera,
--      que entra directo como constructor.
--   3) Los regaladores que colgaban del constructor que salió quedan debajo del nuevo y lo siguen a
--      él en todas las repeticiones (al subir el grupo pasan a ser sus constructores).
--   4) En las posiciones normales los 2 referidos del patrocinador no cambian: el nuevo es su
--      seguidor solo en repeticiones, sigue en su lista de espera y no cuenta en el límite de 2.
--   5) Un grupo repetido no sube de nivel mientras tenga un lugar de constructor vacío; se avisa
--      al patrocinador para que lo llene.
--   6) info_repeticion(): para el mapa, "Sigue a" e "Invitado por" de cada casilla.
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

-- =====================================================================
-- 1. TABLAS
-- =====================================================================
-- A quién sigue una persona en las repeticiones cuando no es su patrocinador (reemplazos)
create table if not exists public.repeticion_sigue (
  user_id     uuid primary key references public.perfiles (id) on delete cascade,
  sigue_a     uuid not null references public.perfiles (id) on delete cascade,
  orden_clave timestamptz not null,           -- ocupa el turno (lado) de la persona que reemplazó
  creado_en   timestamptz not null default now(),
  constraint repeticion_sigue_no_mismo_chk check (user_id <> sigue_a)
);
create index if not exists repeticion_sigue_sigue_a_idx on public.repeticion_sigue (sigue_a);

-- Personas que un patrocinador quitó de sus repeticiones
create table if not exists public.repeticion_excluidos (
  patrocinador_id uuid not null references public.perfiles (id) on delete cascade,
  user_id         uuid not null references public.perfiles (id) on delete cascade,
  grupo_id        uuid references public.grupos (id) on delete set null,
  posicion        text,
  reemplazo_id    uuid references public.perfiles (id) on delete set null,
  creado_en       timestamptz not null default now(),
  primary key (patrocinador_id, user_id)
);
create index if not exists repeticion_excluidos_grupo_idx on public.repeticion_excluidos (grupo_id);

alter table public.repeticion_sigue enable row level security;
alter table public.repeticion_excluidos enable row level security;
revoke all on public.repeticion_sigue from anon, authenticated;
revoke all on public.repeticion_excluidos from anon, authenticated;

-- =====================================================================
-- 2. EQUIPO EN LAS REPETICIONES
-- =====================================================================
-- Mis seguidores en repeticiones, en orden: mis referidos activos (que no sigan a otra persona)
-- más quienes me siguen por un reemplazo, menos los que quité de mis repeticiones.
create or replace function public.seguidores_rep(p_lider uuid)
returns table (id uuid, n integer)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, (row_number() over (order by s.clave, s.id))::int
  from (
    select pe.id, pe.creado_en as clave
    from public.perfiles pe
    where pe.invitado_por = p_lider and pe.referido_estado = 'activo'
      and not exists (select 1 from public.repeticion_sigue rs where rs.user_id = pe.id)
    union all
    select rs.user_id, rs.orden_clave
    from public.repeticion_sigue rs
    where rs.sigue_a = p_lider
  ) s
  where not exists (select 1 from public.repeticion_excluidos x
                    where x.patrocinador_id = p_lider and x.user_id = s.id);
$$;

-- A quién sigue una persona en las repeticiones (reemplazo o, si no, su patrocinador)
create or replace function public.lider_rep(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select sigue_a from public.repeticion_sigue where user_id = p_user_id),
                  (select invitado_por from public.perfiles where id = p_user_id));
$$;

-- Redefinida (25): mi equipo de siempre según los seguidores en repeticiones
create or replace function public.equipo_de(p_user_id uuid)
returns table (posicion text, user_id uuid, patrocinador uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with c2 as (
    select s.id, s.n from public.seguidores_rep(p_user_id) s where s.n <= 2
  ), r as (
    select c2.n as cn, c2.id as cid, s.id, s.n as rn
    from c2 cross join lateral public.seguidores_rep(c2.id) s
    where s.n <= 2 and s.id <> p_user_id
  )
  select 'constructor_' || n, id, p_user_id from c2
  union all
  select 'regalador_' || ((cn - 1) * 2 + rn), id, cid from r;
$$;

-- =====================================================================
-- 3. ASCENSO (redefinida del 25): un grupo repetido no sube con un constructor vacío
-- =====================================================================
create or replace function public.ascender_grupo(p_grupo_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grupo  public.grupos;
  v_nivel  public.niveles;
  v_rec    uuid;
  v_c1     uuid;
  v_c2     uuid;
  v_r      uuid[];
  v_a      uuid;
  v_b      uuid;
  v_espera int;
  v_ultimo boolean;
  u        uuid;
begin
  select * into v_grupo from public.grupos where id = p_grupo_id for update;
  if not found or v_grupo.estado <> 'activo' then
    return false;
  end if;

  if (select count(*) from public.posiciones
       where grupo_id = p_grupo_id and posicion like 'regalador%'
         and user_id is not null and estado = 'confirmada') < 4 then
    return false;
  end if;

  select * into v_nivel from public.niveles where id = v_grupo.nivel_id;

  -- (26) Grupo repetido con un lugar de constructor vacío: no sube; se avisa al patrocinador
  if v_grupo.tipo = 'repetido'
     and exists (select 1 from public.posiciones
                 where grupo_id = p_grupo_id and posicion like 'constructor%' and user_id is null) then
    perform public.notificar(public.recibidor_de_grupo(p_grupo_id), 'Tu grupo no puede subir todavía',
      format('Tus 4 regaladores del nivel %s ya están aprobados, pero tu grupo repetido tiene un lugar de constructor vacío. En Mi grupo toca "Elegir de mi lista de espera" en esa casilla: el grupo sube en cuanto lo llenes.',
             v_nivel.nombre));
    return false;
  end if;

  select (array_agg(user_id) filter (where posicion = 'recibidor'))[1],
         (array_agg(user_id) filter (where posicion = 'constructor_1'))[1],
         (array_agg(user_id) filter (where posicion = 'constructor_2'))[1],
         array[
           (array_agg(user_id) filter (where posicion = 'regalador_1'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_2'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_3'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_4'))[1]
         ]
    into v_rec, v_c1, v_c2, v_r
  from public.posiciones
  where grupo_id = p_grupo_id;

  if v_rec is not null then
    insert into public.ciclos_completados (user_id, nivel_id, grupo_id) values (v_rec, v_nivel.id, p_grupo_id);
  end if;

  update public.posiciones
     set user_id = null, origen = null, estado = null, asignado_en = null,
         reservada_en = null, tarea_hecha_en = null, ascendido_en = null, aviso_enviado = false
   where grupo_id = p_grupo_id;
  update public.grupos set estado = 'completado' where id = p_grupo_id;

  v_a := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_a, 'recibidor',     v_c1);
  perform public.colocar_ascendido(v_a, 'constructor_1', v_r[1]);
  perform public.colocar_ascendido(v_a, 'constructor_2', v_r[2]);

  v_b := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_b, 'recibidor',     v_c2);
  perform public.colocar_ascendido(v_b, 'constructor_1', v_r[3]);
  perform public.colocar_ascendido(v_b, 'constructor_2', v_r[4]);

  v_ultimo := public.nivel_siguiente(v_nivel.id) is null;
  perform public.notificar(v_rec, 'Completaste el nivel ' || v_nivel.nombre,
    case when v_grupo.tipo = 'repetido'
         then format('Completaste otra vez el nivel %s con tu equipo. Puedes volver a repetir niveles inferiores desde Niveles.', v_nivel.nombre)
         when v_ultimo
         then format('Completaste el nivel %s, el último nivel. ¡Felicitaciones! Puedes repetir niveles inferiores con tu equipo desde Niveles.', v_nivel.nombre)
         else format('Completaste el nivel %s. Ya puedes participar en el siguiente desde Niveles.', v_nivel.nombre)
    end);

  foreach u in array v_r loop
    perform public.notificar(u, 'Subiste a constructor',
      format('La persona del centro recibió todas las tareas y subiste a constructor. Tienes %s para invitar a 2 personas. (Nivel %s)',
             public.texto_dias_invitar(v_nivel.id), v_nivel.nombre));
  end loop;

  perform public.notificar(v_c1, 'Eres recibidor',
    format('Ahora eres el recibidor de un grupo nuevo. (Nivel %s)', v_nivel.nombre));
  perform public.notificar(v_c2, 'Eres recibidor',
    format('Ahora eres el recibidor de un grupo nuevo. (Nivel %s)', v_nivel.nombre));

  select count(*) into v_espera from public.lista_espera where nivel_id = v_nivel.id;
  if v_espera > 0 then
    perform public.notificar_admins('Grupos nuevos con lugares libres',
      format('Un grupo del nivel %s se completó y se dividió en 2 grupos nuevos con regaladores libres. Hay %s persona(s) en lista de espera de ese nivel: asígnalas en Administración → Lista de espera.',
             v_nivel.nombre, v_espera));
  end if;

  return true;
end;
$$;

-- =====================================================================
-- 4. "QUITAR DE ESTA REPETICIÓN"
-- =====================================================================
create or replace function public.quitar_de_repeticion(p_posicion_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_pos    public.posiciones;
  v_grupo  public.grupos;
  v_nombre text;
  v_nivel  text;
  v_yo_nom text;
  v_espera integer;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  perform 1 from public.perfiles where id = v_yo for update;

  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  select * into v_grupo from public.grupos where id = v_pos.grupo_id;
  if v_grupo.tipo <> 'repetido' then
    raise exception 'Solo se puede quitar a alguien de un grupo repetido.';
  end if;
  if v_grupo.estado <> 'activo' then
    raise exception 'Ese grupo ya se completó.';
  end if;
  if public.recibidor_de_grupo(v_grupo.id) is distinct from v_yo then
    raise exception 'Solo el patrocinador que repite el nivel (el del centro) puede quitar a un constructor.';
  end if;
  if v_pos.posicion not like 'constructor%' then
    raise exception 'Solo puedes quitar a uno de tus constructores.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla ya está libre.';
  end if;

  select nombre_usuario into v_nombre from public.perfiles where id = v_pos.user_id;
  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  select nombre_usuario into v_yo_nom from public.perfiles where id = v_yo;

  -- Sale solo de este grupo: sus otras posiciones y su cuenta no cambian
  perform public.liberar_posicion(v_pos.id, 'retirada');

  insert into public.repeticion_excluidos (patrocinador_id, user_id, grupo_id, posicion)
  values (v_yo, v_pos.user_id, v_grupo.id, v_pos.posicion)
  on conflict (patrocinador_id, user_id)
  do update set grupo_id = excluded.grupo_id, posicion = excluded.posicion, reemplazo_id = null, creado_en = now();

  perform public.notificar(v_pos.user_id, 'Saliste de una repetición',
    format('%s te quitó de su grupo repetido del nivel %s. Tus otras posiciones y tu cuenta siguen igual; no entrarás automáticamente en sus próximas repeticiones.',
           v_yo_nom, v_nivel));

  select count(*) into v_espera from public.perfiles
  where invitado_por = v_yo and referido_estado = 'reserva';
  perform public.notificar(v_yo, 'Llena el lugar de constructor',
    case when v_espera > 0
         then format('Quitaste a %s de tu grupo repetido del nivel %s. En Mi grupo toca "Elegir de mi lista de espera" en esa casilla: tu grupo no sube de nivel hasta que la llenes.', v_nombre, v_nivel)
         else format('Quitaste a %s de tu grupo repetido del nivel %s. Todavía no tienes a nadie en tu lista de espera: cuando alguien se registre con tu enlace podrás elegirlo en Mi grupo. Tu grupo no sube de nivel hasta que llenes ese lugar.', v_nombre, v_nivel)
    end);
  return v_nombre;
end;
$$;

-- =====================================================================
-- 5. LLENAR UN LUGAR DE CONSTRUCTOR DE UN GRUPO REPETIDO CON MI LISTA DE ESPERA
-- =====================================================================
create or replace function public.candidatos_constructor_repetido(p_posicion_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo  uuid := (select auth.uid());
  v_pos public.posiciones;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_pos from public.posiciones where id = p_posicion_id;
  if not found or public.recibidor_de_grupo(v_pos.grupo_id) is distinct from v_yo then
    raise exception 'Solo el patrocinador que repite el nivel puede llenar ese lugar.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', pe.id,
             'nombre_usuario', pe.nombre_usuario,
             'en_espera_desde', coalesce(pe.reserva_desde, pe.creado_en))
           order by coalesce(pe.reserva_desde, pe.creado_en), pe.id), '[]'::jsonb)
    from public.perfiles pe
    where pe.invitado_por = v_yo and pe.referido_estado = 'reserva'
      and not exists (select 1 from public.posiciones x where x.user_id = pe.id and x.nivel_id = v_pos.nivel_id)
  );
end;
$$;

create or replace function public.llenar_constructor_repetido(p_posicion_id uuid, p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := (select auth.uid());
  v_pos     public.posiciones;
  v_grupo   public.grupos;
  v_nuevo   public.perfiles;
  v_excl    public.repeticion_excluidos;
  v_clave   timestamptz;
  v_seguir  boolean;
  v_nivel   text;
  v_yo_nom  text;
  r         record;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  -- Mismo orden de bloqueo que el resto: perfiles (por id) y después la casilla
  perform 1 from public.perfiles where id in (v_yo, p_user_id) order by id for update;

  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  select * into v_grupo from public.grupos where id = v_pos.grupo_id;
  if v_grupo.tipo <> 'repetido' or v_grupo.estado <> 'activo' then
    raise exception 'Ese lugar no es de un grupo repetido activo.';
  end if;
  if public.recibidor_de_grupo(v_grupo.id) is distinct from v_yo then
    raise exception 'Solo el patrocinador que repite el nivel (el del centro) puede llenar ese lugar.';
  end if;
  if v_pos.posicion not like 'constructor%' then
    raise exception 'Solo se llenan así los lugares de constructor.';
  end if;
  if v_pos.user_id is not null then
    raise exception 'Ese lugar ya está ocupado. Recarga la página.';
  end if;

  select * into v_nuevo from public.perfiles where id = p_user_id;
  if not found or v_nuevo.invitado_por is distinct from v_yo or v_nuevo.referido_estado <> 'reserva' then
    raise exception 'Esa persona no está en tu lista de espera.';
  end if;
  if exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = v_pos.nivel_id) then
    raise exception '% ya tiene una posición en este nivel. Elige a otra persona.', v_nuevo.nombre_usuario;
  end if;

  -- ¿Ese lugar es de alguien que quité? Entonces el nuevo me sigue en todas mis repeticiones
  select * into v_excl from public.repeticion_excluidos
  where patrocinador_id = v_yo and grupo_id = v_grupo.id and posicion = v_pos.posicion and reemplazo_id is null;
  v_seguir := v_excl.user_id is not null
              or (select count(*) from public.seguidores_rep(v_yo)) < 2;

  -- Entra directo como constructor (sin relojes); en las posiciones normales sigue en mi espera
  perform public.colocar_en_repetido(v_grupo.id, v_pos.posicion, p_user_id);
  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  select nombre_usuario into v_yo_nom from public.perfiles where id = v_yo;

  if v_seguir then
    -- Ocupa el turno (lado) de quien reemplaza
    v_clave := case when v_excl.user_id is not null
                    then coalesce((select orden_clave from public.repeticion_sigue where user_id = v_excl.user_id),
                                  (select creado_en from public.perfiles where id = v_excl.user_id))
                    else now() end;
    insert into public.repeticion_sigue (user_id, sigue_a, orden_clave)
    values (p_user_id, v_yo, v_clave)
    on conflict (user_id) do update set sigue_a = excluded.sigue_a, orden_clave = excluded.orden_clave, creado_en = now();

    if v_excl.user_id is not null then
      update public.repeticion_excluidos set reemplazo_id = p_user_id
       where patrocinador_id = v_yo and user_id = v_excl.user_id;
    end if;

    -- Los regaladores que colgaban de quien salió pasan a seguir al nuevo constructor
    for r in
      select p.user_id, pe.nombre_usuario, pe.creado_en
      from public.posiciones p
      join public.perfiles pe on pe.id = p.user_id
      where p.grupo_id = v_grupo.id and p.cuelga_de = v_pos.posicion
        and exists (select 1 from public.repeticion_excluidos x
                    where x.patrocinador_id = v_yo and x.user_id = public.lider_rep(p.user_id))
    loop
      insert into public.repeticion_sigue (user_id, sigue_a, orden_clave)
      values (r.user_id, p_user_id,
              coalesce((select orden_clave from public.repeticion_sigue where user_id = r.user_id), r.creado_en))
      on conflict (user_id) do update set sigue_a = excluded.sigue_a, creado_en = now();
      perform public.notificar(r.user_id, 'Tienes un nuevo constructor',
        format('%s es ahora tu constructor en el grupo repetido del nivel %s. Desde ahora lo sigues a él en las repeticiones.',
               v_nuevo.nombre_usuario, v_nivel));
    end loop;
  end if;

  perform public.notificar(p_user_id, 'Entraste como constructor',
    format('%s te eligió de su lista de espera: eres %s en su grupo repetido del nivel %s. No necesitas invitar: los regaladores ya están en el grupo.%s',
           v_yo_nom, public.nombre_posicion(v_pos.posicion), v_nivel,
           case when v_seguir then ' Lo sigues en sus repeticiones; en las posiciones normales sigues en su lista de espera.' else '' end));

  -- Si los 4 regaladores ya estaban aprobados, el grupo sube ahora
  perform public.ascender_grupo(v_grupo.id);
  return v_nuevo.nombre_usuario;
end;
$$;

-- =====================================================================
-- 6. PARA EL MAPA: "Sigue a" / "Invitado por" y qué puedo hacer en cada casilla
-- =====================================================================
create or replace function public.info_repeticion(p_grupo_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo    uuid := (select auth.uid());
  v_grupo public.grupos;
  v_soy   boolean;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_grupo from public.grupos where id = p_grupo_id;
  if not found or v_grupo.tipo <> 'repetido' then
    return '[]'::jsonb;
  end if;
  if not public.es_admin()
     and not exists (select 1 from public.posiciones where grupo_id = p_grupo_id and user_id = v_yo) then
    raise exception 'No perteneces a ese grupo.';
  end if;
  v_soy := v_grupo.estado = 'activo' and public.recibidor_de_grupo(p_grupo_id) = v_yo;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'posicion', x.posicion,
             'sigue_a', x.sigue_a,
             'invitado_por', case when x.invitado_por is distinct from x.sigue_a then x.invitado_por end,
             'puedo_quitar', v_soy and x.posicion like 'constructor%' and x.user_id is not null,
             'puedo_llenar', v_soy and x.posicion like 'constructor%' and x.user_id is null)), '[]'::jsonb)
    from (
      select p.posicion, p.user_id,
             case when p.user_id is null or p.posicion = 'recibidor' then null
                  else coalesce(padre_pe.nombre_usuario,
                                (select nombre_usuario from public.perfiles where id = public.lider_rep(p.user_id)))
             end as sigue_a,
             case when p.user_id is null or p.posicion = 'recibidor' then null
                  else (select inv.nombre_usuario from public.perfiles yo
                        join public.perfiles inv on inv.id = yo.invitado_por where yo.id = p.user_id)
             end as invitado_por
      from public.posiciones p
      left join public.posiciones padre on padre.grupo_id = p.grupo_id and padre.posicion = p.cuelga_de
      left join public.perfiles padre_pe on padre_pe.id = padre.user_id
      where p.grupo_id = p_grupo_id
    ) x
  );
end;
$$;

-- =====================================================================
-- 7. PERMISOS
-- =====================================================================
revoke execute on function public.seguidores_rep(uuid)                         from public, anon, authenticated;
revoke execute on function public.lider_rep(uuid)                              from public, anon, authenticated;
revoke execute on function public.equipo_de(uuid)                              from public, anon, authenticated;
revoke execute on function public.ascender_grupo(uuid)                         from public, anon, authenticated;

revoke execute on function public.quitar_de_repeticion(uuid)                   from public, anon;
revoke execute on function public.candidatos_constructor_repetido(uuid)        from public, anon;
revoke execute on function public.llenar_constructor_repetido(uuid, uuid)      from public, anon;
revoke execute on function public.info_repeticion(uuid)                        from public, anon;
grant  execute on function public.quitar_de_repeticion(uuid)                   to authenticated;
grant  execute on function public.candidatos_constructor_repetido(uuid)        to authenticated;
grant  execute on function public.llenar_constructor_repetido(uuid, uuid)      to authenticated;
grant  execute on function public.info_repeticion(uuid)                        to authenticated;

notify pgrst, 'reload schema';
