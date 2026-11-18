-- =====================================================================
-- 26_quitar_de_repeticion.sql  (va DESPUÉS de 25_repetir_nivel.sql; reemplaza a la versión anterior del 26)
-- A) Quién repite cómo:
--   - FUNDADOR (perfiles.es_fundador, lo marca el admin): repite con su equipo completo, como en el 25
--     (él al centro, sus 2 constructores y los 4 regaladores de ellos).
--   - TODOS LOS DEMÁS: al repetir un nivel inferior entran como REGALADOR: debajo de la persona a la que
--     siguen si es constructor en ese nivel y tiene lugar; si no, por derrame (primer lugar libre de
--     regalador de ese nivel); si no hay, lista de espera del nivel. Hacen su tarea y, al subir a
--     constructor, sus 2 lugares los llenan sus referidos que lo siguen (tocando Repetir/Participar).
--     Si no tiene referidos disponibles, las personas NUEVAS que se registran con su enlace mientras
--     tiene un lugar libre entran directo debajo de él: son su equipo de repeticiones (lo siguen en
--     las repeticiones) y NO cuentan en su límite de 2 referidos de las posiciones normales
--     (referido_estado = 'derrame': en las posiciones normales entran por derrame).
-- B) Grupo repetido del fundador:
--   1) El patrocinador (el recibidor) puede "Quitar de esta repetición" a uno
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

-- Registro de cada repetición (para la espera mínima entre repeticiones)
create table if not exists public.repeticiones (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references public.perfiles (id) on delete cascade,
  nivel_id  integer not null references public.niveles (id),
  modo      text not null check (modo in ('equipo', 'regalador')),
  creado_en timestamptz not null default now()
);
create index if not exists repeticiones_user_idx on public.repeticiones (user_id, creado_en desc);
alter table public.repeticiones enable row level security;
revoke all on public.repeticiones from anon, authenticated;

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
    if u is not null and exists (select 1 from public.ciclos_completados c where c.user_id = u and c.nivel_id = v_nivel.id) then
      -- (26) Constructor que está repitiendo el nivel: sus 2 lugares son para quienes lo siguen
      perform public.notificar(u, 'Subiste a constructor',
        format('Subiste a constructor en el nivel %s que estás repitiendo. Tus referidos que te siguen pueden entrar debajo de ti tocando Repetir (o Participar) en Niveles. Si no tienes referidos disponibles, invita a 2 personas nuevas con tu enlace: entran directo debajo de ti, son tu equipo de repeticiones y no cuentan en tu límite de 2. Tienes %s.',
               v_nivel.nombre, public.texto_dias_invitar(v_nivel.id)));
      perform public.notificar(s.id, 'Tu patrocinador tiene un lugar para ti',
        format('%s es constructor en el nivel %s y tiene un lugar para ti debajo de él. Entra desde Niveles.',
               (select nombre_usuario from public.perfiles where id = u), v_nivel.nombre))
      from public.seguidores_rep(u) s
      where not exists (select 1 from public.posiciones x where x.user_id = s.id and x.nivel_id = v_nivel.id)
        and not exists (select 1 from public.lista_espera e where e.user_id = s.id and e.nivel_id = v_nivel.id);
    else
      perform public.notificar(u, 'Subiste a constructor',
        format('La persona del centro recibió todas las tareas y subiste a constructor. Tienes %s para invitar a 2 personas. (Nivel %s)',
               public.texto_dias_invitar(v_nivel.id), v_nivel.nombre));
    end if;
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
-- 7. REPETIR: EL FUNDADOR CON SU EQUIPO; LOS DEMÁS COMO REGALADOR
-- =====================================================================
-- Redefinida (25): para el reloj del constructor cuentan sus referidos activos Y su equipo de
-- repeticiones que ya tienen posición en ese nivel
create or replace function public.contar_invitados(p_user_id uuid, p_nivel_id integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
  from public.perfiles pe
  where ((pe.invitado_por = p_user_id and pe.referido_estado = 'activo')
         or exists (select 1 from public.repeticion_sigue rs where rs.user_id = pe.id and rs.sigue_a = p_user_id))
    and exists (select 1 from public.posiciones po where po.user_id = pe.id and po.nivel_id = p_nivel_id);
$$;

-- Lugar libre de regalador debajo de una persona que es constructor en un nivel que está
-- REPITIENDO (ya lo completó antes), sin plazo vencido. Null si no hay.
create or replace function public.casilla_equipo_rep(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
  from public.posiciones c
  join public.grupos g on g.id = c.grupo_id and g.estado = 'activo'
  join public.niveles n on n.id = c.nivel_id
  join public.posiciones p on p.grupo_id = c.grupo_id and p.cuelga_de = c.posicion and p.user_id is null
  where c.user_id = p_user_id and c.posicion like 'constructor%'
    and c.estado is distinct from 'plazo_vencido'
    and exists (select 1 from public.ciclos_completados cc where cc.user_id = p_user_id and cc.nivel_id = c.nivel_id)
  order by n.orden, p.posicion
  limit 1;
$$;

-- Redefinida (25): alta con enlace. Si el patrocinador es constructor repitiendo un nivel y tiene
-- un lugar libre debajo, la persona nueva es de su equipo de repeticiones: no cuenta en su límite
-- de 2 (queda 'derrame' para las posiciones normales) y el trigger de después la coloca.
create or replace function public.limitar_referidos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.invitado_por is null then
    new.referido_estado := 'activo';
    new.reserva_desde := null;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.invitado_por is not distinct from old.invitado_por then
    return new;
  end if;

  -- Bloquea al patrocinador (dos registros a la vez no toman el mismo lugar)
  perform 1 from public.perfiles where id = new.invitado_por for update;

  if tg_op = 'INSERT' and public.casilla_equipo_rep(new.invitado_por) is not null then
    new.referido_estado := 'derrame';
    new.reserva_desde := null;
  elsif public.contar_activos(new.invitado_por) >= 2
     or exists (select 1 from public.perfiles pe
                where pe.invitado_por = new.invitado_por and pe.referido_estado = 'reserva' and pe.id <> new.id) then
    new.referido_estado := 'reserva';
    new.reserva_desde := now();
  else
    new.referido_estado := 'activo';
    new.reserva_desde := null;
  end if;
  return new;
end;
$$;

-- Después del alta: coloca a la persona nueva debajo de su patrocinador (equipo de repeticiones)
create or replace function public.equipo_rep_tras_alta()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cas   public.posiciones;
  v_nivel text;
  v_pat   text;
  v_rec   uuid;
begin
  if new.invitado_por is null or new.referido_estado <> 'derrame' then
    return null;
  end if;
  select p.* into v_cas from public.posiciones p
  where p.id = public.casilla_equipo_rep(new.invitado_por) and p.user_id is null
  for update skip locked;

  if v_cas.id is null then
    -- Alguien tomó el lugar justo antes: se aplica la regla normal (activo o espera)
    update public.perfiles
       set referido_estado = case when public.contar_activos(new.invitado_por) >= 2
                                    or exists (select 1 from public.perfiles pe where pe.invitado_por = new.invitado_por
                                                 and pe.referido_estado = 'reserva' and pe.id <> new.id)
                                  then 'reserva' else 'activo' end,
           reserva_desde = case when public.contar_activos(new.invitado_por) >= 2
                                  or exists (select 1 from public.perfiles pe where pe.invitado_por = new.invitado_por
                                               and pe.referido_estado = 'reserva' and pe.id <> new.id)
                                then now() end
     where id = new.id;
    return null;
  end if;

  perform public.ocupar_posicion(v_cas.id, new.id, true);
  insert into public.repeticion_sigue (user_id, sigue_a, orden_clave)
  values (new.id, new.invitado_por, now())
  on conflict (user_id) do nothing;

  select nombre into v_nivel from public.niveles where id = v_cas.nivel_id;
  select nombre_usuario into v_pat from public.perfiles where id = new.invitado_por;
  perform public.notificar(new.id, 'Ya tienes tu lugar',
    format('Entraste al equipo de repeticiones de %s: eres %s en el nivel %s, debajo de él. Tienes %s para hacer tu tarea, escribir al recibidor y marcarla como hecha.',
           v_pat, public.nombre_posicion(v_cas.posicion), v_nivel,
           public.texto_duracion(public.intervalo_config('horas_tarea'))));
  perform public.notificar(new.invitado_por, 'Nueva persona en tu equipo de repeticiones',
    format('%s se registró con tu enlace y entró debajo de ti como %s en el nivel %s. No cuenta en tu límite de 2 referidos.',
           new.nombre_usuario, public.nombre_posicion(v_cas.posicion), v_nivel));
  v_rec := public.recibidor_de_grupo(v_cas.grupo_id);
  if v_rec is not null and v_rec <> new.invitado_por then
    perform public.notificar(v_rec, 'Nueva persona en tu grupo',
      format('%s entró a tu grupo del nivel %s como %s.', new.nombre_usuario, v_nivel, public.nombre_posicion(v_cas.posicion)));
  end if;
  return null;
end;
$$;

drop trigger if exists perfiles_equipo_rep_tras_alta on public.perfiles;
create trigger perfiles_equipo_rep_tras_alta
  after insert on public.perfiles
  for each row execute function public.equipo_rep_tras_alta();

-- Repetir sin ser fundador: regalador debajo de quien sigo (si es constructor en ese nivel y tiene
-- lugar); si no, derrame (misma prioridad que el 21) en ESE nivel; si no, lista de espera del nivel.
create or replace function public.entrar_repitiendo(p_user_id uuid, p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nivel   public.niveles;
  v_perfil  public.perfiles;
  v_lider   uuid;
  v_libre   public.posiciones;
  v_cand    record;
  v_derrame boolean := false;
  v_rec     uuid;
begin
  select * into v_nivel from public.niveles where id = p_nivel_id;
  select * into v_perfil from public.perfiles where id = p_user_id for update;
  if exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = p_nivel_id) then
    raise exception 'Ya tienes una posición activa en el nivel %. Solo puedes tener una por nivel.', v_nivel.nombre;
  end if;
  if exists (select 1 from public.lista_espera where user_id = p_user_id and nivel_id = p_nivel_id) then
    raise exception 'Ya estás en la lista de espera de este nivel.';
  end if;

  -- 1) Debajo de quien sigo en las repeticiones, si es constructor en ese nivel y tiene lugar
  v_lider := public.lider_rep(p_user_id);
  if v_lider is not null and exists (select 1 from public.seguidores_rep(v_lider) s where s.id = p_user_id) then
    select p.* into v_libre
    from public.posiciones c
    join public.grupos g on g.id = c.grupo_id and g.estado = 'activo'
    join public.posiciones p on p.grupo_id = c.grupo_id and p.cuelga_de = c.posicion and p.user_id is null
    where c.user_id = v_lider and c.nivel_id = p_nivel_id and c.posicion like 'constructor%'
      and c.estado is distinct from 'plazo_vencido'
    order by p.posicion
    limit 1
    for update of p skip locked;
  end if;

  -- 2) Derrame en ese nivel
  if v_libre.id is null then
    for v_cand in
      select lib.id
      from public.grupos g
      cross join lateral (
        select p.id, p.posicion,
               c.user_id as c_user, c.estado as c_estado, c.ascendido_en as c_ascendido, c.nivel_id as c_nivel
        from public.posiciones p
        join public.posiciones c
          on c.grupo_id = p.grupo_id and c.posicion = p.cuelga_de and c.user_id is not null
        where p.grupo_id = g.id and p.user_id is null and p.posicion like 'regalador%'
        offset 0
      ) lib
      where g.nivel_id = p_nivel_id and g.estado = 'activo'
      order by case
                 when lib.c_estado = 'plazo_vencido' then 0
                 when lib.c_ascendido is null
                   or public.contar_invitados(lib.c_user, lib.c_nivel) >= 2 then 1
                 else 2
               end,
               g.creado_en, g.id, lib.posicion
    loop
      select p.* into v_libre
      from public.posiciones p
      where p.id = v_cand.id and p.user_id is null
      for update skip locked;
      exit when v_libre.id is not null;
    end loop;
    v_derrame := v_libre.id is not null;
  end if;

  -- 3) Sin lugar: lista de espera del nivel
  if v_libre.id is null then
    insert into public.lista_espera (user_id, nivel_id) values (p_user_id, p_nivel_id);
    perform public.notificar(p_user_id, 'Estás en lista de espera',
      format('Quieres repetir el nivel %s pero no hay un lugar libre de regalador. Entrarás cuando se libere uno (o el administrador te asignará un lugar).', v_nivel.nombre));
    perform public.notificar_admins('Nueva persona en lista de espera',
      format('%s quiere repetir el nivel %s y quedó en lista de espera.', v_perfil.nombre_usuario, v_nivel.nombre));
    return jsonb_build_object('resultado', 'lista_espera', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre);
  end if;

  perform public.ocupar_posicion(v_libre.id, p_user_id, true);
  perform public.notificar(p_user_id, 'Repites el nivel ' || v_nivel.nombre,
    format('Entraste como %s en el nivel %s%s. Tienes %s para hacer tu tarea, escribir al recibidor y marcarla como hecha. Cuando subas a constructor, tus referidos que te siguen entran debajo de ti; si no tienes, invita a 2 personas nuevas con tu enlace.',
           public.nombre_posicion(v_libre.posicion), v_nivel.nombre,
           case when v_derrame then ' (primer lugar libre)' else ', debajo de la persona que sigues' end,
           public.texto_duracion(public.intervalo_config('horas_tarea'))));
  v_rec := public.recibidor_de_grupo(v_libre.grupo_id);
  if v_rec is not null and v_rec <> p_user_id then
    perform public.notificar(v_rec, 'Nueva persona en tu grupo',
      format('%s entró a tu grupo del nivel %s como %s.', v_perfil.nombre_usuario, v_nivel.nombre, public.nombre_posicion(v_libre.posicion)));
  end if;
  return jsonb_build_object('resultado', 'colocado', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                            'grupo_id', v_libre.grupo_id, 'posicion', v_libre.posicion, 'derrame', v_derrame);
end;
$$;

-- Repetir del FUNDADOR con su equipo completo (lo que hacía repetir_nivel en el 25)
create or replace function public.repetir_con_equipo(p_user_id uuid, p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := p_user_id;
  v_nivel   public.niveles;
  v_perfil  public.perfiles;
  v_eq      jsonb;
  v_ids     uuid[];
  v_g       uuid;
  v_seat    text;
  v_user    uuid;
  v_pat     uuid;
  v_casilla uuid;
  v_col     jsonb := '[]'::jsonb;
  v_vac     jsonb := '[]'::jsonb;
  v_motivo  text;
begin
  select * into v_nivel from public.niveles where id = p_nivel_id;

  -- Bloqueo de los perfiles (yo + equipo) SIEMPRE en el mismo orden (sin bloqueos cruzados)
  select coalesce(jsonb_object_agg(e.posicion, jsonb_build_object('user_id', e.user_id, 'pat', e.patrocinador)), '{}'::jsonb),
         coalesce(array_agg(e.user_id), '{}')
    into v_eq, v_ids
  from public.equipo_de(v_yo) e;
  perform 1 from public.perfiles where id = any(v_ids || v_yo) order by id for update;
  select * into v_perfil from public.perfiles where id = v_yo;
  if exists (select 1 from public.posiciones where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya tienes una posición activa en el nivel %. Solo puedes tener una por nivel.', v_nivel.nombre;
  end if;

  v_g := public.crear_grupo_vacio(p_nivel_id);
  update public.grupos set tipo = 'repetido', repetido_por = v_yo where id = v_g;
  perform public.colocar_en_repetido(v_g, 'recibidor', v_yo);

  foreach v_seat in array array['constructor_1', 'constructor_2', 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'] loop
    v_user := (v_eq -> v_seat ->> 'user_id')::uuid;
    v_pat := case
               when v_seat like 'constructor%' then v_yo
               when v_seat in ('regalador_1', 'regalador_2') then (v_eq -> 'constructor_1' ->> 'user_id')::uuid
               else (v_eq -> 'constructor_2' ->> 'user_id')::uuid
             end;
    select id into v_casilla from public.posiciones where grupo_id = v_g and posicion = v_seat;

    if v_user is not null and not exists (select 1 from public.posiciones where user_id = v_user and nivel_id = p_nivel_id) then
      perform public.colocar_en_repetido(v_g, v_seat, v_user);
      v_col := v_col || jsonb_build_object('posicion', v_seat, 'nombre_usuario', (select nombre_usuario from public.perfiles where id = v_user));
      perform public.notificar(v_user, 'Tu equipo repite el nivel ' || v_nivel.nombre,
        case when v_seat like 'regalador%'
             then format('%s armó otra vez su grupo del nivel %s y tú eres %s. Tienes %s para hacer tu tarea, escribir al recibidor y marcarla como hecha.',
                         v_perfil.nombre_usuario, v_nivel.nombre, public.nombre_posicion(v_seat),
                         public.texto_duracion(public.intervalo_config('horas_tarea')))
             else format('%s armó otra vez su grupo del nivel %s y tú eres %s. No necesitas invitar: tus referidos entran como regaladores.',
                         v_perfil.nombre_usuario, v_nivel.nombre, public.nombre_posicion(v_seat))
        end);
    else
      v_motivo := case when v_user is null then 'falta' else 'ya tiene posición en este nivel' end;
      v_vac := v_vac || jsonb_build_object('posicion', v_seat, 'motivo', v_motivo,
                 'nombre_usuario', (select nombre_usuario from public.perfiles where id = v_user));
      perform public.abrir_lugar_libre(v_pat, v_casilla);
    end if;
  end loop;

  perform public.notificar(v_yo, 'Repetiste el nivel ' || v_nivel.nombre,
    format('Armaste otra vez tu grupo del nivel %s: tú estás al centro. Entraron %s de tu equipo%s.',
           v_nivel.nombre, jsonb_array_length(v_col),
           case when jsonb_array_length(v_vac) > 0
                then format(' y quedaron %s lugares libres (un constructor vacío lo llenas desde Mi grupo con tu lista de espera)', jsonb_array_length(v_vac))
                else '' end));

  return jsonb_build_object('resultado', 'equipo', 'grupo_id', v_g, 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                            'colocados', v_col, 'vacios', v_vac);
end;
$$;

-- Última repetición (registro del 26 o grupos repetidos del 25)
create or replace function public.ultima_repeticion(p_user_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select greatest((select max(creado_en) from public.repeticiones where user_id = p_user_id),
                  (select max(creado_en) from public.grupos where repetido_por = p_user_id));
$$;

-- Redefinida (25): el fundador repite con su equipo; los demás entran como regalador
create or replace function public.repetir_nivel(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_nivel  public.niveles;
  v_perfil public.perfiles;
  v_max    integer;
  v_ult    timestamptz;
  v_res    jsonb;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_nivel from public.niveles where id = p_nivel_id;
  if not found then
    raise exception 'El nivel elegido no existe.';
  end if;
  select * into v_perfil from public.perfiles where id = v_yo;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  select max(n.orden) into v_max
  from public.niveles n
  where exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id)
     or exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id);
  if v_max is null or v_nivel.orden >= v_max then
    raise exception 'Solo puedes repetir niveles inferiores al más alto que alcanzaste.';
  end if;
  if exists (select 1 from public.posiciones where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya tienes una posición activa en el nivel %. Solo puedes tener una por nivel.', v_nivel.nombre;
  end if;
  if exists (select 1 from public.lista_espera where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya estás en la lista de espera de este nivel.';
  end if;

  v_ult := public.ultima_repeticion(v_yo);
  if v_ult + public.intervalo_config('horas_espera_repetir') > now() then
    raise exception 'Debes esperar % para volver a repetir un nivel.',
      public.texto_duracion(v_ult + public.intervalo_config('horas_espera_repetir') - now());
  end if;

  if v_perfil.es_fundador then
    v_res := public.repetir_con_equipo(v_yo, p_nivel_id);
  else
    v_res := public.entrar_repitiendo(v_yo, p_nivel_id);
  end if;
  insert into public.repeticiones (user_id, nivel_id, modo)
  values (v_yo, p_nivel_id, case when v_perfil.es_fundador then 'equipo' else 'regalador' end);
  return v_res;
end;
$$;

-- Redefinida (25): además dice cómo repito ('equipo' el fundador, 'regalador' los demás)
create or replace function public.niveles_para_repetir()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo    uuid := (select auth.uid());
  v_max   integer;
  v_hasta timestamptz;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select max(n.orden) into v_max
  from public.niveles n
  where exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id)
     or exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id);
  v_hasta := public.ultima_repeticion(v_yo) + public.intervalo_config('horas_espera_repetir');
  return jsonb_build_object(
    'max_orden', v_max,
    'modo', case when (select es_fundador from public.perfiles where id = v_yo) then 'equipo' else 'regalador' end,
    'espera_hasta', case when v_hasta > now() then v_hasta end,
    'niveles', (
      select coalesce(jsonb_agg(n.id order by n.orden), '[]'::jsonb)
      from public.niveles n
      where n.orden < coalesce(v_max, 0)
        and not exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id)
        and not exists (select 1 from public.lista_espera e where e.user_id = v_yo and e.nivel_id = n.id)
    )
  );
end;
$$;

-- =====================================================================
-- 8. PERMISOS
-- =====================================================================
revoke execute on function public.contar_invitados(uuid, integer)              from public, anon, authenticated;
revoke execute on function public.casilla_equipo_rep(uuid)                     from public, anon, authenticated;
revoke execute on function public.limitar_referidos()                          from public, anon, authenticated;
revoke execute on function public.equipo_rep_tras_alta()                       from public, anon, authenticated;
revoke execute on function public.entrar_repitiendo(uuid, integer)             from public, anon, authenticated;
revoke execute on function public.repetir_con_equipo(uuid, integer)            from public, anon, authenticated;
revoke execute on function public.ultima_repeticion(uuid)                      from public, anon, authenticated;
revoke execute on function public.repetir_nivel(integer)                       from public, anon;
revoke execute on function public.niveles_para_repetir()                       from public, anon;
grant  execute on function public.repetir_nivel(integer)                       to authenticated;
grant  execute on function public.niveles_para_repetir()                       to authenticated;
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
