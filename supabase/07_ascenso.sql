-- =====================================================================
-- Sistema Siembra tu Futuro — 07_ascenso.sql
-- Ejecutar DESPUÉS de 01 a 06. Se puede volver a ejecutar sin problema.
-- Cambios 4: relojes corregidos, ASCENSO (división del grupo) y niveles 2 a 10.
--
-- Reglas:
--  * Reloj de horas_tarea: SOLO regaladores con origen automático (desde reservada_en).
--  * Reloj de dias_invitar: SOLO constructores con ascendido_en (subieron por ascenso,
--    llegaron como constructor por Participar/lista de espera con relojes o por "Retirar y
--    reemplazar"). Recibidores y puestos por el administrador no tienen relojes.
--  * Ascenso: al aprobar la 4.ª tarea, el recibidor completa el ciclo (ciclos_completados),
--    el grupo pasa a 'completado' y se divide en dos grupos nuevos del mismo nivel:
--      Grupo A: recibidor = constructor_1, constructores = regalador_1 y regalador_2
--      Grupo B: recibidor = constructor_2, constructores = regalador_3 y regalador_4
-- =====================================================================

-- =====================================================================
-- 1. COLUMNAS Y TABLAS NUEVAS
-- =====================================================================
alter table public.perfiles   add column if not exists es_fundador  boolean not null default false;
alter table public.posiciones add column if not exists ascendido_en timestamptz;

comment on column public.perfiles.es_fundador is
  'Fundador: en los niveles 2 a 10 crea su propio grupo como recibidor al tocar Participar. Solo lo cambia el administrador.';
comment on column public.posiciones.ascendido_en is
  'Desde cuándo es constructor con reloj de dias_invitar (ascenso, Participar o reemplazo). NULL = sin ese reloj.';

update public.configuracion
   set descripcion = 'Días para tener 2 invitados con posición en el nivel, contados desde que la persona queda como constructor (ascendido_en). Admite decimales.'
 where clave = 'dias_invitar';
update public.configuracion
   set descripcion = 'Horas para que un REGALADOR haga su tarea, desde que reserva el lugar. Admite decimales (0.05 = 3 minutos).'
 where clave = 'horas_tarea';

create table if not exists public.ciclos_completados (
  user_id       uuid    not null references public.perfiles (id) on delete cascade,
  nivel_id      integer not null references public.niveles (id),
  grupo_id      uuid    references public.grupos (id) on delete set null,
  completado_en timestamptz not null default now(),
  primary key (user_id, nivel_id)
);
comment on table public.ciclos_completados is 'Recibidores que recibieron sus 4 tareas: habilitan el nivel siguiente.';

-- =====================================================================
-- 2. MIGRACIÓN DE DATOS DE LA FASE 3 (idempotente)
-- =====================================================================
-- Regaladores suspendidos por la regla vieja (7 días desde la tarea): vuelven a esperar aprobación.
update public.posiciones
   set estado = 'tarea_hecha', tarea_hecha_en = coalesce(tarea_hecha_en, now())
 where posicion like 'regalador%' and user_id is not null and estado = 'plazo_vencido';

-- Recibidor y constructores no tienen tarea ni reloj de horas_tarea.
-- Constructores que entraron con relojes: su plazo de invitar corre desde que llegaron.
update public.posiciones
   set ascendido_en   = case when posicion like 'constructor%' and origen = 'automatico'
                             then coalesce(ascendido_en, tarea_hecha_en, asignado_en, now())
                             else ascendido_en end,
       estado         = case when posicion like 'constructor%' and estado = 'plazo_vencido' then estado end,
       reservada_en   = null,
       tarea_hecha_en = null,
       aviso_enviado  = false
 where user_id is not null
   and posicion not like 'regalador%'
   and (
     estado in ('reservada', 'tarea_hecha', 'confirmada')
     or (posicion = 'recibidor' and estado is not null)
     or reservada_en is not null
     or tarea_hecha_en is not null
     or (posicion like 'constructor%' and origen = 'automatico' and ascendido_en is null)
   );

-- =====================================================================
-- 3. FUNCIONES INTERNAS
-- =====================================================================

-- "7 días", "1 día" o, si es menos de un día (pruebas), "5 min"
create or replace function public.texto_dias_invitar()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when v >= 1 then public.texto_numero(v) || case when v = 1 then ' día' else ' días' end
           else public.texto_duracion(public.intervalo_config('dias_invitar'))
         end
  from (select coalesce((select valor from public.configuracion where clave = 'dias_invitar'), 7) as v) x;
$$;

-- Texto del plazo de la tarea: "4 horas"
create or replace function public.texto_horas_tarea()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select public.texto_numero(coalesce((select valor from public.configuracion where clave = 'horas_tarea'), 4)) || ' horas';
$$;

-- Nivel habilitado: el primero, o el siguiente a uno donde la persona completó su ciclo.
create or replace function public.nivel_habilitado(p_user_id uuid, p_nivel_id integer)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select n.orden = 1
        or exists (
             select 1
             from public.ciclos_completados c
             join public.niveles ant on ant.id = c.nivel_id
             where c.user_id = p_user_id and ant.orden = n.orden - 1
           )
    from public.niveles n
    where n.id = p_nivel_id
  ), false);
$$;

-- Pone a una persona en una casilla.
--   Regalador: estado 'reservada'; con relojes, corre horas_tarea desde ahora.
--   Constructor con relojes: corre dias_invitar desde ahora (ascendido_en).
--   Recibidor: nunca tiene relojes.
create or replace function public.ocupar_posicion(p_posicion_id uuid, p_user_id uuid, p_con_relojes boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.posiciones
     set user_id        = p_user_id,
         asignado_en    = now(),
         origen         = case when p_con_relojes then 'automatico' else 'admin' end,
         estado         = case when posicion like 'regalador%' then 'reservada' end,
         reservada_en   = case when p_con_relojes and posicion like 'regalador%' then now() end,
         ascendido_en   = case when p_con_relojes and posicion like 'constructor%' then now() end,
         tarea_hecha_en = null,
         aviso_enviado  = false
   where id = p_posicion_id;

  delete from public.lista_espera
   where user_id = p_user_id
     and nivel_id = (select nivel_id from public.posiciones where id = p_posicion_id);
$$;

create or replace function public.liberar_posicion(p_posicion_id uuid, p_estado text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.posiciones
     set user_id = null, origen = null, estado = p_estado, asignado_en = null,
         reservada_en = null, tarea_hecha_en = null, ascendido_en = null, aviso_enviado = false
   where id = p_posicion_id;
$$;

-- Crea un grupo con sus 7 casillas vacías. Devuelve su id.
create or replace function public.crear_grupo_vacio(p_nivel_id integer)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grupo uuid;
begin
  insert into public.grupos (nivel_id) values (p_nivel_id) returning id into v_grupo;
  insert into public.posiciones (grupo_id, nivel_id, posicion)
  select v_grupo, p_nivel_id, p
  from unnest(array['recibidor', 'constructor_1', 'constructor_2',
                    'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4']) as p;
  return v_grupo;
end;
$$;

-- Coloca a un ascendido en una casilla del grupo nuevo (sin hacer nada si no hay persona)
create or replace function public.colocar_ascendido(p_grupo_id uuid, p_posicion text, p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.posiciones
     set user_id        = p_user_id,
         asignado_en    = now(),
         origen         = 'automatico',
         estado         = null,
         reservada_en   = null,
         tarea_hecha_en = null,
         aviso_enviado  = false,
         ascendido_en   = case when p_posicion like 'constructor%' then now() end
   where grupo_id = p_grupo_id and posicion = p_posicion and p_user_id is not null;
$$;

-- Validación de asignaciones del admin: además, el grupo debe estar activo.
create or replace function public.validar_asignacion(p_posicion_id uuid, p_user_id uuid)
returns public.posiciones
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos public.posiciones;
  v_requisito text;
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
  if exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'Ese usuario ya tiene una posición en este nivel.';
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

-- Notificación al ocupar una casilla con relojes (texto según la casilla)
create or replace function public.notificar_lugar(p_user_id uuid, p_posicion text, p_nivel text, p_intro text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.notificar(p_user_id, 'Reservaste tu lugar',
    p_intro || ' ' ||
    case
      when p_posicion like 'regalador%' then
        format('Tienes %s para hacer tu tarea, avisar al recibidor por WhatsApp y marcarla como hecha.', public.texto_horas_tarea())
      when p_posicion like 'constructor%' then
        format('Tienes %s para invitar a 2 personas que obtengan su lugar en el nivel %s.', public.texto_dias_invitar(), p_nivel)
      else
        'Como recibidor no tienes relojes: espera las tareas de tus 4 regaladores y apruébalas en Mi grupo.'
    end);
end;
$$;

-- ---------- ASCENSO ----------
-- Se llama dentro de confirmar_tarea (misma transacción). Devuelve true si hubo ascenso.
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
  -- Bloquea el grupo: dos aprobaciones a la vez no pueden dividirlo dos veces
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
         ]
    into v_rec, v_c1, v_c2, v_r
  from public.posiciones
  where grupo_id = p_grupo_id;

  -- a) El recibidor termina su ciclo
  if v_rec is not null then
    insert into public.ciclos_completados (user_id, nivel_id, grupo_id)
    values (v_rec, v_nivel.id, p_grupo_id)
    on conflict (user_id, nivel_id) do update
      set grupo_id = excluded.grupo_id, completado_en = now();
  end if;

  -- b) Se vacía el grupo original (una persona = una posición por nivel) y queda 'completado'
  update public.posiciones
     set user_id = null, origen = null, estado = null, asignado_en = null,
         reservada_en = null, tarea_hecha_en = null, ascendido_en = null, aviso_enviado = false
   where grupo_id = p_grupo_id;
  update public.grupos set estado = 'completado' where id = p_grupo_id;

  --    Grupo A: constructor_1 al centro, regalador_1 y regalador_2 como constructores
  v_a := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_a, 'recibidor',     v_c1);
  perform public.colocar_ascendido(v_a, 'constructor_1', v_r[1]);
  perform public.colocar_ascendido(v_a, 'constructor_2', v_r[2]);

  --    Grupo B: constructor_2 al centro, regalador_3 y regalador_4 como constructores
  v_b := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_b, 'recibidor',     v_c2);
  perform public.colocar_ascendido(v_b, 'constructor_1', v_r[3]);
  perform public.colocar_ascendido(v_b, 'constructor_2', v_r[4]);

  -- d) Notificaciones
  v_ultimo := not exists (select 1 from public.niveles where orden > v_nivel.orden);
  perform public.notificar(v_rec, 'Completaste el nivel ' || v_nivel.nombre,
    case when v_ultimo
         then format('Completaste el nivel %s, el último nivel. ¡Felicitaciones!', v_nivel.nombre)
         else format('Completaste el nivel %s. Ya puedes participar en el siguiente desde Niveles.', v_nivel.nombre)
    end);

  foreach u in array v_r loop
    perform public.notificar(u, 'Subiste a constructor',
      format('La persona del centro recibió todas las tareas y subiste a constructor. Tienes %s para invitar a 2 personas. (Nivel %s)',
             public.texto_dias_invitar(), v_nivel.nombre));
  end loop;

  perform public.notificar(v_c1, 'Eres recibidor',
    format('Ahora eres el recibidor de un grupo nuevo. (Nivel %s)', v_nivel.nombre));
  perform public.notificar(v_c2, 'Eres recibidor',
    format('Ahora eres el recibidor de un grupo nuevo. (Nivel %s)', v_nivel.nombre));

  -- e) Lista de espera en el nivel: aviso al administrador
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
-- 4. FUNCIONES PARA LA WEB (rpc)
-- =====================================================================

-- ---------- participar ----------
-- Nivel 1: solo casillas de regalador (primero debajo del invitador si es constructor;
--          si no, el primer regalador libre de su grupo). Si no, lista de espera.
-- Niveles 2 a 10: fundador -> grupo nuevo como recibidor. Si no, en el grupo del invitador:
--          invitador recibidor -> constructor_1 / constructor_2; invitador constructor ->
--          regalador libre debajo de él. Si no, lista de espera.
create or replace function public.participar(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo        uuid := (select auth.uid());
  v_nivel     public.niveles;
  v_perfil    public.perfiles;
  v_pos_inv   public.posiciones;
  v_libre     public.posiciones;
  v_grupo     uuid;
  v_recibidor uuid;
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

  if exists (select 1 from public.ciclos_completados where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya completaste este nivel. Participa en el siguiente.';
  end if;
  if not public.nivel_habilitado(v_yo, p_nivel_id) then
    raise exception 'Este nivel todavía no está habilitado para ti. Primero completa el nivel anterior.';
  end if;
  if exists (select 1 from public.posiciones where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya tienes una posición en este nivel.';
  end if;
  if exists (select 1 from public.lista_espera where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya estás en la lista de espera de este nivel.';
  end if;

  -- (Niveles 2 a 10) Fundador: crea su propio grupo como recibidor
  if v_nivel.orden > 1 and v_perfil.es_fundador then
    v_grupo := public.crear_grupo_vacio(p_nivel_id);
    select * into v_libre from public.posiciones where grupo_id = v_grupo and posicion = 'recibidor';
  else
    -- Grupo activo del invitador en este nivel
    if v_perfil.invitado_por is not null then
      select po.* into v_pos_inv
      from public.posiciones po
      join public.grupos g on g.id = po.grupo_id and g.estado = 'activo'
      where po.user_id = v_perfil.invitado_por and po.nivel_id = p_nivel_id;
    end if;

    if v_pos_inv.id is not null then
      if v_nivel.orden = 1 then
        -- Solo regaladores: primero debajo del invitador (si es constructor), luego el primero libre
        select p.* into v_libre
        from public.posiciones p
        where p.grupo_id = v_pos_inv.grupo_id
          and p.user_id is null
          and p.posicion like 'regalador%'
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
        order by p.posicion
        limit 1
        for update skip locked;
      elsif v_pos_inv.posicion like 'constructor%' then
        select p.* into v_libre
        from public.posiciones p
        where p.grupo_id = v_pos_inv.grupo_id
          and p.user_id is null
          and p.cuelga_de = v_pos_inv.posicion
        order by p.posicion
        limit 1
        for update skip locked;
      end if;
    end if;
  end if;

  -- Sin lugar o sin grupo del invitador -> lista de espera
  if v_libre.id is null then
    insert into public.lista_espera (user_id, nivel_id) values (v_yo, p_nivel_id);
    perform public.notificar(v_yo, 'Estás en lista de espera',
      format('No hay un lugar libre para ti en el grupo de quien te invitó en el nivel %s (o todavía no tiene grupo en ese nivel). El administrador te asignará un lugar.', v_nivel.nombre));
    perform public.notificar_admins('Nueva persona en lista de espera',
      format('%s tocó Participar en el nivel %s y quedó en lista de espera.', v_perfil.nombre_usuario, v_nivel.nombre));
    return jsonb_build_object('resultado', 'lista_espera', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre);
  end if;

  perform public.ocupar_posicion(v_libre.id, v_yo, true);

  perform public.notificar_lugar(v_yo, v_libre.posicion, v_nivel.nombre,
    case when v_libre.posicion = 'recibidor'
         then format('Como fundador creaste un grupo nuevo en el nivel %s y eres su recibidor.', v_nivel.nombre)
         else format('Ocupas la posición %s en el nivel %s.', public.nombre_posicion(v_libre.posicion), v_nivel.nombre)
    end);

  v_recibidor := public.recibidor_de_grupo(v_libre.grupo_id);
  if v_recibidor is not null and v_recibidor <> v_yo then
    perform public.notificar(v_recibidor, 'Nueva persona en tu grupo',
      format('%s entró a tu grupo del nivel %s como %s.',
             v_perfil.nombre_usuario, v_nivel.nombre, public.nombre_posicion(v_libre.posicion)));
  end if;

  return jsonb_build_object('resultado', 'colocado', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                            'grupo_id', v_libre.grupo_id, 'posicion', v_libre.posicion);
end;
$$;

-- ---------- marcar_tarea_hecha (solo regaladores) ----------
create or replace function public.marcar_tarea_hecha(p_posicion_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo  uuid := (select auth.uid());
  v_pos public.posiciones;
  v_nivel text;
begin
  select * into v_pos
  from public.posiciones
  where user_id = v_yo and estado = 'reservada' and posicion like 'regalador%'
    and (p_posicion_id is null or id = p_posicion_id)
  order by reservada_en nulls last
  limit 1
  for update;

  if not found then
    raise exception 'No tienes una tarea pendiente por marcar.';
  end if;
  if v_pos.origen = 'automatico' and v_pos.reservada_en is not null
     and now() >= v_pos.reservada_en + public.intervalo_config('horas_tarea') then
    raise exception 'Se acabó el tiempo para marcar tu tarea. Tu lugar será liberado.';
  end if;

  update public.posiciones set estado = 'tarea_hecha', tarea_hecha_en = now() where id = v_pos.id;

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  perform public.notificar(public.recibidor_de_grupo(v_pos.grupo_id), 'Tarea por aprobar',
    format('%s (%s, nivel %s) marcó su tarea como hecha. Revísala y apruébala en Mi grupo.',
           (select nombre_usuario from public.perfiles where id = v_yo),
           public.nombre_posicion(v_pos.posicion), v_nivel));
end;
$$;

-- ---------- confirmar_tarea (ahora con ascenso; devuelve jsonb) ----------
drop function if exists public.confirmar_tarea(uuid);
create function public.confirmar_tarea(p_posicion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := (select auth.uid());
  v_pos     public.posiciones;
  v_ascenso boolean;
  v_nivel   public.niveles;
begin
  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if public.recibidor_de_grupo(v_pos.grupo_id) is distinct from v_yo then
    raise exception 'Solo el recibidor del grupo puede aprobar tareas.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla está libre.';
  end if;
  if v_pos.posicion not like 'regalador%' then
    raise exception 'Solo se aprueban tareas de regaladores.';
  end if;
  if v_pos.estado = 'confirmada' then
    raise exception 'Esa tarea ya fue aprobada.';
  end if;
  if v_pos.estado is distinct from 'tarea_hecha' then
    raise exception 'Esa persona todavía no marcó su tarea como hecha.';
  end if;

  update public.posiciones set estado = 'confirmada' where id = p_posicion_id;

  perform public.notificar(v_pos.user_id, 'Tu tarea fue confirmada',
    'El recibidor confirmó que recibió tu tarea. Cuando los 4 regaladores estén aprobados subirás a constructor.');

  v_ascenso := public.ascender_grupo(v_pos.grupo_id);
  select * into v_nivel from public.niveles where id = v_pos.nivel_id;

  return jsonb_build_object(
    'ascenso', v_ascenso,
    'nivel', v_nivel.nombre,
    'ultimo_nivel', not exists (select 1 from public.niveles where orden > v_nivel.orden)
  );
end;
$$;

-- ---------- retirar_y_reemplazar (mensaje según la casilla) ----------
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
  if not exists (select 1 from public.lista_espera where user_id = p_nuevo_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'La persona nueva debe estar en la lista de espera de este nivel.';
  end if;
  if exists (select 1 from public.posiciones where user_id = p_nuevo_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'La persona nueva ya tiene una posición en este nivel.';
  end if;

  -- Libera y coloca al nuevo en un solo paso (un constructor nuevo recibe dias_invitar completos)
  perform public.liberar_posicion(p_posicion_id, 'retirada');
  perform public.ocupar_posicion(p_posicion_id, p_nuevo_user_id, true);

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;

  perform public.notificar(v_retirado, 'Fuiste retirado de tu posición',
    format('Saliste de la posición %s del nivel %s y tu lugar fue asignado a otra persona.',
           public.nombre_posicion(v_pos.posicion), v_nivel));
  perform public.notificar_lugar(p_nuevo_user_id, v_pos.posicion, v_nivel,
    format('Te colocaron como %s en el nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));
end;
$$;

-- ---------- admin_asignar_desde_espera (mensaje según la casilla) ----------
create or replace function public.admin_asignar_desde_espera(p_user_id uuid, p_posicion_id uuid, p_con_relojes boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posiciones;
  v_nivel text;
  v_intro text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede asignar posiciones.';
  end if;

  v_pos := public.validar_asignacion(p_posicion_id, p_user_id);
  if v_pos.user_id is not null then
    raise exception 'Esa casilla ya está ocupada. Elige una casilla libre.';
  end if;
  if not exists (select 1 from public.lista_espera where user_id = p_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'Esa persona ya no está en la lista de espera de este nivel.';
  end if;

  perform public.ocupar_posicion(p_posicion_id, p_user_id, coalesce(p_con_relojes, true));

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  v_intro := format('El administrador te asignó como %s en el nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel);
  if coalesce(p_con_relojes, true) then
    perform public.notificar_lugar(p_user_id, v_pos.posicion, v_nivel, v_intro);
  else
    perform public.notificar(p_user_id, 'Reservaste tu lugar', v_intro);
  end if;
  perform public.notificar(public.recibidor_de_grupo(v_pos.grupo_id), 'Nueva persona en tu grupo',
    format('%s entró a tu grupo del nivel %s como %s.',
           (select nombre_usuario from public.perfiles where id = p_user_id), v_nivel, public.nombre_posicion(v_pos.posicion)));
end;
$$;

-- ---------- admin_marcar_fundador ----------
create or replace function public.admin_marcar_fundador(p_user_id uuid, p_es_fundador boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede marcar fundadores.';
  end if;
  update public.perfiles set es_fundador = coalesce(p_es_fundador, false) where id = p_user_id;
  if not found then
    raise exception 'Ese usuario no existe.';
  end if;
end;
$$;

-- ---------- mi_reloj ----------
-- Fases: 'tarea' (Paso 1, regalador con relojes, reservada) | 'esperando' (regalador que ya hizo
-- su tarea, X/4 aprobadas) | 'invitar' (Paso 2, constructor con ascendido_en) | 'listo' (ya tiene
-- 2 invitados) | 'plazo_vencido'. Devuelve NULL si no tiene una posición con relojes.
create or replace function public.mi_reloj(p_nivel_id integer default null)
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
    select p.id, n.orden,
           case
             when p.posicion like 'regalador%' and p.origen = 'automatico' and p.estado = 'reservada' then 'tarea'
             when p.posicion like 'regalador%' and p.origen = 'automatico' and p.estado in ('tarea_hecha', 'confirmada') then 'esperando'
             when p.posicion like 'constructor%' and p.ascendido_en is not null and p.estado = 'plazo_vencido' then 'plazo_vencido'
             when p.posicion like 'constructor%' and p.ascendido_en is not null then
               case when public.contar_invitados(v_yo, p.nivel_id) >= 2 then 'listo' else 'invitar' end
           end as fase
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = v_yo
      and (p_nivel_id is null or p.nivel_id = p_nivel_id)
  ) x
  where x.fase is not null
  order by array_position(array['tarea', 'plazo_vencido', 'invitar', 'esperando', 'listo'], x.fase), x.orden desc
  limit 1;

  if v_fase is null then
    return null;
  end if;

  select * into v_pos from public.posiciones where id = v_id;
  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  v_rec := public.recibidor_de_grupo(v_pos.grupo_id);
  v_inv := public.contar_invitados(v_yo, v_pos.nivel_id);

  return jsonb_build_object(
    'ahora',              now(),
    'fase',               v_fase,
    'posicion_id',        v_pos.id,
    'posicion',           v_pos.posicion,
    'nivel_id',           v_pos.nivel_id,
    'nivel_nombre',       v_nivel,
    'estado',             v_pos.estado,
    'reservada_en',       v_pos.reservada_en,
    'fin_tarea',          v_pos.reservada_en + public.intervalo_config('horas_tarea'),
    'tarea_hecha_en',     v_pos.tarea_hecha_en,
    'ascendido_en',       v_pos.ascendido_en,
    'fin_invitar',        v_pos.ascendido_en + public.intervalo_config('dias_invitar'),
    'invitados',          v_inv,
    'aprobadas',          (select count(*) from public.posiciones
                            where grupo_id = v_pos.grupo_id and posicion like 'regalador%'
                              and user_id is not null and estado = 'confirmada'),
    'recibidor_nombre',   (select nombre_usuario from public.perfiles where id = v_rec),
    'recibidor_whatsapp', case when v_rec is not null then public.whatsapp_de(v_rec) end
  );
end;
$$;

-- =====================================================================
-- 5. REVISAR PLAZOS (pg_cron cada 5 minutos; mismo nombre que en 05)
-- =====================================================================
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
  v_invitar   interval := public.intervalo_config('dias_invitar');
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

  -- (c) Constructor: dias_invitar desde ascendido_en con menos de 2 invitados con posición en ese nivel
  for r in
    select p.id, p.user_id, p.nivel_id, n.nombre as nivel, pe.nombre_usuario, pe.invitado_por
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    join public.perfiles pe on pe.id = p.user_id
    where p.posicion like 'constructor%'
      and p.ascendido_en is not null
      and p.estado is null
      and p.ascendido_en + v_invitar <= now()
      and public.contar_invitados(p.user_id, p.nivel_id) < 2
    for update of p skip locked
  loop
    update public.posiciones set estado = 'plazo_vencido' where id = r.id;
    perform public.notificar(r.user_id, 'Plazo vencido',
      format('Pasaron %s desde que subiste a constructor y no completaste tus 2 invitados en el nivel %s. Tu posición quedó suspendida y quien te invitó puede reemplazarte.',
             public.texto_duracion(v_invitar), r.nivel));
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
-- 6. RLS Y GRANTs
-- =====================================================================
alter table public.ciclos_completados enable row level security;

drop policy if exists "ciclos: ver los propios" on public.ciclos_completados;
create policy "ciclos: ver los propios"
  on public.ciclos_completados for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "ciclos: admin lee" on public.ciclos_completados;
create policy "ciclos: admin lee"
  on public.ciclos_completados for select to authenticated
  using (public.es_admin());

revoke all on table public.ciclos_completados from anon, authenticated;
grant select on table public.ciclos_completados to authenticated;

-- es_fundador: se lee junto con el perfil (cada uno el suyo; el admin todos). Nadie lo
-- escribe directo: el permiso de update sigue siendo solo de nombre_usuario.

-- Internas
revoke execute on function public.texto_dias_invitar()                          from public, anon, authenticated;
revoke execute on function public.texto_horas_tarea()                           from public, anon, authenticated;
revoke execute on function public.nivel_habilitado(uuid, integer)               from public, anon, authenticated;
revoke execute on function public.ocupar_posicion(uuid, uuid, boolean)          from public, anon, authenticated;
revoke execute on function public.liberar_posicion(uuid, text)                  from public, anon, authenticated;
revoke execute on function public.crear_grupo_vacio(integer)                    from public, anon, authenticated;
revoke execute on function public.colocar_ascendido(uuid, text, uuid)           from public, anon, authenticated;
revoke execute on function public.validar_asignacion(uuid, uuid)                from public, anon, authenticated;
revoke execute on function public.notificar_lugar(uuid, text, text, text)       from public, anon, authenticated;
revoke execute on function public.ascender_grupo(uuid)                          from public, anon, authenticated;
revoke execute on function public.revisar_plazos()                              from public, anon, authenticated;

-- Para la web (solo con sesión)
revoke execute on function public.participar(integer)                           from public, anon;
revoke execute on function public.marcar_tarea_hecha(uuid)                      from public, anon;
revoke execute on function public.confirmar_tarea(uuid)                         from public, anon;
revoke execute on function public.retirar_y_reemplazar(uuid, uuid)              from public, anon;
revoke execute on function public.admin_asignar_desde_espera(uuid, uuid, boolean) from public, anon;
revoke execute on function public.admin_marcar_fundador(uuid, boolean)          from public, anon;
revoke execute on function public.mi_reloj(integer)                             from public, anon;

grant execute on function public.participar(integer)                           to authenticated;
grant execute on function public.marcar_tarea_hecha(uuid)                      to authenticated;
grant execute on function public.confirmar_tarea(uuid)                         to authenticated;
grant execute on function public.retirar_y_reemplazar(uuid, uuid)              to authenticated;
grant execute on function public.admin_asignar_desde_espera(uuid, uuid, boolean) to authenticated;
grant execute on function public.admin_marcar_fundador(uuid, boolean)          to authenticated;
grant execute on function public.mi_reloj(integer)                             to authenticated;

-- =====================================================================
-- 7. GRUPOS QUE YA TENÍAN SUS 4 REGALADORES APROBADOS: se dividen ahora
-- =====================================================================
do $$
declare
  g record;
begin
  for g in
    select gr.id
    from public.grupos gr
    where gr.estado = 'activo'
      and (select count(*) from public.posiciones p
            where p.grupo_id = gr.id and p.posicion like 'regalador%'
              and p.user_id is not null and p.estado = 'confirmada') = 4
  loop
    perform public.ascender_grupo(g.id);
    raise notice 'Grupo % completado y dividido.', g.id;
  end loop;
end $$;

notify pgrst, 'reload schema';
