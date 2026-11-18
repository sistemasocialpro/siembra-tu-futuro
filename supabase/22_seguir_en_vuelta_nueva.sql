-- !! OBSOLETO desde 25_repetir_nivel.sql: NO volver a ejecutar este archivo (crea las vueltas que el 25 quita).
--    Se deja solo como historial. Su contenido vigente (sin vueltas) está en el 25.
-- =====================================================================
-- Sistema Siembra tu Futuro — 22_seguir_en_vuelta_nueva.sql
-- Ejecutar DESPUÉS de 21_derrame_prioridad.sql. Se puede volver a ejecutar sin problema.
-- Si re-ejecutas 18, 19, 20 o 21, vuelve a ejecutar este archivo después.
--
-- Regla del cliente (reemplaza parte del 19):
--   * Quien empieza una VUELTA NUEVA en el nivel 1 cae por DERRAME (ya no se busca la posición
--     de su patrocinador en la vuelta en que lo invitó).
--   * Excepción con PREFERENCIA: si su patrocinador original es CONSTRUCTOR en el nivel 1 (en
--     cualquiera de sus vueltas, sin plazo vencido) y tiene un regalador libre debajo, cae
--     DEBAJO DE ÉL y lo SIGUE en esa vuelta del patrocinador (tabla seguimientos): en los
--     niveles siguientes de esa vuelta se le busca lugar con su patrocinador.
--   * Enlace: en cada vuelta el patrocinador tiene como máximo 2 seguidores en total:
--     invitados nuevos de esa vuelta + socios de vueltas anteriores que ocuparon sus lugares.
--     Si A vuelve y B no, el enlace permite invitar a 1 persona nueva.
--   * Dentro del plazo del constructor, el primero que llega ocupa el lugar (socio que vuelve o
--     invitado nuevo). El derrame de otras personas sigue la regla del 21: esos lugares
--     guardados se usan solo al final, si no queda ningún otro libre en el nivel. Con el plazo
--     vencido pasan primero al derrame.
--   * El reloj del constructor cuenta como "invitados" a sus seguidores de esa vuelta
--     (invitados nuevos y socios que volvieron) que ya tienen posición en ese nivel.
-- =====================================================================

-- =====================================================================
-- 1. QUIÉN SIGUE A QUIÉN EN CADA VUELTA
-- =====================================================================
-- La vuelta 1 de cada persona sigue a quien la invitó, en la vuelta en que la invitó
-- (perfiles.invitado_por + invitado_vuelta). Las vueltas siguientes solo siguen a alguien si
-- la persona ocupó un lugar debajo de su patrocinador al volver al nivel 1 (esta tabla).
create table if not exists public.seguimientos (
  user_id             uuid    not null references public.perfiles (id) on delete cascade,
  vuelta              integer not null,
  patrocinador_id     uuid    not null references public.perfiles (id) on delete cascade,
  vuelta_patrocinador integer not null,
  creado_en           timestamptz not null default now(),
  primary key (user_id, vuelta)
);
create index if not exists seguimientos_patrocinador_idx
  on public.seguimientos (patrocinador_id, vuelta_patrocinador);
alter table public.seguimientos enable row level security;
revoke all on table public.seguimientos from anon, authenticated;
-- Sin políticas ni GRANT: solo la usan las funciones de abajo.

-- Patrocinador al que sigue una persona en una de sus vueltas (null si no sigue a nadie)
create or replace function public.patrocinador_en_vuelta(p_user_id uuid, p_vuelta integer,
  out patrocinador uuid, out vuelta_patrocinador integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  select s.patrocinador_id, s.vuelta_patrocinador into patrocinador, vuelta_patrocinador
  from public.seguimientos s where s.user_id = p_user_id and s.vuelta = p_vuelta;
  if patrocinador is null and p_vuelta = 1 then
    select pe.invitado_por, coalesce(pe.invitado_vuelta, 1) into patrocinador, vuelta_patrocinador
    from public.perfiles pe where pe.id = p_user_id and pe.invitado_por is not null;
  end if;
end;
$$;

-- Seguidores de una persona en una vuelta suya: invitados nuevos de esa vuelta + socios de
-- vueltas anteriores que ocuparon sus lugares. Máximo 2 por vuelta (lo controla el enlace).
create or replace function public.contar_seguidores(p_user_id uuid, p_vuelta integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select ((select count(*) from public.perfiles r
            where r.invitado_por = p_user_id and coalesce(r.invitado_vuelta, 1) = coalesce(p_vuelta, 1))
        + (select count(*) from public.seguimientos s
            where s.patrocinador_id = p_user_id and s.vuelta_patrocinador = coalesce(p_vuelta, 1)))::int;
$$;

-- Seguidores de esa vuelta que ya tienen posición en el nivel (para el reloj del constructor)
create or replace function public.contar_invitados_vuelta(p_user_id uuid, p_nivel_id integer, p_vuelta integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select ((select count(*) from public.perfiles pe
            where pe.invitado_por = p_user_id and coalesce(pe.invitado_vuelta, 1) = coalesce(p_vuelta, 1)
              and exists (select 1 from public.posiciones po
                          where po.user_id = pe.id and po.nivel_id = p_nivel_id and po.vuelta = 1))
        + (select count(*) from public.seguimientos s
            where s.patrocinador_id = p_user_id and s.vuelta_patrocinador = coalesce(p_vuelta, 1)
              and exists (select 1 from public.posiciones po
                          where po.user_id = s.user_id and po.nivel_id = p_nivel_id and po.vuelta = s.vuelta)))::int;
$$;

-- ¿El lugar que cuelga de esa casilla lo guarda un constructor para sus seguidores?
-- (reloj para invitar corriendo, sin plazo vencido y con menos de 2 seguidores con posición)
create or replace function public.lugar_guardado(p_grupo_id uuid, p_cuelga_de text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posiciones c
    where c.grupo_id = p_grupo_id and c.posicion = p_cuelga_de and c.user_id is not null
      and c.estado is null and c.ascendido_en is not null
      and public.contar_invitados_vuelta(c.user_id, c.nivel_id, c.vuelta) < 2
  );
$$;

-- =====================================================================
-- 2. ENLACE: 2 seguidores por vuelta (invitados nuevos + socios que volvieron)
-- =====================================================================
create or replace function public.contar_referidos(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select public.contar_seguidores(p_user_id,
    coalesce((select vuelta_actual from public.perfiles where id = p_user_id), 1));
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

  if public.contar_seguidores(new.invitado_por, new.invitado_vuelta) >= 2 then
    raise exception 'Tu patrocinador ya tiene sus 2 referidos y no puede recibir más por ahora. Por favor contáctate con la persona que te invitó.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

-- =====================================================================
-- 3. PARTICIPAR
-- =====================================================================
create or replace function public.participar(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo          uuid := (select auth.uid());
  v_nivel       public.niveles;
  v_perfil      public.perfiles;
  v_pos_inv     public.posiciones;
  v_libre       public.posiciones;
  v_grupo       uuid;
  v_recibidor   uuid;
  v_primero     boolean;
  v_vuelta      integer;
  v_repite      boolean;
  v_nueva       boolean := false;
  v_derrame     boolean := false;
  v_cand        record;
  v_pat         uuid;
  v_pat_vuelta  integer;
  v_preferencia boolean := false;
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

  -- ¿Ya completó este nivel en otra vuelta? Entonces "repite"
  v_repite := exists (select 1 from public.ciclos_completados where user_id = v_yo and nivel_id = p_nivel_id);

  -- Volver al nivel 1 después de completarlo: empieza una vuelta nueva
  if v_vuelta > v_perfil.vuelta_actual then
    update public.perfiles set vuelta_actual = v_vuelta where id = v_yo;
    v_nueva := true;
  end if;

  -- A quién sigo en esta vuelta (en una vuelta nueva del nivel 1 todavía no sigo a nadie)
  if not v_nueva then
    select x.patrocinador, x.vuelta_patrocinador into v_pat, v_pat_vuelta
    from public.patrocinador_en_vuelta(v_yo, v_vuelta) x;
  end if;

  -- (Niveles 2 en adelante) Fundador: crea su propio grupo como recibidor (también si repite)
  if not v_primero and v_perfil.es_fundador then
    v_grupo := public.crear_grupo_vacio(p_nivel_id);
    select * into v_libre from public.posiciones where grupo_id = v_grupo and posicion = 'recibidor';
  else
    if v_nueva and v_perfil.invitado_por is not null then
      -- (22) PREFERENCIA: vuelta nueva en el nivel 1 y mi patrocinador original es constructor
      -- en el nivel 1 (sin plazo vencido) con un regalador libre debajo: caigo debajo de él.
      select p.* into v_libre
      from public.posiciones c
      join public.grupos g on g.id = c.grupo_id and g.estado = 'activo'
      join public.posiciones p on p.grupo_id = c.grupo_id and p.cuelga_de = c.posicion and p.user_id is null
      where c.user_id = v_perfil.invitado_por and c.nivel_id = p_nivel_id
        and c.posicion like 'constructor%'
        and c.estado is distinct from 'plazo_vencido'
        and not exists (select 1 from public.posiciones yo where yo.grupo_id = c.grupo_id and yo.user_id = v_yo)
      order by c.vuelta desc, p.posicion
      limit 1
      for update of p skip locked;
      if v_libre.id is not null then
        v_pat := v_perfil.invitado_por;
        select c.vuelta into v_pat_vuelta from public.posiciones c
        where c.grupo_id = v_libre.grupo_id and c.posicion = v_libre.cuelga_de;
        v_preferencia := true;
      end if;
    elsif v_pat is not null then
      -- Lugar de la persona a la que sigo, en la vuelta en que la sigo
      select po.* into v_pos_inv
      from public.posiciones po
      join public.grupos g on g.id = po.grupo_id and g.estado = 'activo'
      where po.user_id = v_pat and po.nivel_id = p_nivel_id and po.vuelta = v_pat_vuelta
      limit 1;

      if v_pos_inv.id is not null then
        if v_primero then
          -- Solo regaladores: primero debajo de él (si es constructor); si no, el primero libre de
          -- su grupo que no esté guardado por otro constructor para sus seguidores
          select p.* into v_libre
          from public.posiciones p
          where p.grupo_id = v_pos_inv.grupo_id
            and p.user_id is null
            and p.posicion like 'regalador%'
            and (p.cuelga_de = v_pos_inv.posicion or not public.lugar_guardado(p.grupo_id, p.cuelga_de))
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
    end if;

    -- Derrame (21): primer regalador libre de un grupo activo del nivel, para quien repite el
    -- nivel o entra al nivel 1. Orden: 0 = debajo de un constructor con plazo vencido;
    -- 1 = debajo de un constructor que no espera seguidores; 2 = por último, los lugares que un
    -- constructor guarda para sus seguidores (reloj corriendo y menos de 2 con posición).
    -- Lista sin bloquear y después bloqueo de una sola casilla con FOR UPDATE SKIP LOCKED.
    if v_libre.id is null and (v_repite or v_primero) then
      for v_cand in
        select lib.id
        from public.grupos g
        cross join lateral (
          select p.id, p.posicion,
                 c.user_id as c_user, c.estado as c_estado, c.ascendido_en as c_ascendido,
                 c.nivel_id as c_nivel, c.vuelta as c_vuelta
          from public.posiciones p
          join public.posiciones c
            on c.grupo_id = p.grupo_id and c.posicion = p.cuelga_de and c.user_id is not null
          where p.grupo_id = g.id and p.user_id is null and p.posicion like 'regalador%'
          offset 0
        ) lib
        where g.nivel_id = p_nivel_id and g.estado = 'activo'
          and not exists (select 1 from public.posiciones yo where yo.grupo_id = g.id and yo.user_id = v_yo)
        order by case
                   when lib.c_estado = 'plazo_vencido' then 0
                   when lib.c_ascendido is null
                     or public.contar_invitados_vuelta(lib.c_user, lib.c_nivel, lib.c_vuelta) >= 2 then 1
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
  end if;

  if v_nueva then
    perform public.notificar(v_yo, 'Empezaste la vuelta ' || v_vuelta,
      format('Volviste al nivel %s y empezaste tu vuelta %s. En esta vuelta puedes tener hasta 2 personas contigo: las que invites con tu enlace y tus socios de vueltas anteriores que vuelvan al nivel %s y ocupen tus lugares.',
             v_nivel.nombre, v_vuelta, v_nivel.nombre));
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

  -- (22) Volví al nivel 1 y caí debajo de mi patrocinador: lo sigo en esa vuelta suya
  if v_preferencia then
    insert into public.seguimientos (user_id, vuelta, patrocinador_id, vuelta_patrocinador)
    values (v_yo, v_vuelta, v_pat, v_pat_vuelta)
    on conflict (user_id, vuelta) do update
      set patrocinador_id = excluded.patrocinador_id, vuelta_patrocinador = excluded.vuelta_patrocinador, creado_en = now();
    perform public.notificar(v_pat, 'Tu socio volvió contigo',
      format('%s volvió al nivel %s y ocupa uno de tus lugares de regalador (tu vuelta %s). Te seguirá en esa vuelta. Tu enlace permite %s persona(s) nueva(s) más en esa vuelta.',
             v_perfil.nombre_usuario, v_nivel.nombre, v_pat_vuelta,
             greatest(0, 2 - public.contar_seguidores(v_pat, v_pat_vuelta))));
  end if;

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
                            'vuelta', v_vuelta, 'nueva_vuelta', v_nueva, 'derrame', v_derrame,
                            'con_patrocinador', v_preferencia);
end;
$$;

-- =====================================================================
-- 4. PERMISOS
-- =====================================================================
revoke execute on function public.patrocinador_en_vuelta(uuid, integer)            from public, anon, authenticated;
revoke execute on function public.contar_seguidores(uuid, integer)                 from public, anon, authenticated;
revoke execute on function public.contar_invitados_vuelta(uuid, integer, integer)  from public, anon, authenticated;
revoke execute on function public.lugar_guardado(uuid, text)                       from public, anon, authenticated;
revoke execute on function public.contar_referidos(uuid)                           from public, anon, authenticated;
revoke execute on function public.limitar_referidos()                              from public, anon, authenticated;

revoke execute on function public.participar(integer) from public, anon;
grant  execute on function public.participar(integer) to authenticated;

notify pgrst, 'reload schema';
