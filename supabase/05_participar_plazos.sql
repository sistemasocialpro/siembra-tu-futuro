-- =====================================================================
-- Sistema Siembra tu Futuro — 05_participar_plazos.sql
-- Ejecutar DESPUÉS de 01, 02, 03 y 04. Se puede volver a ejecutar sin problema.
-- Fase 3: Participar (colocación automática), plazos con relojes, notificaciones,
-- lista de espera y configuración editable por el administrador.
--
-- Estructura del grupo (cuelga_de, columna calculada en 03):
--   recibidor (centro)
--     ├─ constructor_1 ─┬─ regalador_1
--     │                 └─ regalador_2
--     └─ constructor_2 ─┬─ regalador_3
--                       └─ regalador_4
-- =====================================================================

-- =====================================================================
-- 1. CONFIGURACIÓN (números del sistema, editables sin tocar código)
-- =====================================================================
create table if not exists public.configuracion (
  clave          text primary key,
  valor          numeric not null check (valor > 0),
  descripcion    text,
  actualizado_en timestamptz not null default now()
);

-- Al re-ejecutar NO se pisan los valores que el administrador haya cambiado.
insert into public.configuracion (clave, valor, descripcion) values
  ('horas_tarea',  4, 'Horas para hacer la tarea, desde que se reserva el lugar. Admite decimales (0.05 = 3 minutos).'),
  ('horas_aviso',  3, 'A las cuántas horas sin tarea hecha se envía el aviso (una sola vez). Debe ser menor que horas_tarea.'),
  ('dias_invitar', 7, 'Días para tener 2 invitados con posición, contados desde que se marca la tarea como hecha. Admite decimales.')
on conflict (clave) do update set descripcion = excluded.descripcion;

-- =====================================================================
-- 2. POSICIONES: estado, origen y relojes
-- =====================================================================
alter table public.posiciones add column if not exists estado         text;
alter table public.posiciones add column if not exists origen         text;
alter table public.posiciones add column if not exists reservada_en   timestamptz;
alter table public.posiciones add column if not exists tarea_hecha_en timestamptz;
alter table public.posiciones add column if not exists aviso_enviado  boolean not null default false;

comment on column public.posiciones.estado is
  'reservada | tarea_hecha | confirmada | plazo_vencido (suspendida) | retirada (casilla libre). NULL = activo sin tarea (recibidor/constructor puesto por el admin) o casilla libre.';
comment on column public.posiciones.origen is
  'admin (sin relojes) | automatico (Participar / lista de espera, con relojes). NULL si la casilla está libre.';

-- Migración desde la fase 2 (columna estado_tarea) -> estado/origen
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'posiciones' and column_name = 'estado_tarea') then
    update public.posiciones
       set origen = case when user_id is not null then coalesce(origen, 'admin') end,
           estado = case
                      when user_id is null then null
                      when estado_tarea = 'confirmada' then 'confirmada'
                      when posicion like 'regalador%' then 'reservada'
                      else null
                    end;
    alter table public.posiciones drop column estado_tarea;
  end if;
end $$;

alter table public.posiciones drop constraint if exists posiciones_estado_chk;
alter table public.posiciones add constraint posiciones_estado_chk
  check (estado is null or estado in ('reservada', 'tarea_hecha', 'confirmada', 'plazo_vencido', 'retirada'));

alter table public.posiciones drop constraint if exists posiciones_origen_chk;
alter table public.posiciones add constraint posiciones_origen_chk
  check (origen is null or origen in ('admin', 'automatico'));

-- Casilla libre: sin origen y estado NULL/retirada. Casilla ocupada: con origen y nunca "retirada".
alter table public.posiciones drop constraint if exists posiciones_coherencia_chk;
alter table public.posiciones add constraint posiciones_coherencia_chk
  check (
    (user_id is null and origen is null and (estado is null or estado = 'retirada'))
    or (user_id is not null and origen is not null and (estado is null or estado <> 'retirada'))
  );

create index if not exists posiciones_relojes_idx on public.posiciones (estado) where origen = 'automatico';

-- =====================================================================
-- 3. LISTA DE ESPERA Y NOTIFICACIONES
-- =====================================================================
create table if not exists public.lista_espera (
  user_id   uuid    not null references public.perfiles (id) on delete cascade,
  nivel_id  integer not null references public.niveles (id),
  creado_en timestamptz not null default now(),
  primary key (user_id, nivel_id)
);
create index if not exists lista_espera_nivel_idx on public.lista_espera (nivel_id, creado_en);

create table if not exists public.notificaciones (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references public.perfiles (id) on delete cascade,
  titulo    text not null,
  mensaje   text not null,
  leida     boolean not null default false,
  creada_en timestamptz not null default now()
);
create index if not exists notificaciones_user_idx on public.notificaciones (user_id, creada_en desc);

-- =====================================================================
-- 4. FUNCIONES INTERNAS (no se llaman desde la web)
-- =====================================================================

-- Plazo de configuración como intervalo (horas_* en horas, dias_* en días)
create or replace function public.intervalo_config(p_clave text)
returns interval
language sql
stable
security definer
set search_path = ''
as $$
  select (case when p_clave like 'dias\_%' then interval '1 day' else interval '1 hour' end)
         * coalesce(
             (select c.valor from public.configuracion c where c.clave = p_clave),
             case p_clave when 'horas_tarea' then 4 when 'horas_aviso' then 3 when 'dias_invitar' then 7 else 0 end
           )::float8;
$$;

-- Número sin ceros sobrantes y con coma decimal: 4 -> "4", 0.05 -> "0,05"
create or replace function public.texto_numero(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(rtrim(rtrim(to_char(p, 'FM9999999990.9999'), '0'), '.'), '.', ',');
$$;

-- Duración legible: "2 d 3 h", "1 h 30 min", "12 min"
create or replace function public.texto_duracion(p interval)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when s >= 86400 then (s / 86400)::int || ' d' || case when (s % 86400) / 3600 >= 1 then ' ' || ((s % 86400) / 3600)::int || ' h' else '' end
    when s >= 3600  then (s / 3600)::int || ' h' || case when (s % 3600) / 60 >= 1 then ' ' || ((s % 3600) / 60)::int || ' min' else '' end
    else greatest(1, ceil(s / 60.0))::int || ' min'
  end
  from (select floor(greatest(extract(epoch from p), 0))::bigint as s) x;
$$;

create or replace function public.nombre_posicion(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p
    when 'recibidor' then 'Recibidor'
    when 'constructor_1' then 'Constructor 1'
    when 'constructor_2' then 'Constructor 2'
    when 'regalador_1' then 'Regalador 1'
    when 'regalador_2' then 'Regalador 2'
    when 'regalador_3' then 'Regalador 3'
    when 'regalador_4' then 'Regalador 4'
    else p end;
$$;

create or replace function public.notificar(p_user_id uuid, p_titulo text, p_mensaje text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notificaciones (user_id, titulo, mensaje)
  select p_user_id, p_titulo, p_mensaje where p_user_id is not null;
$$;

create or replace function public.notificar_admins(p_titulo text, p_mensaje text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notificaciones (user_id, titulo, mensaje)
  select a.user_id, p_titulo, p_mensaje
  from public.administradores a
  join public.perfiles pe on pe.id = a.user_id;
$$;

-- Si hay gente esperando en el nivel, avisa al administrador (no coloca a nadie solo)
create or replace function public.avisar_lista_espera(p_nivel_id integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cuantos int;
  v_nivel   text;
begin
  select count(*) into v_cuantos from public.lista_espera where nivel_id = p_nivel_id;
  if v_cuantos > 0 then
    select nombre into v_nivel from public.niveles where id = p_nivel_id;
    perform public.notificar_admins(
      'Lugar libre con lista de espera',
      format('Se liberó un lugar en el nivel %s y hay %s persona(s) en lista de espera. Asígnalo en Administración → Lista de espera.',
             v_nivel, v_cuantos));
  end if;
end;
$$;

-- Invitados de una persona que tienen posición en ese nivel
create or replace function public.contar_invitados(p_user_id uuid, p_nivel_id integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
  from public.perfiles pe
  where pe.invitado_por = p_user_id
    and exists (select 1 from public.posiciones po where po.user_id = pe.id and po.nivel_id = p_nivel_id);
$$;

-- ¿Puede esta persona participar en este nivel?
-- Fase 3: solo el primer nivel. Cuando exista "subir de nivel", se ampliará aquí.
create or replace function public.nivel_habilitado(p_user_id uuid, p_nivel_id integer)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select n.orden = 1 from public.niveles n where n.id = p_nivel_id), false);
$$;

-- Valida que el admin pueda poner a p_user_id en la casilla (bloquea la fila). Devuelve la casilla.
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
  if not exists (select 1 from public.perfiles where id = p_user_id) then
    raise exception 'Ese usuario no existe.';
  end if;
  if v_pos.user_id = p_user_id then
    raise exception 'Esa persona ya está en esta casilla.';
  end if;
  if exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'Ese usuario ya tiene una posición en este nivel.';
  end if;

  -- Orden para casillas vacías: Recibidor -> Constructor 1 -> Constructor 2 -> Regaladores
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

-- Pone a una persona en una casilla. Con relojes = origen automático (4 h para la tarea, etc.).
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
         estado         = case when p_con_relojes or posicion like 'regalador%' then 'reservada' end,
         reservada_en   = case when p_con_relojes then now() end,
         tarea_hecha_en = null,
         aviso_enviado  = false
   where id = p_posicion_id;

  delete from public.lista_espera
   where user_id = p_user_id
     and nivel_id = (select nivel_id from public.posiciones where id = p_posicion_id);
$$;

-- Deja una casilla libre
create or replace function public.liberar_posicion(p_posicion_id uuid, p_estado text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.posiciones
     set user_id = null, origen = null, estado = p_estado, asignado_en = null,
         reservada_en = null, tarea_hecha_en = null, aviso_enviado = false
   where id = p_posicion_id;
$$;

create or replace function public.recibidor_de_grupo(p_grupo_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select user_id from public.posiciones where grupo_id = p_grupo_id and posicion = 'recibidor';
$$;

-- =====================================================================
-- 5. FUNCIONES PARA LA WEB (rpc)
-- =====================================================================

-- ---------- participar ----------
create or replace function public.participar(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo        uuid := (select auth.uid());
  v_nivel     public.niveles;
  v_invitador uuid;
  v_pos_inv   public.posiciones;
  v_libre     public.posiciones;
  v_debajo    text[];
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
  select invitado_por into v_invitador from public.perfiles where id = v_yo for update;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  if not public.nivel_habilitado(v_yo, p_nivel_id) then
    raise exception 'Este nivel todavía no está habilitado para ti.';
  end if;
  if exists (select 1 from public.posiciones where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya tienes una posición en este nivel.';
  end if;
  if exists (select 1 from public.lista_espera where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya estás en la lista de espera de este nivel.';
  end if;

  -- Grupo del invitador en este nivel (si está en uno activo)
  if v_invitador is not null then
    select po.* into v_pos_inv
    from public.posiciones po
    join public.grupos g on g.id = po.grupo_id and g.estado = 'activo'
    where po.user_id = v_invitador and po.nivel_id = p_nivel_id;
  end if;

  if v_pos_inv.id is not null then
    v_debajo := case v_pos_inv.posicion
      when 'recibidor'     then array['constructor_1', 'constructor_2', 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4']
      when 'constructor_1' then array['regalador_1', 'regalador_2']
      when 'constructor_2' then array['regalador_3', 'regalador_4']
      else array[]::text[]
    end;

    -- Primero debajo del invitador; si no, el primer libre en orden.
    -- FOR UPDATE: si otra persona toma el mismo lugar a la vez, se espera y se salta al siguiente libre.
    select p.* into v_libre
    from public.posiciones p
    where p.grupo_id = v_pos_inv.grupo_id
      and p.user_id is null
      and p.posicion <> 'recibidor'
    order by (p.posicion = any (v_debajo)) desc,
             array_position(array['constructor_1', 'constructor_2', 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], p.posicion)
    limit 1
    for update;
  end if;

  -- Sin lugar o sin grupo del invitador -> lista de espera
  if v_libre.id is null then
    insert into public.lista_espera (user_id, nivel_id) values (v_yo, p_nivel_id);
    perform public.notificar(v_yo, 'Estás en lista de espera',
      format('No hay un lugar libre en el grupo de quien te invitó en el nivel %s. El administrador te asignará un lugar cuando se libere uno.', v_nivel.nombre));
    perform public.notificar_admins('Nueva persona en lista de espera',
      format('%s tocó Participar en el nivel %s y quedó en lista de espera.',
             (select nombre_usuario from public.perfiles where id = v_yo), v_nivel.nombre));
    return jsonb_build_object('resultado', 'lista_espera', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre);
  end if;

  perform public.ocupar_posicion(v_libre.id, v_yo, true);

  perform public.notificar(v_yo, 'Reservaste tu lugar',
    format('Ocupas la posición %s en el nivel %s. Tienes %s horas para hacer tu tarea, avisar al recibidor por WhatsApp y marcarla como hecha.',
           public.nombre_posicion(v_libre.posicion), v_nivel.nombre,
           public.texto_numero((select valor from public.configuracion where clave = 'horas_tarea'))));

  v_recibidor := public.recibidor_de_grupo(v_libre.grupo_id);
  if v_recibidor is not null and v_recibidor <> v_yo then
    perform public.notificar(v_recibidor, 'Nueva persona en tu grupo',
      format('%s entró a tu grupo del nivel %s como %s.',
             (select nombre_usuario from public.perfiles where id = v_yo), v_nivel.nombre,
             public.nombre_posicion(v_libre.posicion)));
  end if;

  return jsonb_build_object('resultado', 'colocado', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                            'grupo_id', v_libre.grupo_id, 'posicion', v_libre.posicion);
end;
$$;

-- ---------- marcar_tarea_hecha ----------
-- Sin parámetro: usa la posición "reservada" del usuario. Detiene el reloj de horas_tarea
-- y arranca el de dias_invitar.
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
  where user_id = v_yo and estado = 'reservada'
    and (p_posicion_id is null or id = p_posicion_id)
  order by reservada_en nulls last
  limit 1
  for update;

  if not found then
    raise exception 'No tienes una tarea pendiente por marcar.';
  end if;
  if v_pos.origen = 'automatico' and now() >= v_pos.reservada_en + public.intervalo_config('horas_tarea') then
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

-- ---------- confirmar_tarea ----------
create or replace function public.confirmar_tarea(p_posicion_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo  uuid := (select auth.uid());
  v_pos public.posiciones;
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
  if v_pos.estado = 'confirmada' then
    raise exception 'Esa tarea ya fue aprobada.';
  end if;
  if v_pos.estado is distinct from 'tarea_hecha' then
    raise exception 'Esa persona todavía no marcó su tarea como hecha.';
  end if;

  update public.posiciones set estado = 'confirmada' where id = p_posicion_id;

  perform public.notificar(v_pos.user_id, 'Tu tarea fue confirmada',
    'El recibidor confirmó que recibió tu tarea.');
end;
$$;

-- ---------- candidatos_reemplazo ----------
-- Personas que pueden reemplazar a quien está en la casilla: invitadas por el mismo invitador
-- y en lista de espera de ese nivel. Solo para el admin o para ese invitador.
create or replace function public.candidatos_reemplazo(p_posicion_id uuid)
returns table (user_id uuid, nombre_usuario text, en_espera_desde timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select le.user_id, pe.nombre_usuario, le.creado_en
  from public.posiciones po
  join public.perfiles retirado on retirado.id = po.user_id
  join public.perfiles pe on pe.invitado_por = retirado.invitado_por
  join public.lista_espera le on le.user_id = pe.id and le.nivel_id = po.nivel_id
  where po.id = p_posicion_id
    and pe.id <> retirado.id
    and (public.es_admin() or retirado.invitado_por = (select auth.uid()))
  order by le.creado_en;
$$;

-- ---------- retirar_y_reemplazar ----------
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
  -- El admin solo puede usarlo con plazo vencido; quien invitó puede retirar a su invitado.
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

  -- Libera y coloca al nuevo en un solo paso
  perform public.liberar_posicion(p_posicion_id, 'retirada');
  perform public.ocupar_posicion(p_posicion_id, p_nuevo_user_id, true);

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;

  perform public.notificar(v_retirado, 'Fuiste retirado de tu posición',
    format('Saliste de la posición %s del nivel %s y tu lugar fue asignado a otra persona.',
           public.nombre_posicion(v_pos.posicion), v_nivel));
  perform public.notificar(p_nuevo_user_id, 'Reservaste tu lugar',
    format('Te colocaron como %s en el nivel %s. Tienes %s horas para hacer tu tarea, avisar al recibidor por WhatsApp y marcarla como hecha.',
           public.nombre_posicion(v_pos.posicion), v_nivel,
           public.texto_numero((select valor from public.configuracion where clave = 'horas_tarea'))));
end;
$$;

-- ---------- mi_reloj ----------
-- Datos del reloj del usuario, calculados con la hora del SERVIDOR (campo "ahora").
-- Devuelve NULL si no tiene una posición con relojes.
create or replace function public.mi_reloj(p_nivel_id integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo  uuid := (select auth.uid());
  v_pos public.posiciones;
  v_nivel text;
  v_rec uuid;
begin
  select * into v_pos
  from public.posiciones
  where user_id = v_yo
    and origen = 'automatico'
    and estado in ('reservada', 'tarea_hecha', 'confirmada', 'plazo_vencido')
    and (p_nivel_id is null or nivel_id = p_nivel_id)
  order by (estado = 'reservada') desc, reservada_en desc
  limit 1;

  if not found then
    return null;
  end if;

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  v_rec := public.recibidor_de_grupo(v_pos.grupo_id);

  return jsonb_build_object(
    'ahora',              now(),
    'posicion_id',        v_pos.id,
    'posicion',           v_pos.posicion,
    'nivel_id',           v_pos.nivel_id,
    'nivel_nombre',       v_nivel,
    'estado',             v_pos.estado,
    'reservada_en',       v_pos.reservada_en,
    'fin_tarea',          v_pos.reservada_en + public.intervalo_config('horas_tarea'),
    'tarea_hecha_en',     v_pos.tarea_hecha_en,
    'fin_invitar',        v_pos.tarea_hecha_en + public.intervalo_config('dias_invitar'),
    'invitados',          public.contar_invitados(v_yo, v_pos.nivel_id),
    'recibidor_nombre',   (select nombre_usuario from public.perfiles where id = v_rec),
    'recibidor_whatsapp', case when v_rec is not null then public.whatsapp_de(v_rec) end
  );
end;
$$;

-- ---------- posiciones_de_grupo (redefinida: ahora devuelve estado y relojes) ----------
drop function if exists public.posiciones_de_grupo(uuid);
create function public.posiciones_de_grupo(p_grupo_id uuid)
returns table (
  posicion_id    uuid,
  posicion       text,
  cuelga_de      text,
  user_id        uuid,
  nombre_usuario text,
  estado         text,
  origen         text,
  reservada_en   timestamptz,
  tarea_hecha_en timestamptz,
  es_mi_invitado boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select po.id, po.posicion, po.cuelga_de, po.user_id, pe.nombre_usuario,
         po.estado, po.origen, po.reservada_en, po.tarea_hecha_en,
         coalesce(pe.invitado_por = (select auth.uid()), false)
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

-- =====================================================================
-- 6. ACCIONES DEL ADMINISTRADOR (redefinidas: ahora con origen, estado y notificaciones)
--    Son security definer y comprueban es_admin() al inicio.
-- =====================================================================
create or replace function public.admin_asignar_posicion(p_posicion_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posiciones;
  v_nivel text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede asignar posiciones.';
  end if;

  v_pos := public.validar_asignacion(p_posicion_id, p_user_id);
  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;

  if v_pos.user_id is not null then
    perform public.notificar(v_pos.user_id, 'Fuiste reemplazado',
      format('El administrador te reemplazó en la posición %s del nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));
  end if;

  perform public.ocupar_posicion(p_posicion_id, p_user_id, false);

  perform public.notificar(p_user_id, 'Tienes una posición',
    format('El administrador te asignó como %s en el nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));
end;
$$;

create or replace function public.admin_quitar_posicion(p_posicion_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posiciones;
  v_nivel text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede quitar posiciones.';
  end if;

  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla ya está libre.';
  end if;

  perform public.liberar_posicion(p_posicion_id, null);

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  perform public.notificar(v_pos.user_id, 'Saliste de tu posición',
    format('El administrador te quitó de la posición %s del nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));
  perform public.avisar_lista_espera(v_pos.nivel_id);
end;
$$;

-- Asignar a alguien de la lista de espera a una casilla libre
create or replace function public.admin_asignar_desde_espera(p_user_id uuid, p_posicion_id uuid, p_con_relojes boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posiciones;
  v_nivel text;
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
  perform public.notificar(p_user_id, 'Reservaste tu lugar',
    format('El administrador te asignó como %s en el nivel %s.%s', public.nombre_posicion(v_pos.posicion), v_nivel,
           case when coalesce(p_con_relojes, true)
                then format(' Tienes %s horas para hacer tu tarea y marcarla como hecha.',
                            public.texto_numero((select valor from public.configuracion where clave = 'horas_tarea')))
                else '' end));
  perform public.notificar(public.recibidor_de_grupo(v_pos.grupo_id), 'Nueva persona en tu grupo',
    format('%s entró a tu grupo del nivel %s como %s.',
           (select nombre_usuario from public.perfiles where id = p_user_id), v_nivel, public.nombre_posicion(v_pos.posicion)));
end;
$$;

create or replace function public.admin_guardar_configuracion(p_horas_tarea numeric, p_horas_aviso numeric, p_dias_invitar numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar la configuración.';
  end if;
  if p_horas_tarea is null or p_horas_tarea <= 0
     or p_horas_aviso is null or p_horas_aviso <= 0
     or p_dias_invitar is null or p_dias_invitar <= 0 then
    raise exception 'Todos los valores deben ser números mayores que 0.';
  end if;
  if p_horas_aviso >= p_horas_tarea then
    raise exception 'Las horas del aviso deben ser menores que las horas para hacer la tarea.';
  end if;

  insert into public.configuracion (clave, valor) values
    ('horas_tarea', p_horas_tarea), ('horas_aviso', p_horas_aviso), ('dias_invitar', p_dias_invitar)
  on conflict (clave) do update set valor = excluded.valor, actualizado_en = now();
end;
$$;

-- =====================================================================
-- 7. REVISAR PLAZOS (pg_cron cada 5 minutos)
-- =====================================================================
create or replace function public.revisar_plazos()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r             record;
  v_tarea       interval := public.intervalo_config('horas_tarea');
  v_aviso       interval := public.intervalo_config('horas_aviso');
  v_invitar     interval := public.intervalo_config('dias_invitar');
  v_retirados   int := 0;
  v_avisos      int := 0;
  v_vencidos    int := 0;
begin
  -- (a) Reservada sin tarea hecha y pasaron horas_tarea: sale de la posición
  for r in
    select p.id, p.user_id, p.posicion, p.nivel_id, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.origen = 'automatico' and p.estado = 'reservada' and p.tarea_hecha_en is null
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
    where p.origen = 'automatico' and p.estado = 'reservada' and p.tarea_hecha_en is null
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

  -- (c) dias_invitar desde tarea_hecha_en con menos de 2 invitados con posición: plazo vencido
  for r in
    select p.id, p.user_id, p.nivel_id, n.nombre as nivel, pe.nombre_usuario, pe.invitado_por
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    join public.perfiles pe on pe.id = p.user_id
    where p.origen = 'automatico' and p.estado in ('tarea_hecha', 'confirmada')
      and p.tarea_hecha_en is not null
      and p.tarea_hecha_en + v_invitar <= now()
      and public.contar_invitados(p.user_id, p.nivel_id) < 2
    for update of p skip locked
  loop
    update public.posiciones set estado = 'plazo_vencido' where id = r.id;
    perform public.notificar(r.user_id, 'Plazo vencido',
      format('Pasaron %s desde que hiciste tu tarea y no completaste tus 2 invitados en el nivel %s. Tu posición quedó suspendida y quien te invitó puede reemplazarte.',
             public.texto_duracion(v_invitar), r.nivel));
    perform public.notificar(r.invitado_por, 'Tu invitado tiene el plazo vencido',
      format('%s no completó sus 2 invitados a tiempo en el nivel %s. En Mi grupo puedes usar "Retirar y reemplazar" para poner a alguien que invitaste y esté en lista de espera.',
             r.nombre_usuario, r.nivel));
    v_vencidos := v_vencidos + 1;
  end loop;

  return jsonb_build_object('retirados', v_retirados, 'avisos', v_avisos, 'plazos_vencidos', v_vencidos);
end;
$$;

-- Para probar sin esperar a pg_cron: el administrador puede ejecutar la revisión desde la web
create or replace function public.admin_revisar_plazos()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede revisar los plazos.';
  end if;
  return public.revisar_plazos();
end;
$$;

-- =====================================================================
-- 8. RLS
-- =====================================================================
alter table public.configuracion  enable row level security;
alter table public.lista_espera   enable row level security;
alter table public.notificaciones enable row level security;

-- configuracion: todos con sesión leen; solo admin escribe
drop policy if exists "configuracion: leer con sesión" on public.configuracion;
create policy "configuracion: leer con sesión"
  on public.configuracion for select to authenticated using (true);

drop policy if exists "configuracion: admin escribe" on public.configuracion;
create policy "configuracion: admin escribe"
  on public.configuracion for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- lista_espera: cada uno ve la suya; el admin ve todas (se escribe solo con funciones)
drop policy if exists "lista_espera: ver la propia" on public.lista_espera;
create policy "lista_espera: ver la propia"
  on public.lista_espera for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "lista_espera: admin lee" on public.lista_espera;
create policy "lista_espera: admin lee"
  on public.lista_espera for select to authenticated
  using (public.es_admin());

-- notificaciones: cada uno ve y marca como leídas solo las suyas
drop policy if exists "notificaciones: ver las propias" on public.notificaciones;
create policy "notificaciones: ver las propias"
  on public.notificaciones for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "notificaciones: marcar las propias" on public.notificaciones;
create policy "notificaciones: marcar las propias"
  on public.notificaciones for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- =====================================================================
-- 9. GRANTs
-- =====================================================================
revoke all on table public.configuracion, public.lista_espera, public.notificaciones from anon, authenticated;

grant select on table public.configuracion to authenticated;
grant update (valor, actualizado_en) on table public.configuracion to authenticated;  -- RLS: solo admin
grant select on table public.lista_espera to authenticated;
grant select on table public.notificaciones to authenticated;
grant update (leida) on table public.notificaciones to authenticated;

-- Funciones internas: nadie las llama desde la web
revoke execute on function public.intervalo_config(text)                          from public, anon, authenticated;
revoke execute on function public.texto_numero(numeric)                           from public, anon, authenticated;
revoke execute on function public.texto_duracion(interval)                        from public, anon, authenticated;
revoke execute on function public.nombre_posicion(text)                           from public, anon, authenticated;
revoke execute on function public.notificar(uuid, text, text)                     from public, anon, authenticated;
revoke execute on function public.notificar_admins(text, text)                    from public, anon, authenticated;
revoke execute on function public.avisar_lista_espera(integer)                    from public, anon, authenticated;
revoke execute on function public.contar_invitados(uuid, integer)                 from public, anon, authenticated;
revoke execute on function public.nivel_habilitado(uuid, integer)                 from public, anon, authenticated;
revoke execute on function public.validar_asignacion(uuid, uuid)                  from public, anon, authenticated;
revoke execute on function public.ocupar_posicion(uuid, uuid, boolean)            from public, anon, authenticated;
revoke execute on function public.liberar_posicion(uuid, text)                    from public, anon, authenticated;
revoke execute on function public.recibidor_de_grupo(uuid)                        from public, anon, authenticated;
revoke execute on function public.revisar_plazos()                                from public, anon, authenticated;

-- Funciones para la web (rpc), solo con sesión
revoke execute on function public.participar(integer)                             from public, anon;
revoke execute on function public.marcar_tarea_hecha(uuid)                        from public, anon;
revoke execute on function public.confirmar_tarea(uuid)                           from public, anon;
revoke execute on function public.candidatos_reemplazo(uuid)                      from public, anon;
revoke execute on function public.retirar_y_reemplazar(uuid, uuid)                from public, anon;
revoke execute on function public.mi_reloj(integer)                               from public, anon;
revoke execute on function public.posiciones_de_grupo(uuid)                       from public, anon;
revoke execute on function public.admin_asignar_posicion(uuid, uuid)              from public, anon;
revoke execute on function public.admin_quitar_posicion(uuid)                     from public, anon;
revoke execute on function public.admin_asignar_desde_espera(uuid, uuid, boolean) from public, anon;
revoke execute on function public.admin_guardar_configuracion(numeric, numeric, numeric) from public, anon;
revoke execute on function public.admin_revisar_plazos()                          from public, anon;

grant execute on function public.participar(integer)                             to authenticated;
grant execute on function public.marcar_tarea_hecha(uuid)                        to authenticated;
grant execute on function public.confirmar_tarea(uuid)                           to authenticated;
grant execute on function public.candidatos_reemplazo(uuid)                      to authenticated;
grant execute on function public.retirar_y_reemplazar(uuid, uuid)                to authenticated;
grant execute on function public.mi_reloj(integer)                               to authenticated;
grant execute on function public.posiciones_de_grupo(uuid)                       to authenticated;
grant execute on function public.admin_asignar_posicion(uuid, uuid)              to authenticated;
grant execute on function public.admin_quitar_posicion(uuid)                     to authenticated;
grant execute on function public.admin_asignar_desde_espera(uuid, uuid, boolean) to authenticated;
grant execute on function public.admin_guardar_configuracion(numeric, numeric, numeric) to authenticated;
grant execute on function public.admin_revisar_plazos()                          to authenticated;

-- =====================================================================
-- 10. PROGRAMAR revisar_plazos() CADA 5 MINUTOS (pg_cron)
--     Requiere activar antes la extensión pg_cron (ver instrucciones).
--     Si se re-ejecuta, la tarea con el mismo nombre se actualiza (no se duplica).
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('siembra-revisar-plazos', '*/5 * * * *', 'select public.revisar_plazos();');
    raise notice 'Tarea pg_cron "siembra-revisar-plazos" programada cada 5 minutos.';
  else
    raise notice 'pg_cron NO está activado. Actívalo (Database > Extensions > pg_cron) y vuelve a ejecutar este archivo.';
  end if;
end $$;

-- Para ver la tarea:        select * from cron.job;
-- Para ver sus ejecuciones:  select * from cron.job_run_details order by start_time desc limit 20;
-- Para quitarla:             select cron.unschedule('siembra-revisar-plazos');

notify pgrst, 'reload schema';
