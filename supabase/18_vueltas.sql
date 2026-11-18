-- =====================================================================
-- Sistema Siembra tu Futuro — 18_vueltas.sql
-- Ejecutar DESPUÉS de 01 a 17. Se puede volver a ejecutar sin problema.
-- Si más adelante re-ejecutas 05, 07, 10, 11 o 13, vuelve a ejecutar este archivo después.
--
-- VUELTAS: una persona puede volver a niveles que ya completó y estar en varios niveles a la vez.
--   * Cada entrada al nivel 1 (el de menor orden) después de haberlo completado empieza una
--     VUELTA nueva (vuelta 1, 2, 3… sin límite). En cada vuelta se recorre los niveles en orden.
--   * Una sola posición por nivel EN CADA VUELTA; dos posiciones en el mismo nivel solo si son
--     de vueltas distintas.
--   * Para volver al nivel 1 hay que haberlo completado en la vuelta actual.
--   * Quien REPITE un nivel (ya lo completó en otra vuelta) va debajo de su invitador si está
--     en ese nivel; si no, al primer lugar libre de regalador de cualquier grupo activo de ese
--     nivel ("derrame"). Solo si no hay ningún lugar libre queda en lista de espera.
--   * Cada ciclo completado se guarda (una fila por nivel y vuelta). "Niveles completados"
--     cuenta niveles distintos.
--   * El fundador puede crear grupo nuevo como recibidor también en niveles ya completados.
--   * Referidos por vuelta: en cada vuelta el enlace permite 2 personas nuevas; cada invitado
--     queda unido a la vuelta en que fue invitado (perfiles.invitado_vuelta) y su invitador lo
--     cuenta como "invitado" solo en esa vuelta.
--
-- Antes de cambiar nada se RESPALDA ciclos_completados en ciclos_completados_respaldo_18.
-- =====================================================================

-- =====================================================================
-- 0. RESPALDO de ciclos_completados (solo la primera vez que se ejecuta)
-- =====================================================================
create table if not exists public.ciclos_completados_respaldo_18 as
  table public.ciclos_completados;
alter table public.ciclos_completados_respaldo_18 enable row level security;
revoke all on table public.ciclos_completados_respaldo_18 from anon, authenticated;
-- Para revisar el respaldo:  select * from public.ciclos_completados_respaldo_18;

-- =====================================================================
-- 1. COLUMNAS Y RESTRICCIONES
-- =====================================================================
-- Vuelta en la que va cada persona (empieza en 1) y vuelta de su patrocinador al invitarla
alter table public.perfiles add column if not exists vuelta_actual integer not null default 1;
alter table public.perfiles add column if not exists invitado_vuelta integer;
alter table public.perfiles drop constraint if exists perfiles_vuelta_actual_chk;
alter table public.perfiles add constraint perfiles_vuelta_actual_chk check (vuelta_actual >= 1);
update public.perfiles set invitado_vuelta = 1 where invitado_por is not null and invitado_vuelta is null;

-- Posiciones: vuelta de quien ocupa la casilla (vacía = null)
alter table public.posiciones add column if not exists vuelta integer;
update public.posiciones set vuelta = 1 where user_id is not null and vuelta is null;
update public.posiciones set vuelta = null where user_id is null and vuelta is not null;
alter table public.posiciones drop constraint if exists posiciones_usuario_nivel_uk;
alter table public.posiciones drop constraint if exists posiciones_usuario_nivel_vuelta_uk;
alter table public.posiciones add constraint posiciones_usuario_nivel_vuelta_uk unique (user_id, nivel_id, vuelta);

-- Lista de espera: por nivel y vuelta
alter table public.lista_espera add column if not exists vuelta integer not null default 1;
alter table public.lista_espera drop constraint if exists lista_espera_pkey;
alter table public.lista_espera add constraint lista_espera_pkey primary key (user_id, nivel_id, vuelta);

-- Ciclos completados: historial (una fila por nivel y vuelta)
alter table public.ciclos_completados add column if not exists vuelta integer not null default 1;
alter table public.ciclos_completados add column if not exists id bigint generated always as identity;
alter table public.ciclos_completados drop constraint if exists ciclos_completados_pkey;
alter table public.ciclos_completados add constraint ciclos_completados_pkey primary key (id);
create unique index if not exists ciclos_usuario_nivel_vuelta_uk
  on public.ciclos_completados (user_id, nivel_id, vuelta);
comment on table public.ciclos_completados is 'Historial: recibidores que recibieron sus 4 tareas, por nivel y vuelta. Habilitan el nivel siguiente en esa vuelta.';

-- Red de seguridad: casilla vacía => sin vuelta; ocupada sin vuelta => la vuelta actual de la persona
create or replace function public.posiciones_poner_vuelta()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is null then
    new.vuelta := null;
  elsif new.vuelta is null then
    select coalesce(pe.vuelta_actual, 1) into new.vuelta from public.perfiles pe where pe.id = new.user_id;
    new.vuelta := coalesce(new.vuelta, 1);
  end if;
  return new;
end;
$$;
drop trigger if exists posiciones_poner_vuelta on public.posiciones;
create trigger posiciones_poner_vuelta
  before insert or update on public.posiciones
  for each row execute function public.posiciones_poner_vuelta();

-- =====================================================================
-- 2. ¿EN QUÉ VUELTA ENTRA ALGUIEN A UN NIVEL?
-- =====================================================================
-- Devuelve la vuelta en la que la persona puede entrar al nivel, o null si no puede.
--   Nivel 1: su vuelta actual si todavía no está en ese nivel en esa vuelta; si ya lo completó
--            en su vuelta actual, la vuelta siguiente (vuelta nueva).
--   Otros:   la vuelta más baja donde completó el nivel anterior y todavía no está, ni espera,
--            ni completó este nivel.
create or replace function public.vuelta_para_participar(p_user_id uuid, p_nivel_id integer)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actual integer;
  v_ant    integer := public.nivel_anterior(p_nivel_id);
  v        integer;
begin
  select vuelta_actual into v_actual from public.perfiles where id = p_user_id;
  if v_actual is null then
    return null;
  end if;

  if v_ant is null then
    if exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = p_nivel_id and vuelta = v_actual)
       or exists (select 1 from public.lista_espera where user_id = p_user_id and nivel_id = p_nivel_id and vuelta = v_actual) then
      return null;
    end if;
    if exists (select 1 from public.ciclos_completados where user_id = p_user_id and nivel_id = p_nivel_id and vuelta = v_actual) then
      return v_actual + 1;
    end if;
    return v_actual;
  end if;

  for v in 1 .. v_actual loop
    if exists (select 1 from public.ciclos_completados where user_id = p_user_id and nivel_id = v_ant and vuelta = v)
       and not exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = p_nivel_id and vuelta = v)
       and not exists (select 1 from public.lista_espera where user_id = p_user_id and nivel_id = p_nivel_id and vuelta = v)
       and not exists (select 1 from public.ciclos_completados where user_id = p_user_id and nivel_id = p_nivel_id and vuelta = v) then
      return v;
    end if;
  end loop;
  return null;
end;
$$;

-- Vuelta para una asignación del administrador: la de su lista de espera en ese nivel;
-- si no espera, la vuelta en la que podría participar; si no, su vuelta actual.
create or replace function public.vuelta_para_asignar(p_user_id uuid, p_nivel_id integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select min(vuelta) from public.lista_espera where user_id = p_user_id and nivel_id = p_nivel_id),
    public.vuelta_para_participar(p_user_id, p_nivel_id),
    (select vuelta_actual from public.perfiles where id = p_user_id),
    1);
$$;

-- Invitados de una persona EN UNA VUELTA que ya tienen posición en el nivel
create or replace function public.contar_invitados_vuelta(p_user_id uuid, p_nivel_id integer, p_vuelta integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
  from public.perfiles pe
  where pe.invitado_por = p_user_id
    and coalesce(pe.invitado_vuelta, 1) = coalesce(p_vuelta, 1)
    and exists (select 1 from public.posiciones po where po.user_id = pe.id and po.nivel_id = p_nivel_id);
$$;

-- =====================================================================
-- 3. OCUPAR / LIBERAR / VALIDAR CASILLAS (con vuelta)
-- =====================================================================
drop function if exists public.ocupar_posicion(uuid, uuid, boolean);
create or replace function public.ocupar_posicion(p_posicion_id uuid, p_user_id uuid, p_con_relojes boolean, p_vuelta integer default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nivel  integer;
  v_vuelta integer;
begin
  select nivel_id into v_nivel from public.posiciones where id = p_posicion_id;
  v_vuelta := coalesce(p_vuelta, public.vuelta_para_asignar(p_user_id, v_nivel));

  -- Entrar en una vuelta mayor a la actual empieza esa vuelta
  update public.perfiles set vuelta_actual = v_vuelta where id = p_user_id and vuelta_actual < v_vuelta;

  update public.posiciones
     set user_id        = p_user_id,
         vuelta         = v_vuelta,
         asignado_en    = now(),
         origen         = case when p_con_relojes then 'automatico' else 'admin' end,
         estado         = case when posicion like 'regalador%' then 'reservada' end,
         reservada_en   = case when p_con_relojes and posicion like 'regalador%' then now() end,
         ascendido_en   = case when p_con_relojes and posicion like 'constructor%' then now() end,
         tarea_hecha_en = null,
         aviso_enviado  = false
   where id = p_posicion_id;

  delete from public.lista_espera
   where user_id = p_user_id and nivel_id = v_nivel and vuelta = v_vuelta;
end;
$$;

create or replace function public.liberar_posicion(p_posicion_id uuid, p_estado text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.posiciones
     set user_id = null, vuelta = null, origen = null, estado = p_estado, asignado_en = null,
         reservada_en = null, tarea_hecha_en = null, ascendido_en = null, aviso_enviado = false
   where id = p_posicion_id;
$$;

create or replace function public.validar_asignacion(p_posicion_id uuid, p_user_id uuid)
returns public.posiciones
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos public.posiciones;
  v_requisito text;
  v_vuelta integer;
begin
  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if exists (select 1 from public.grupos where id = v_pos.grupo_id and estado <> 'activo') then
    raise exception 'Ese grupo ya se completó y se dividió. Usa uno de los grupos activos.';
  end if;
  if not exists (select 1 from public.perfiles where id = p_user_id) then
    raise exception 'Ese usuario no existe.';
  end if;
  if v_pos.user_id = p_user_id then
    raise exception 'Esa persona ya está en esta casilla.';
  end if;
  v_vuelta := public.vuelta_para_asignar(p_user_id, v_pos.nivel_id);
  if exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = v_pos.nivel_id and vuelta = v_vuelta) then
    raise exception 'Ese usuario ya tiene una posición en este nivel en su vuelta %.', v_vuelta;
  end if;

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
      raise exception 'Primero asigna la casilla %.', public.nombre_posicion(v_requisito);
    end if;
  end if;

  return v_pos;
end;
$$;

drop function if exists public.colocar_ascendido(uuid, text, uuid);
create or replace function public.colocar_ascendido(p_grupo_id uuid, p_posicion text, p_user_id uuid, p_vuelta integer default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.posiciones
     set user_id        = p_user_id,
         vuelta         = p_vuelta,
         asignado_en    = now(),
         origen         = 'automatico',
         estado         = null,
         reservada_en   = null,
         tarea_hecha_en = null,
         aviso_enviado  = false,
         ascendido_en   = case when p_posicion like 'constructor%' then now() end
   where grupo_id = p_grupo_id and posicion = p_posicion and p_user_id is not null;
$$;

-- =====================================================================
-- 4. PARTICIPAR (con vueltas y derrame)
-- =====================================================================
create or replace function public.participar(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo         uuid := (select auth.uid());
  v_nivel      public.niveles;
  v_perfil     public.perfiles;
  v_pos_inv    public.posiciones;
  v_libre      public.posiciones;
  v_grupo      uuid;
  v_recibidor  uuid;
  v_primero    boolean;
  v_vuelta     integer;
  v_repite     boolean;
  v_nueva      boolean := false;
  v_derrame    boolean := false;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;

  select * into v_nivel from public.niveles where id = p_nivel_id;
  if not found then
    raise exception 'El nivel elegido no existe.';
  end if;

  -- Bloquea mi perfil: evita que un doble toque me coloque dos veces
  select * into v_perfil from public.perfiles where id = v_yo for update;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  v_primero := public.nivel_anterior(p_nivel_id) is null;
  v_vuelta  := public.vuelta_para_participar(v_yo, p_nivel_id);

  if v_vuelta is null then
    if v_primero then
      if exists (select 1 from public.lista_espera where user_id = v_yo and nivel_id = p_nivel_id and vuelta = v_perfil.vuelta_actual) then
        raise exception 'Ya estás en la lista de espera de este nivel.';
      end if;
      raise exception 'Ya tienes una posición en este nivel en tu vuelta %. Cuando lo completes podrás empezar una vuelta nueva.', v_perfil.vuelta_actual;
    end if;
    if not public.nivel_habilitado(v_yo, p_nivel_id) then
      raise exception 'Este nivel todavía no está habilitado para ti. Primero completa el nivel anterior.';
    end if;
    raise exception 'Ya participas en este nivel en todas tus vueltas habilitadas. Completa el nivel anterior en otra vuelta para volver a entrar.';
  end if;

  -- ¿Ya completó este nivel en otra vuelta? Entonces "repite" (derrame si no hay lugar con su invitador)
  v_repite := exists (select 1 from public.ciclos_completados where user_id = v_yo and nivel_id = p_nivel_id);

  -- Volver al nivel 1 después de completarlo: empieza una vuelta nueva
  if v_vuelta > v_perfil.vuelta_actual then
    update public.perfiles set vuelta_actual = v_vuelta where id = v_yo;
    v_nueva := true;
  end if;

  -- (Niveles 2 en adelante) Fundador: crea su propio grupo como recibidor (también si repite)
  if not v_primero and v_perfil.es_fundador then
    v_grupo := public.crear_grupo_vacio(p_nivel_id);
    select * into v_libre from public.posiciones where grupo_id = v_grupo and posicion = 'recibidor';
  else
    -- Grupo activo del invitador en este nivel (primero el de la vuelta en que me invitó)
    if v_perfil.invitado_por is not null then
      select po.* into v_pos_inv
      from public.posiciones po
      join public.grupos g on g.id = po.grupo_id and g.estado = 'activo'
      where po.user_id = v_perfil.invitado_por and po.nivel_id = p_nivel_id
      order by (po.vuelta = coalesce(v_perfil.invitado_vuelta, 1)) desc, po.vuelta desc
      limit 1;
    end if;

    if v_pos_inv.id is not null then
      if v_primero then
        -- Solo regaladores: primero debajo del invitador (si es constructor), luego el primero libre
        select p.* into v_libre
        from public.posiciones p
        where p.grupo_id = v_pos_inv.grupo_id
          and p.user_id is null
          and p.posicion like 'regalador%'
          and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
        order by (p.cuelga_de = v_pos_inv.posicion) desc,
                 array_position(array['regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], p.posicion)
        limit 1
        for update skip locked;
      elsif v_pos_inv.posicion = 'recibidor' then
        select p.* into v_libre
        from public.posiciones p
        where p.grupo_id = v_pos_inv.grupo_id
          and p.user_id is null
          and p.posicion in ('constructor_1', 'constructor_2')
          and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
        order by p.posicion
        limit 1
        for update skip locked;
      elsif v_pos_inv.posicion like 'constructor%' then
        select p.* into v_libre
        from public.posiciones p
        where p.grupo_id = v_pos_inv.grupo_id
          and p.user_id is null
          and p.cuelga_de = v_pos_inv.posicion
          and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
        order by p.posicion
        limit 1
        for update skip locked;
      end if;
    end if;

    -- Derrame: quien repite el nivel va al primer regalador libre de cualquier grupo activo
    if v_libre.id is null and v_repite then
      select p.* into v_libre
      from public.posiciones p
      join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
      where p.nivel_id = p_nivel_id
        and p.user_id is null
        and p.posicion like 'regalador%'
        and exists (select 1 from public.posiciones c
                    where c.grupo_id = p.grupo_id and c.posicion = p.cuelga_de and c.user_id is not null)
        and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
      order by g.creado_en,
               array_position(array['regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], p.posicion)
      limit 1
      for update of p skip locked;
      v_derrame := v_libre.id is not null;
    end if;
  end if;

  if v_nueva then
    perform public.notificar(v_yo, 'Empezaste la vuelta ' || v_vuelta,
      format('Volviste al nivel %s y empezaste tu vuelta %s. Tu enlace de invitación vuelve a tener lugar para 2 personas nuevas, que te seguirán en los niveles de esta vuelta.',
             v_nivel.nombre, v_vuelta));
  end if;

  -- Sin lugar -> lista de espera (de esta vuelta)
  if v_libre.id is null then
    insert into public.lista_espera (user_id, nivel_id, vuelta) values (v_yo, p_nivel_id, v_vuelta);
    perform public.notificar(v_yo, 'Estás en lista de espera',
      format('No hay un lugar libre para ti en el nivel %s (vuelta %s). El administrador te asignará un lugar.', v_nivel.nombre, v_vuelta));
    perform public.notificar_admins('Nueva persona en lista de espera',
      format('%s tocó Participar en el nivel %s (vuelta %s) y quedó en lista de espera.', v_perfil.nombre_usuario, v_nivel.nombre, v_vuelta));
    return jsonb_build_object('resultado', 'lista_espera', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                              'vuelta', v_vuelta, 'nueva_vuelta', v_nueva);
  end if;

  perform public.ocupar_posicion(v_libre.id, v_yo, true, v_vuelta);

  perform public.notificar_lugar(v_yo, v_libre.posicion, v_nivel.nombre,
    case when v_libre.posicion = 'recibidor'
         then format('Como fundador creaste un grupo nuevo en el nivel %s (vuelta %s) y eres su recibidor.', v_nivel.nombre, v_vuelta)
         else format('Ocupas la posición %s en el nivel %s (vuelta %s).', public.nombre_posicion(v_libre.posicion), v_nivel.nombre, v_vuelta)
    end);

  v_recibidor := public.recibidor_de_grupo(v_libre.grupo_id);
  if v_recibidor is not null and v_recibidor <> v_yo then
    perform public.notificar(v_recibidor, 'Nueva persona en tu grupo',
      format('%s entró a tu grupo del nivel %s como %s.',
             v_perfil.nombre_usuario, v_nivel.nombre, public.nombre_posicion(v_libre.posicion)));
  end if;

  return jsonb_build_object('resultado', 'colocado', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                            'grupo_id', v_libre.grupo_id, 'posicion', v_libre.posicion,
                            'vuelta', v_vuelta, 'nueva_vuelta', v_nueva, 'derrame', v_derrame);
end;
$$;

-- =====================================================================
-- 5. ASCENSO: guarda el ciclo con su vuelta y cada ascendido conserva su vuelta
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
  v_vrec   integer;
  v_vc1    integer;
  v_vc2    integer;
  v_vr     integer[];
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

  select (array_agg(user_id) filter (where posicion = 'recibidor'))[1],
         (array_agg(user_id) filter (where posicion = 'constructor_1'))[1],
         (array_agg(user_id) filter (where posicion = 'constructor_2'))[1],
         array[
           (array_agg(user_id) filter (where posicion = 'regalador_1'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_2'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_3'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_4'))[1]
         ],
         (array_agg(vuelta) filter (where posicion = 'recibidor'))[1],
         (array_agg(vuelta) filter (where posicion = 'constructor_1'))[1],
         (array_agg(vuelta) filter (where posicion = 'constructor_2'))[1],
         array[
           (array_agg(vuelta) filter (where posicion = 'regalador_1'))[1],
           (array_agg(vuelta) filter (where posicion = 'regalador_2'))[1],
           (array_agg(vuelta) filter (where posicion = 'regalador_3'))[1],
           (array_agg(vuelta) filter (where posicion = 'regalador_4'))[1]
         ]
    into v_rec, v_c1, v_c2, v_r, v_vrec, v_vc1, v_vc2, v_vr
  from public.posiciones
  where grupo_id = p_grupo_id;

  if v_rec is not null then
    insert into public.ciclos_completados (user_id, nivel_id, vuelta, grupo_id)
    values (v_rec, v_nivel.id, coalesce(v_vrec, 1), p_grupo_id)
    on conflict (user_id, nivel_id, vuelta) do update
      set grupo_id = excluded.grupo_id, completado_en = now();
  end if;

  update public.posiciones
     set user_id = null, vuelta = null, origen = null, estado = null, asignado_en = null,
         reservada_en = null, tarea_hecha_en = null, ascendido_en = null, aviso_enviado = false
   where grupo_id = p_grupo_id;
  update public.grupos set estado = 'completado' where id = p_grupo_id;

  v_a := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_a, 'recibidor',     v_c1,   v_vc1);
  perform public.colocar_ascendido(v_a, 'constructor_1', v_r[1], v_vr[1]);
  perform public.colocar_ascendido(v_a, 'constructor_2', v_r[2], v_vr[2]);

  v_b := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_b, 'recibidor',     v_c2,   v_vc2);
  perform public.colocar_ascendido(v_b, 'constructor_1', v_r[3], v_vr[3]);
  perform public.colocar_ascendido(v_b, 'constructor_2', v_r[4], v_vr[4]);

  -- Último nivel según el ORDEN (no según el id)
  v_ultimo := public.nivel_siguiente(v_nivel.id) is null;
  perform public.notificar(v_rec, 'Completaste el nivel ' || v_nivel.nombre,
    case when v_ultimo
         then format('Completaste el nivel %s (vuelta %s), el último nivel. ¡Felicitaciones! Puedes volver a empezar desde el primer nivel en una vuelta nueva.', v_nivel.nombre, coalesce(v_vrec, 1))
         else format('Completaste el nivel %s (vuelta %s). Ya puedes participar en el siguiente desde Niveles.', v_nivel.nombre, coalesce(v_vrec, 1))
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
-- 6. RELOJES Y PLAZOS: los invitados se cuentan en la vuelta del constructor
-- =====================================================================
drop function if exists public.mi_reloj(integer);
create or replace function public.mi_reloj(p_nivel_id integer default null, p_vuelta integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo   uuid := (select auth.uid());
  v_pos  public.posiciones;
  v_id   uuid;
  v_fase text;
  v_inv  int;
  v_nivel text;
  v_rec  uuid;
begin
  select x.id, x.fase into v_id, v_fase
  from (
    select p.id, n.orden, p.vuelta,
           case
             when p.posicion like 'regalador%' and p.origen = 'automatico' and p.estado = 'reservada' then 'tarea'
             when p.posicion like 'regalador%' and p.origen = 'automatico' and p.estado in ('tarea_hecha', 'confirmada') then 'esperando'
             when p.posicion like 'constructor%' and p.ascendido_en is not null and p.estado = 'plazo_vencido' then 'plazo_vencido'
             when p.posicion like 'constructor%' and p.ascendido_en is not null then
               case when public.contar_invitados_vuelta(v_yo, p.nivel_id, p.vuelta) >= 2 then 'listo' else 'invitar' end
           end as fase
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = v_yo
      and (p_nivel_id is null or p.nivel_id = p_nivel_id)
      and (p_vuelta is null or p.vuelta = p_vuelta)
  ) x
  where x.fase is not null
  order by array_position(array['tarea', 'plazo_vencido', 'invitar', 'esperando', 'listo'], x.fase), x.orden desc, x.vuelta desc
  limit 1;

  if v_fase is null then
    return null;
  end if;

  select * into v_pos from public.posiciones where id = v_id;
  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  v_rec := public.recibidor_de_grupo(v_pos.grupo_id);
  v_inv := public.contar_invitados_vuelta(v_yo, v_pos.nivel_id, v_pos.vuelta);

  return jsonb_build_object(
    'ahora',              now(),
    'fase',               v_fase,
    'posicion_id',        v_pos.id,
    'posicion',           v_pos.posicion,
    'nivel_id',           v_pos.nivel_id,
    'nivel_nombre',       v_nivel,
    'vuelta',             v_pos.vuelta,
    'estado',             v_pos.estado,
    'reservada_en',       v_pos.reservada_en,
    'fin_tarea',          v_pos.reservada_en + public.intervalo_config('horas_tarea'),
    'tarea_hecha_en',     v_pos.tarea_hecha_en,
    'ascendido_en',       v_pos.ascendido_en,
    'fin_invitar',        v_pos.ascendido_en + public.dias_invitar_de(v_pos.nivel_id),
    'dias_invitar',       public.dias_invitar_valor(v_pos.nivel_id),
    'invitados',          v_inv,
    'aprobadas',          (select count(*) from public.posiciones
                            where grupo_id = v_pos.grupo_id and posicion like 'regalador%'
                              and user_id is not null and estado = 'confirmada'),
    'recibidor_nombre',   (select nombre_usuario from public.perfiles where id = v_rec),
    'recibidor_whatsapp', case when v_rec is not null then public.whatsapp_de(v_rec) end
  );
end;
$$;

create or replace function public.revisar_plazos()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r           record;
  v_tarea     interval := public.intervalo_config('horas_tarea');
  v_aviso     interval := public.intervalo_config('horas_aviso');
  v_retirados int := 0;
  v_avisos    int := 0;
  v_vencidos  int := 0;
begin
  -- (a) Regalador reservado sin tarea hecha y pasaron horas_tarea: sale de la posición
  for r in
    select p.id, p.user_id, p.posicion, p.nivel_id, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.origen = 'automatico' and p.posicion like 'regalador%'
      and p.estado = 'reservada' and p.tarea_hecha_en is null
      and p.reservada_en + v_tarea <= now()
    for update of p skip locked
  loop
    perform public.liberar_posicion(r.id, 'retirada');
    perform public.notificar(r.user_id, 'Se acabó tu tiempo',
      format('Pasaron %s sin que marcaras tu tarea como hecha y saliste de la posición %s del nivel %s. Puedes volver a tocar Participar.',
             public.texto_duracion(v_tarea), public.nombre_posicion(r.posicion), r.nivel));
    perform public.avisar_patrocinador(r.user_id, r.posicion, r.nivel_id,
      'salió de su posición porque se acabó su tiempo para hacer la tarea. Tienes un lugar disponible.');
    perform public.avisar_lista_espera(r.nivel_id);
    v_retirados := v_retirados + 1;
  end loop;

  -- (b) A las horas_aviso sin tarea hecha: aviso (una sola vez)
  for r in
    select p.id, p.user_id, p.reservada_en, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.origen = 'automatico' and p.posicion like 'regalador%'
      and p.estado = 'reservada' and p.tarea_hecha_en is null
      and not p.aviso_enviado
      and p.reservada_en + v_aviso <= now()
    for update of p skip locked
  loop
    update public.posiciones set aviso_enviado = true where id = r.id;
    perform public.notificar(r.user_id, 'Se acaba tu tiempo',
      format('Te quedan unos %s para hacer tu tarea del nivel %s. Escribe al recibidor por WhatsApp y márcala como hecha o perderás tu lugar.',
             public.texto_duracion(r.reservada_en + v_tarea - now()), r.nivel));
    v_avisos := v_avisos + 1;
  end loop;

  -- (c) Constructor: días del nivel desde ascendido_en con menos de 2 invitados (de su vuelta) con posición
  for r in
    select p.id, p.user_id, p.nivel_id, n.nombre as nivel, pe.nombre_usuario, pe.invitado_por
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    join public.perfiles pe on pe.id = p.user_id
    where p.posicion like 'constructor%'
      and p.ascendido_en is not null
      and p.estado is null
      and p.ascendido_en + public.dias_invitar_de(p.nivel_id) <= now()
      and public.contar_invitados_vuelta(p.user_id, p.nivel_id, p.vuelta) < 2
    for update of p skip locked
  loop
    update public.posiciones set estado = 'plazo_vencido' where id = r.id;
    perform public.notificar(r.user_id, 'Plazo vencido',
      format('Pasaron %s desde que subiste a constructor y no completaste tus 2 invitados en el nivel %s. Tu posición quedó suspendida y quien te invitó puede reemplazarte.',
             public.texto_dias_invitar(r.nivel_id), r.nivel));
    perform public.notificar(r.invitado_por, 'Tu invitado tiene el plazo vencido',
      format('%s no completó sus 2 invitados a tiempo en el nivel %s. En Mi grupo puedes usar "Retirar y reemplazar" para poner a alguien que invitaste y esté en lista de espera.',
             r.nombre_usuario, r.nivel));
    perform public.notificar_admins('Plazo vencido',
      format('%s (constructor, nivel %s) no completó sus 2 invitados a tiempo.', r.nombre_usuario, r.nivel));
    v_vencidos := v_vencidos + 1;
  end loop;

  return jsonb_build_object('retirados', v_retirados, 'avisos', v_avisos, 'plazos_vencidos', v_vencidos);
end;
$$;

-- =====================================================================
-- 7. RETIRAR Y REEMPLAZAR: el reemplazo entra en la vuelta de su lista de espera
-- =====================================================================
create or replace function public.retirar_y_reemplazar(p_posicion_id uuid, p_nuevo_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo           uuid := (select auth.uid());
  v_pos          public.posiciones;
  v_invitador    uuid;
  v_es_invitador boolean;
  v_retirado     uuid;
  v_nivel        text;
  v_vuelta_nueva integer;
begin
  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla ya está libre.';
  end if;

  v_retirado := v_pos.user_id;
  select invitado_por into v_invitador from public.perfiles where id = v_retirado;
  v_es_invitador := v_invitador is not null and v_invitador = v_yo;

  if not (public.es_admin() or v_es_invitador) then
    raise exception 'Solo el administrador o quien invitó a esta persona puede retirarla.';
  end if;
  if not v_es_invitador and v_pos.estado is distinct from 'plazo_vencido' then
    raise exception 'Solo se puede retirar a alguien cuando su plazo está vencido.';
  end if;
  if v_invitador is null then
    raise exception 'Esta persona no tiene invitador. Usa "Reemplazar" en la pestaña Grupos.';
  end if;

  if p_nuevo_user_id is null or p_nuevo_user_id = v_retirado then
    raise exception 'Elige a otra persona para el reemplazo.';
  end if;
  if not exists (select 1 from public.perfiles where id = p_nuevo_user_id and invitado_por = v_invitador) then
    raise exception 'La persona nueva debe ser alguien invitado por quien invitó a la persona retirada.';
  end if;
  select min(vuelta) into v_vuelta_nueva
  from public.lista_espera where user_id = p_nuevo_user_id and nivel_id = v_pos.nivel_id;
  if v_vuelta_nueva is null then
    raise exception 'La persona nueva debe estar en la lista de espera de este nivel.';
  end if;
  if exists (select 1 from public.posiciones where user_id = p_nuevo_user_id and nivel_id = v_pos.nivel_id and vuelta = v_vuelta_nueva) then
    raise exception 'La persona nueva ya tiene una posición en este nivel.';
  end if;

  perform public.liberar_posicion(p_posicion_id, 'retirada');
  perform public.ocupar_posicion(p_posicion_id, p_nuevo_user_id, true, v_vuelta_nueva);

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;

  perform public.notificar(v_retirado, 'Fuiste retirado de tu posición',
    format('Saliste de la posición %s del nivel %s y tu lugar fue asignado a otra persona.',
           public.nombre_posicion(v_pos.posicion), v_nivel));
  perform public.notificar_lugar(p_nuevo_user_id, v_pos.posicion, v_nivel,
    format('Te colocaron como %s en el nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));

  -- Si lo hizo el administrador, el patrocinador se entera
  if not v_es_invitador then
    perform public.avisar_patrocinador(v_retirado, v_pos.posicion, v_pos.nivel_id,
      format('fue retirado por plazo vencido y su lugar lo ocupa %s.',
             (select nombre_usuario from public.perfiles where id = p_nuevo_user_id)));
  end if;
end;
$$;

-- =====================================================================
-- 8. REFERIDOS POR VUELTA: 2 personas nuevas en cada vuelta
-- =====================================================================
create or replace function public.contar_referidos(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
  from public.perfiles r
  where r.invitado_por = p_user_id
    and coalesce(r.invitado_vuelta, 1) = coalesce((select vuelta_actual from public.perfiles where id = p_user_id), 1);
$$;

create or replace function public.limitar_referidos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vuelta integer;
begin
  if new.invitado_por is null then
    new.invitado_vuelta := null;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.invitado_por is not distinct from old.invitado_por then
    return new;
  end if;

  -- Bloquea al patrocinador y toma su vuelta actual: el invitado queda unido a esa vuelta
  select vuelta_actual into v_vuelta from public.perfiles where id = new.invitado_por for update;
  new.invitado_vuelta := coalesce(v_vuelta, 1);

  if (select count(*) from public.perfiles
       where invitado_por = new.invitado_por
         and coalesce(invitado_vuelta, 1) = new.invitado_vuelta
         and id <> new.id) >= 2 then
    raise exception 'Tu patrocinador ya tiene sus 2 referidos y no puede recibir más por ahora. Por favor contáctate con la persona que te invitó.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;
-- (el trigger perfiles_limitar_referidos de 10 ya llama a esta función)

-- =====================================================================
-- 9. RESÚMENES PARA LA PÁGINA
-- =====================================================================
create or replace function public.mi_resumen_perfil()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_perfil public.perfiles;
  v_actual public.niveles;
begin
  select * into v_perfil from public.perfiles where id = v_yo;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  -- Nivel actual: el de mayor orden donde tengo posición; si no, el primer habilitado sin completar
  select n.* into v_actual
  from public.posiciones p join public.niveles n on n.id = p.nivel_id
  where p.user_id = v_yo
  order by n.orden desc, p.vuelta desc limit 1;

  if v_actual.id is null then
    select n.* into v_actual
    from public.niveles n
    where public.nivel_habilitado(v_yo, n.id)
      and not exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id)
    order by n.orden limit 1;
  end if;

  return jsonb_build_object(
    'nombre_usuario',      v_perfil.nombre_usuario,
    'miembro_desde',       v_perfil.creado_en,
    'vuelta_actual',       v_perfil.vuelta_actual,
    'tareas_regaladas',    (select count(*) from public.tareas_historial where regalador_id = v_yo),
    'tareas_recibidas',    (select count(*) from public.tareas_historial where recibidor_id = v_yo),
    'niveles_completados', (select count(distinct nivel_id) from public.ciclos_completados where user_id = v_yo),
    'ciclos_completados',  (select count(*) from public.ciclos_completados where user_id = v_yo),
    'total_niveles',       (select count(*) from public.niveles),
    'nivel_actual',        case when v_actual.id is null then null
                                else jsonb_build_object('id', v_actual.id, 'nombre', v_actual.nombre, 'orden', v_actual.orden) end,
    'referidos',           public.contar_referidos(v_yo),
    'en_espera',           exists (select 1 from public.lista_espera where user_id = v_yo),
    'niveles', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nivel_id', n.id,
               'nombre',   n.nombre,
               'orden',    n.orden,
               'posicion', (select p.posicion from public.posiciones p
                             where p.user_id = v_yo and p.nivel_id = n.id order by p.vuelta desc limit 1),
               'estado',   case
                             when exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id) then 'actual'
                             when exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id) then 'completado'
                             when public.nivel_habilitado(v_yo, n.id) then 'habilitado'
                             else 'bloqueado'
                           end
             ) order by n.orden), '[]'::jsonb)
      from public.niveles n
    )
  );
end;
$$;

drop function if exists public.mi_grupo_resumen(integer);
create or replace function public.mi_grupo_resumen(p_nivel_id integer, p_vuelta integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_grupo  uuid;
  v_vuelta integer;
begin
  select p.grupo_id, p.vuelta into v_grupo, v_vuelta
  from public.posiciones p
  join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
  where p.user_id = v_yo and p.nivel_id = p_nivel_id
    and (p_vuelta is null or p.vuelta = p_vuelta)
  order by p.vuelta desc
  limit 1;

  if v_grupo is null then
    return null;
  end if;

  return jsonb_build_object(
    'nivel_id',  p_nivel_id,
    'nivel',     (select nombre from public.niveles where id = p_nivel_id),
    'vuelta',    v_vuelta,
    'mi_posicion', (select posicion from public.posiciones where grupo_id = v_grupo and user_id = v_yo),
    'recibidor', (select pe.nombre_usuario from public.posiciones p
                    left join public.perfiles pe on pe.id = p.user_id
                   where p.grupo_id = v_grupo and p.posicion = 'recibidor'),
    'casillas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'posicion', p.posicion,
               'nombre_usuario', pe.nombre_usuario,
               'estado', p.estado
             ) order by p.posicion), '[]'::jsonb)
      from public.posiciones p
      left join public.perfiles pe on pe.id = p.user_id
      where p.grupo_id = v_grupo and p.posicion <> 'recibidor'
    ),
    'tareas_aprobadas', (select count(*) from public.posiciones
                          where grupo_id = v_grupo and posicion like 'regalador%'
                            and user_id is not null and estado = 'confirmada')
  );
end;
$$;

-- Todo lo que la página necesita para Inicio, Niveles y Mi grupo con vueltas
create or replace function public.mis_vueltas()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_perfil public.perfiles;
begin
  select * into v_perfil from public.perfiles where id = v_yo;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  return jsonb_build_object(
    'vuelta_actual', v_perfil.vuelta_actual,
    'referidos',     public.contar_referidos(v_yo),
    'posiciones', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'grupo_id', p.grupo_id, 'nivel_id', p.nivel_id, 'vuelta', p.vuelta,
               'posicion', p.posicion, 'estado', p.estado, 'origen', p.origen
             ) order by n.orden, p.vuelta), '[]'::jsonb)
      from public.posiciones p join public.niveles n on n.id = p.nivel_id
      where p.user_id = v_yo
    ),
    'espera', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nivel_id', e.nivel_id, 'vuelta', e.vuelta, 'creado_en', e.creado_en
             ) order by e.creado_en), '[]'::jsonb)
      from public.lista_espera e
      where e.user_id = v_yo
    ),
    'ciclos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nivel_id', c.nivel_id, 'vuelta', c.vuelta, 'completado_en', c.completado_en
             ) order by c.completado_en), '[]'::jsonb)
      from public.ciclos_completados c
      where c.user_id = v_yo
    ),
    -- Por nivel: en qué vuelta podría entrar ahora (null = no puede tocar Participar)
    'puede_participar', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nivel_id', n.id, 'vuelta', public.vuelta_para_participar(v_yo, n.id)
             ) order by n.orden), '[]'::jsonb)
      from public.niveles n
    )
  );
end;
$$;

-- =====================================================================
-- 10. PERMISOS
-- =====================================================================
revoke execute on function public.posiciones_poner_vuelta()                              from public, anon, authenticated;
revoke execute on function public.vuelta_para_participar(uuid, integer)                  from public, anon, authenticated;
revoke execute on function public.vuelta_para_asignar(uuid, integer)                     from public, anon, authenticated;
revoke execute on function public.contar_invitados_vuelta(uuid, integer, integer)        from public, anon, authenticated;
revoke execute on function public.ocupar_posicion(uuid, uuid, boolean, integer)          from public, anon, authenticated;
revoke execute on function public.liberar_posicion(uuid, text)                           from public, anon, authenticated;
revoke execute on function public.validar_asignacion(uuid, uuid)                         from public, anon, authenticated;
revoke execute on function public.colocar_ascendido(uuid, text, uuid, integer)           from public, anon, authenticated;
revoke execute on function public.ascender_grupo(uuid)                                   from public, anon, authenticated;
revoke execute on function public.revisar_plazos()                                       from public, anon, authenticated;
revoke execute on function public.contar_referidos(uuid)                                 from public, anon, authenticated;
revoke execute on function public.limitar_referidos()                                    from public, anon, authenticated;

revoke execute on function public.participar(integer)                                    from public, anon;
revoke execute on function public.mi_reloj(integer, integer)                             from public, anon;
revoke execute on function public.retirar_y_reemplazar(uuid, uuid)                       from public, anon;
revoke execute on function public.mi_resumen_perfil()                                    from public, anon;
revoke execute on function public.mi_grupo_resumen(integer, integer)                     from public, anon;
revoke execute on function public.mis_vueltas()                                          from public, anon;

grant execute on function public.participar(integer)                                     to authenticated;
grant execute on function public.mi_reloj(integer, integer)                              to authenticated;
grant execute on function public.retirar_y_reemplazar(uuid, uuid)                        to authenticated;
grant execute on function public.mi_resumen_perfil()                                     to authenticated;
grant execute on function public.mi_grupo_resumen(integer, integer)                      to authenticated;
grant execute on function public.mis_vueltas()                                           to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- 11. COMPROBACIÓN
-- =====================================================================
select 'respaldo ciclos_completados' as que, count(*)::text as valor from public.ciclos_completados_respaldo_18
union all select 'ciclos_completados ahora', count(*)::text from public.ciclos_completados
union all select 'posiciones ocupadas sin vuelta (debe ser 0)', count(*)::text from public.posiciones where user_id is not null and vuelta is null
union all select 'personas con vuelta_actual > 1', count(*)::text from public.perfiles where vuelta_actual > 1;
