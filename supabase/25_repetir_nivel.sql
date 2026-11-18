-- =====================================================================
-- Sistema Siembra tu Futuro — 25_repetir_nivel.sql
-- Ejecutar DESPUÉS de 24_reserva_elegir.sql. Se puede volver a ejecutar sin problema.
-- Desde este archivo, los SQL 18 al 24 NO se vuelven a ejecutar (crean las vueltas que este
-- archivo quita). Si re-ejecutas 01 al 17, vuelve a ejecutar este archivo después.
--
-- CAMBIO GRANDE: se quitan las VUELTAS y se agrega "REPETIR CON MI EQUIPO".
--   * Una sola posición activa por nivel (sin número de vuelta).
--   * Quien llegó a un nivel puede repetir cualquier nivel INFERIOR (repetir_nivel): se arma un
--     grupo nuevo con su equipo de siempre: él al centro (recibidor), sus 2 referidos activos
--     como constructores y los 2 referidos activos de cada uno como regaladores. Entran
--     automáticamente, con mensaje; los regaladores con su plazo de la tarea (horas_tarea).
--     No se pide que el equipo esté habilitado en ese nivel.
--   * Asiento vacío (falta la persona o ya tiene posición en ese nivel): se abre un lugar libre
--     para la reserva de su patrocinador (el que repite para los constructores; cada constructor
--     para sus regaladores). Si nadie lo toma, queda para el derrame.
--   * Una repetición activa por nivel y una espera mínima entre repeticiones
--     (configuracion.horas_espera_repetir, 0 = sin espera).
--   * La reserva (23 y 24) sigue: 2 referidos activos por patrocinador (ya no por vuelta),
--     lista de espera, el patrocinador elige en 24 h, ubicar en derrame o en su red.
--   * Se conservan el derrame con prioridad (21) y los índices (20).
--
-- MIGRACIÓN (solo la primera vez):
--   * Respaldo de las tablas afectadas en *_respaldo_25.
--   * Los casos que hubo que resolver quedan en public.revision_migracion_25 (al final se listan):
--       - posicion_duplicada: alguien tenía 2 posiciones en el mismo nivel (de vueltas distintas);
--         se conserva la de la vuelta más baja y se liberan las demás (se le avisa).
--       - espera_duplicada: estaba 2 veces en la lista de espera del mismo nivel; queda la primera.
--       - seguimiento: seguía a un patrocinador en otra vuelta; ahora sigue solo al suyo original.
--       - mas_de_2_activos: patrocinador con más de 2 referidos activos (de varias vueltas); todos
--         siguen activos y los nuevos quedarán en su lista de espera.
-- =====================================================================

-- =====================================================================
-- 0. RESPALDO (solo la primera vez)
-- =====================================================================
do $$
declare
  t text;
begin
  foreach t in array array['posiciones', 'perfiles', 'lista_espera', 'ciclos_completados',
                           'seguimientos', 'lugares_libres', 'grupos'] loop
    if to_regclass('public.' || t) is not null and to_regclass('public.' || t || '_respaldo_25') is null then
      execute format('create table public.%I as table public.%I', t || '_respaldo_25', t);
      execute format('alter table public.%I enable row level security', t || '_respaldo_25');
      execute format('revoke all on table public.%I from anon, authenticated', t || '_respaldo_25');
    end if;
  end loop;
end;
$$;

-- =====================================================================
-- 1. LISTA DE CASOS PARA REVISAR
-- =====================================================================
create table if not exists public.revision_migracion_25 (
  id             bigint generated always as identity primary key,
  tipo           text not null,
  user_id        uuid,
  nombre_usuario text,
  detalle        text not null,
  creado_en      timestamptz not null default now()
);
alter table public.revision_migracion_25 enable row level security;
revoke all on table public.revision_migracion_25 from anon, authenticated;

-- =====================================================================
-- 2. MIGRACIÓN DE LOS DATOS CON VUELTAS (solo si todavía existen las vueltas)
-- =====================================================================
do $$
declare
  r      record;
  v_keep record;
  v_lib  text;
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'posiciones' and column_name = 'vuelta') then
    return;
  end if;

  -- a) Dos posiciones en el mismo nivel (vueltas distintas): queda la de la vuelta más baja
  for r in
    select p.user_id, p.nivel_id from public.posiciones p
    where p.user_id is not null group by 1, 2 having count(*) > 1
  loop
    select p.id, p.vuelta, p.posicion into v_keep from public.posiciones p
    where p.user_id = r.user_id and p.nivel_id = r.nivel_id
    order by p.vuelta nulls last, p.asignado_en limit 1;

    select string_agg(format('%s (vuelta %s)', public.nombre_posicion(p.posicion), p.vuelta), ', ') into v_lib
    from public.posiciones p where p.user_id = r.user_id and p.nivel_id = r.nivel_id and p.id <> v_keep.id;

    insert into public.revision_migracion_25 (tipo, user_id, nombre_usuario, detalle)
    select 'posicion_duplicada', r.user_id, pe.nombre_usuario,
           format('Tenía varias posiciones en el nivel %s. Se conservó %s (vuelta %s) y se liberó: %s.',
                  n.nombre, public.nombre_posicion(v_keep.posicion), v_keep.vuelta, v_lib)
    from public.perfiles pe, public.niveles n where pe.id = r.user_id and n.id = r.nivel_id;

    update public.posiciones
       set user_id = null, vuelta = null, origen = null, estado = 'retirada', asignado_en = null,
           reservada_en = null, tarea_hecha_en = null, ascendido_en = null, aviso_enviado = false
     where user_id = r.user_id and nivel_id = r.nivel_id and id <> v_keep.id;

    perform public.notificar(r.user_id, 'Cambio en el sistema',
      format('Ya no hay vueltas: ahora se tiene una sola posición por nivel. En el nivel %s conservamos tu posición %s.',
             (select nombre from public.niveles where id = r.nivel_id), public.nombre_posicion(v_keep.posicion)));
  end loop;

  -- b) Dos veces en la lista de espera del mismo nivel: queda la primera
  for r in select le.user_id, le.nivel_id from public.lista_espera le group by 1, 2 having count(*) > 1 loop
    insert into public.revision_migracion_25 (tipo, user_id, nombre_usuario, detalle)
    select 'espera_duplicada', r.user_id, pe.nombre_usuario,
           format('Estaba varias veces en la lista de espera del nivel %s; quedó solo la primera.', n.nombre)
    from public.perfiles pe, public.niveles n where pe.id = r.user_id and n.id = r.nivel_id;
    delete from public.lista_espera le
     where le.user_id = r.user_id and le.nivel_id = r.nivel_id
       and le.ctid <> (select x.ctid from public.lista_espera x
                       where x.user_id = r.user_id and x.nivel_id = r.nivel_id order by x.creado_en limit 1);
  end loop;

  -- c) Personas que seguían a un patrocinador en otra vuelta
  if to_regclass('public.seguimientos') is not null then
    insert into public.revision_migracion_25 (tipo, user_id, nombre_usuario, detalle)
    select 'seguimiento', s.user_id, pe.nombre_usuario,
           format('Seguía a %s en su vuelta %s. Ahora sigue solo a su patrocinador original (%s).',
                  pat.nombre_usuario, s.vuelta_patrocinador, coalesce(ori.nombre_usuario, 'sin patrocinador'))
    from public.seguimientos s
    join public.perfiles pe on pe.id = s.user_id
    join public.perfiles pat on pat.id = s.patrocinador_id
    left join public.perfiles ori on ori.id = pe.invitado_por;
  end if;

  -- d) Patrocinadores con más de 2 referidos activos (2 por vuelta)
  insert into public.revision_migracion_25 (tipo, user_id, nombre_usuario, detalle)
  select 'mas_de_2_activos', p.id, p.nombre_usuario,
         format('Tiene %s referidos activos (de varias vueltas). Todos siguen activos; las personas nuevas quedarán en su lista de espera hasta que tenga menos de 2.', x.n)
  from (select invitado_por, count(*) as n from public.perfiles
        where referido_estado = 'activo' and invitado_por is not null group by 1 having count(*) > 2) x
  join public.perfiles p on p.id = x.invitado_por;
end;
$$;

-- =====================================================================
-- 3. FUNCIONES DE LAS VUELTAS QUE SE QUITAN (y firmas viejas con vuelta)
-- =====================================================================
drop trigger if exists posiciones_poner_vuelta on public.posiciones;
drop function if exists public.posiciones_poner_vuelta();
drop function if exists public.vuelta_para_participar(uuid, integer);
drop function if exists public.vuelta_para_asignar(uuid, integer);
drop function if exists public.patrocinador_en_vuelta(uuid, integer);
drop function if exists public.mis_vueltas();
drop function if exists public.contar_seguidores(uuid, integer);
drop function if exists public.contar_invitados_vuelta(uuid, integer, integer);
drop function if exists public.ocupar_posicion(uuid, uuid, boolean, integer);
drop function if exists public.colocar_ascendido(uuid, text, uuid, integer);
drop function if exists public.mi_reloj(integer, integer);
drop function if exists public.mi_grupo_resumen(integer, integer);
drop function if exists public.promover_reserva(uuid, integer, uuid, uuid);
drop function if exists public.promover_reserva(uuid, integer, uuid);
drop function if exists public.abrir_lugar_libre(uuid, integer, uuid);
drop function if exists public.reserva_tras_vencer(uuid, integer, uuid);
drop function if exists public.eliminar_referido(uuid, integer);

-- =====================================================================
-- 4. TABLAS SIN VUELTAS
-- =====================================================================
-- Posiciones: una sola por nivel
alter table public.posiciones drop constraint if exists posiciones_usuario_nivel_vuelta_uk;
alter table public.posiciones drop column if exists vuelta;
alter table public.posiciones drop constraint if exists posiciones_usuario_nivel_uk;
alter table public.posiciones add constraint posiciones_usuario_nivel_uk unique (user_id, nivel_id);

-- Lista de espera: por nivel
alter table public.lista_espera drop constraint if exists lista_espera_pkey;
alter table public.lista_espera drop column if exists vuelta;
alter table public.lista_espera add constraint lista_espera_pkey primary key (user_id, nivel_id);

-- Ciclos completados: historial (un nivel puede aparecer varias veces, una por repetición)
drop index if exists public.ciclos_usuario_nivel_vuelta_uk;
alter table public.ciclos_completados drop column if exists vuelta;
create index if not exists ciclos_usuario_nivel_idx on public.ciclos_completados (user_id, nivel_id);

-- Perfiles: sin vuelta actual ni vuelta de invitación (la reserva sigue)
drop index if exists public.perfiles_reserva_idx;
drop index if exists public.perfiles_invitado_vuelta_idx;
alter table public.perfiles drop constraint if exists perfiles_vuelta_actual_chk;
alter table public.perfiles drop column if exists vuelta_actual;
alter table public.perfiles drop column if exists invitado_vuelta;
create index if not exists perfiles_reserva_idx on public.perfiles (invitado_por, reserva_desde)
  where referido_estado = 'reserva';
create index if not exists perfiles_activos_idx on public.perfiles (invitado_por)
  where referido_estado = 'activo';

-- Ya no se sigue a nadie "en otra vuelta"
drop table if exists public.seguimientos;

-- Lugares libres: por patrocinador
drop index if exists public.lugares_libres_patrocinador_idx;
alter table public.lugares_libres drop column if exists vuelta;
create index if not exists lugares_libres_patrocinador_idx on public.lugares_libres (patrocinador_id);

-- Grupos: normal o repetido (y quién lo repitió)
alter table public.grupos add column if not exists tipo text not null default 'normal';
alter table public.grupos drop constraint if exists grupos_tipo_chk;
alter table public.grupos add constraint grupos_tipo_chk check (tipo in ('normal', 'repetido'));
alter table public.grupos add column if not exists repetido_por uuid references public.perfiles (id) on delete set null;
create index if not exists grupos_repetido_por_idx on public.grupos (repetido_por, creado_en) where tipo = 'repetido';

-- Espera mínima entre repeticiones (0 = sin espera); el 0 se permite solo para esta clave y la de registro
alter table public.configuracion drop constraint if exists configuracion_valor_chk;
alter table public.configuracion add constraint configuracion_valor_chk
  check (
    valor >= 0
    and (clave <> 'registro_exige_link' or valor in (0, 1))
    and (clave in ('registro_exige_link', 'horas_espera_repetir') or valor > 0)
  );
insert into public.configuracion (clave, valor, descripcion) values
  ('horas_espera_repetir', 0, 'Horas mínimas entre dos repeticiones de nivel de la misma persona (0 = sin espera).')
on conflict (clave) do nothing;
-- Para cambiarla (SQL Editor):  update public.configuracion set valor = 24 where clave = 'horas_espera_repetir';

-- =====================================================================
-- 5. CONTEOS (sin vueltas)
-- =====================================================================
-- Referidos activos de una persona (máximo 2; los demás están en su lista de espera)
create or replace function public.contar_activos(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.perfiles where invitado_por = p_user_id and referido_estado = 'activo';
$$;

create or replace function public.contar_referidos(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select public.contar_activos(p_user_id);
$$;

-- Referidos activos que ya tienen posición en el nivel (para el reloj del constructor)
create or replace function public.contar_invitados(p_user_id uuid, p_nivel_id integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
  from public.perfiles pe
  where pe.invitado_por = p_user_id and pe.referido_estado = 'activo'
    and exists (select 1 from public.posiciones po where po.user_id = pe.id and po.nivel_id = p_nivel_id);
$$;

-- ¿Ese lugar lo guarda un constructor para sus referidos? (reloj corriendo y menos de 2 con posición)
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
      and public.contar_invitados(c.user_id, c.nivel_id) < 2
  );
$$;

-- Alta: activo si tiene menos de 2 activos y nadie en espera; si no, al final de la espera
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

  if public.contar_activos(new.invitado_por) >= 2
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

-- =====================================================================
-- 6. CASILLAS (sin vueltas)
-- =====================================================================
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

-- =====================================================================
-- 7. ASCENSO (el ciclo queda en el historial; un nivel puede completarse varias veces)
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
-- 8. RELOJES Y RESÚMENES (sin vueltas)
-- =====================================================================
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

create or replace function public.mi_grupo_resumen(p_nivel_id integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo    uuid := (select auth.uid());
  v_grupo uuid;
begin
  select p.grupo_id into v_grupo
  from public.posiciones p
  join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
  where p.user_id = v_yo and p.nivel_id = p_nivel_id;

  if v_grupo is null then
    return null;
  end if;

  return jsonb_build_object(
    'nivel_id',  p_nivel_id,
    'nivel',     (select nombre from public.niveles where id = p_nivel_id),
    'repetido',  (select tipo = 'repetido' from public.grupos where id = v_grupo),
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

  select n.* into v_actual
  from public.posiciones p join public.niveles n on n.id = p.nivel_id
  where p.user_id = v_yo
  order by n.orden desc limit 1;

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
               'posicion', (select p.posicion from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id),
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

-- =====================================================================
-- 9. RETIRAR Y REEMPLAZAR (sin vueltas)
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

  perform public.liberar_posicion(p_posicion_id, 'retirada');
  perform public.ocupar_posicion(p_posicion_id, p_nuevo_user_id, true);

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;

  perform public.notificar(v_retirado, 'Fuiste retirado de tu posición',
    format('Saliste de la posición %s del nivel %s y tu lugar fue asignado a otra persona.',
           public.nombre_posicion(v_pos.posicion), v_nivel));
  perform public.notificar_lugar(p_nuevo_user_id, v_pos.posicion, v_nivel,
    format('Te colocaron como %s en el nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));

  if not v_es_invitador then
    perform public.avisar_patrocinador(v_retirado, v_pos.posicion, v_pos.nivel_id,
      format('fue retirado por plazo vencido y su lugar lo ocupa %s.',
             (select nombre_usuario from public.perfiles where id = p_nuevo_user_id)));
  end if;
end;
$$;

-- =====================================================================
-- 10. RESERVA DE REFERIDOS (23 y 24, sin vueltas)
-- =====================================================================
-- Una persona de la espera (la elegida o la 1.ª) pasa a activa y toma la casilla libre si sirve:
-- regalador del primer nivel, o cualquier casilla (no la del centro) de un grupo repetido.
create or replace function public.promover_reserva(p_patrocinador uuid, p_casilla uuid, p_user_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_pos   public.posiciones;
  v_nivel text;
  v_rec   uuid;
begin
  if p_patrocinador is null or public.contar_activos(p_patrocinador) >= 2 then
    return null;
  end if;

  select pe.id, pe.nombre_usuario into r
  from public.perfiles pe
  where pe.invitado_por = p_patrocinador and pe.referido_estado = 'reserva'
    and (p_user_id is null or pe.id = p_user_id)
  order by coalesce(pe.reserva_desde, pe.creado_en), pe.id
  limit 1
  for update skip locked;
  if not found then
    return null;
  end if;

  update public.perfiles set referido_estado = 'activo', reserva_desde = null where id = r.id;

  if p_casilla is not null then
    select p.* into v_pos
    from public.posiciones p
    join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
    where p.id = p_casilla and p.user_id is null
      and ((p.posicion like 'regalador%' and public.nivel_anterior(p.nivel_id) is null)
           or (g.tipo = 'repetido' and p.posicion <> 'recibidor'))
      and not exists (select 1 from public.posiciones x where x.user_id = r.id and x.nivel_id = p.nivel_id)
    for update of p skip locked;
  end if;

  if v_pos.id is not null then
    perform public.ocupar_posicion(v_pos.id, r.id, true);
    select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
    perform public.notificar(r.id, 'Ya tienes tu lugar',
      case when v_pos.posicion like 'regalador%'
           then format('Tomaste un lugar de tu patrocinador: %s en el nivel %s. Tienes %s para hacer tu tarea, escribir al recibidor y marcarla como hecha.',
                       public.nombre_posicion(v_pos.posicion), v_nivel, public.texto_duracion(public.intervalo_config('horas_tarea')))
           else format('Tomaste un lugar de tu patrocinador: %s en el nivel %s. Tienes %s para invitar a 2 personas.',
                       public.nombre_posicion(v_pos.posicion), v_nivel, public.texto_dias_invitar(v_pos.nivel_id))
      end);
    v_rec := public.recibidor_de_grupo(v_pos.grupo_id);
    if v_rec is not null and v_rec <> r.id then
      perform public.notificar(v_rec, 'Nueva persona en tu grupo',
        format('%s entró a tu grupo del nivel %s como %s.', r.nombre_usuario, v_nivel, public.nombre_posicion(v_pos.posicion)));
    end if;
  else
    perform public.notificar(r.id, 'Ya eres referido activo',
      'Tomaste un lugar de tu patrocinador y ya no estás en espera. Ve a Niveles y toca Participar para entrar en su grupo.');
  end if;
  return r.id;
end;
$$;

-- Se liberó un lugar del patrocinador: si tiene gente en espera, elige quién lo toma (24 h)
create or replace function public.abrir_lugar_libre(p_patrocinador uuid, p_casilla uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_patrocinador is null
     or public.contar_activos(p_patrocinador) >= 2
     or not exists (select 1 from public.perfiles pe
                    where pe.invitado_por = p_patrocinador and pe.referido_estado = 'reserva') then
    return;
  end if;
  -- Nunca más lugares pendientes que lugares de referido realmente libres: si ya hay uno
  -- pendiente, se le asigna esta casilla (por ejemplo, el asiento vacío de un grupo repetido)
  if (select count(*) from public.lugares_libres where patrocinador_id = p_patrocinador)
       >= 2 - public.contar_activos(p_patrocinador) then
    if p_casilla is not null then
      update public.lugares_libres set casilla_id = p_casilla
       where id = (select l.id from public.lugares_libres l
                   where l.patrocinador_id = p_patrocinador
                   order by (l.casilla_id is null) desc, l.liberado_en limit 1);
    end if;
    return;
  end if;
  insert into public.lugares_libres (patrocinador_id, casilla_id) values (p_patrocinador, p_casilla);
  perform public.notificar(p_patrocinador, 'Tienes un lugar libre: elige quién lo toma',
    format('Se liberó uno de tus 2 lugares. En Inicio, en "Mis referidos", elige quién de tu lista de espera lo toma. Si no eliges en %s, entra automáticamente el 1.º en espera.',
           public.texto_duracion(public.intervalo_config('horas_elegir_reserva'))));
end;
$$;

-- Plazo de la tarea vencido: si el patrocinador tiene gente en espera, el vencido pasa al final
-- de la espera y el patrocinador elige quién toma la casilla
create or replace function public.reserva_tras_vencer(p_user_id uuid, p_casilla uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_perfil public.perfiles;
  v_n      integer;
begin
  select * into v_perfil from public.perfiles where id = p_user_id;
  if not found or v_perfil.invitado_por is null or v_perfil.referido_estado <> 'activo' then
    return;
  end if;
  if not exists (select 1 from public.perfiles pe
                 where pe.invitado_por = v_perfil.invitado_por and pe.referido_estado = 'reserva' and pe.id <> p_user_id) then
    return;
  end if;

  update public.perfiles set referido_estado = 'reserva', reserva_desde = now() where id = p_user_id;
  select count(*) into v_n from public.perfiles pe
  where pe.invitado_por = v_perfil.invitado_por and pe.referido_estado = 'reserva';
  perform public.notificar(p_user_id, 'Pasaste a la lista de espera',
    format('Se venció tu plazo y tu patrocinador elegirá quién de su lista de espera toma tu lugar. Ahora eres el %s en espera. También puedes entrar por derrame desde Niveles.', v_n));
  perform public.abrir_lugar_libre(v_perfil.invitado_por, p_casilla);
end;
$$;

-- El patrocinador elimina a uno de sus 2 referidos activos (solo si todavía es regalador)
create or replace function public.eliminar_referido(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := (select auth.uid());
  v_ref     public.perfiles;
  r         record;
  v_casilla uuid;
  v_rec     uuid;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  perform 1 from public.perfiles where id = v_yo for update;

  select * into v_ref from public.perfiles where id = p_user_id for update;
  if not found then
    raise exception 'No se encontró esa persona.';
  end if;
  if v_ref.invitado_por is distinct from v_yo or v_ref.referido_estado <> 'activo' then
    if v_ref.invitado_por = v_yo and v_ref.referido_estado = 'reserva' then
      raise exception 'Esa persona está en tu lista de espera. Solo puedes eliminar a tus 2 referidos activos.';
    end if;
    raise exception 'Esa persona no es uno de tus 2 referidos activos.';
  end if;
  if exists (select 1 from public.posiciones where user_id = p_user_id and posicion not like 'regalador%') then
    raise exception 'No puedes eliminar a % porque ya es constructor o recibidor. Si necesitas ayuda, escribe a Soporte.', v_ref.nombre_usuario;
  end if;

  for r in
    select p.id, p.grupo_id, p.posicion, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = p_user_id
    order by n.orden
    for update of p
  loop
    perform public.liberar_posicion(r.id, 'retirada');
    if v_casilla is null then
      v_casilla := r.id;
    end if;
    v_rec := public.recibidor_de_grupo(r.grupo_id);
    if v_rec is not null and v_rec <> p_user_id then
      perform public.notificar(v_rec, 'Alguien salió de tu grupo',
        format('%s dejó la posición %s de tu grupo del nivel %s.', v_ref.nombre_usuario, public.nombre_posicion(r.posicion), r.nivel));
    end if;
  end loop;
  delete from public.lista_espera where user_id = p_user_id;

  update public.perfiles set referido_estado = 'eliminado', reserva_desde = null where id = p_user_id;
  perform public.notificar(p_user_id, 'Ya no eres referido activo',
    format('%s te quitó de sus 2 referidos. Puedes seguir participando: en Niveles toca "Entrar por derrame".',
           (select nombre_usuario from public.perfiles where id = v_yo)));

  perform public.abrir_lugar_libre(v_yo, v_casilla);
  return v_ref.nombre_usuario;
end;
$$;

-- "Elegir para este lugar"
create or replace function public.elegir_para_lugar(p_lugar_id bigint, p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo    uuid := (select auth.uid());
  v_lugar public.lugares_libres;
  v_per   public.perfiles;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  perform 1 from public.perfiles where id = v_yo for update;

  select * into v_per from public.perfiles where id = p_user_id;
  if not found or v_per.invitado_por is distinct from v_yo or v_per.referido_estado <> 'reserva' then
    raise exception 'Esa persona no está en tu lista de espera.';
  end if;

  select * into v_lugar from public.lugares_libres
  where patrocinador_id = v_yo and (p_lugar_id is null or id = p_lugar_id)
  order by liberado_en
  limit 1
  for update;
  if not found then
    raise exception 'No tienes un lugar libre. Solo se pueden usar lugares libres: nunca se saca a nadie para poner a otra persona.';
  end if;
  if public.contar_activos(v_yo) >= 2 then
    delete from public.lugares_libres where id = v_lugar.id;
    raise exception 'Ya tienes tus 2 referidos activos. No hay lugar libre.';
  end if;

  if public.promover_reserva(v_yo, v_lugar.casilla_id, p_user_id) is null then
    raise exception 'No se pudo poner a esa persona en el lugar libre. Recarga la página e inténtalo de nuevo.';
  end if;
  delete from public.lugares_libres where id = v_lugar.id;
  return v_per.nombre_usuario;
end;
$$;

-- "Ubicar debajo de…": mi red = mis referidos activos y los referidos activos de ellos,
-- con un lugar de referido libre y sin gente en su propia lista de espera
create or replace function public.candidatos_ubicar()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', red.id, 'nombre_usuario', red.nombre_usuario, 'nivel_red', red.nivel_red,
             'via', red.via, 'libres', 2 - public.contar_activos(red.id))
           order by red.nivel_red, red.nombre_usuario), '[]'::jsonb)
    from (
      select pe.id, pe.nombre_usuario, 1 as nivel_red, null::text as via
      from public.perfiles pe
      where pe.invitado_por = v_yo and pe.referido_estado = 'activo'
      union all
      select n2.id, n2.nombre_usuario, 2, n1.nombre_usuario
      from public.perfiles n1
      join public.perfiles n2 on n2.invitado_por = n1.id
      where n1.invitado_por = v_yo and n1.referido_estado = 'activo' and n2.referido_estado = 'activo'
    ) red
    where public.contar_activos(red.id) < 2
      and not exists (select 1 from public.perfiles r where r.invitado_por = red.id and r.referido_estado = 'reserva')
  );
end;
$$;

create or replace function public.ubicar_debajo_de(p_user_id uuid, p_destino uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo   uuid := (select auth.uid());
  v_per  public.perfiles;
  v_dest public.perfiles;
  v_ok   boolean;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  perform 1 from public.perfiles where id = v_yo for update;

  select * into v_per from public.perfiles where id = p_user_id for update;
  if not found or v_per.invitado_por is distinct from v_yo or v_per.referido_estado <> 'reserva' then
    raise exception 'Esa persona no está en tu lista de espera.';
  end if;

  select * into v_dest from public.perfiles where id = p_destino for update;
  if not found or p_destino = p_user_id or p_destino = v_yo then
    raise exception 'Elige a otra persona de tu red.';
  end if;

  -- Solo mi red (coalesce: sin patrocinador NO es de mi red)
  v_ok := coalesce(v_dest.referido_estado = 'activo' and (
            v_dest.invitado_por is not distinct from v_yo
            or exists (select 1 from public.perfiles n1
                       where n1.id = v_dest.invitado_por and n1.invitado_por = v_yo and n1.referido_estado = 'activo')), false);
  if not v_ok then
    raise exception 'Solo puedes ubicarla debajo de alguien de tu red (tus referidos o los referidos de ellos).';
  end if;

  if public.contar_activos(p_destino) >= 2
     or exists (select 1 from public.perfiles r where r.invitado_por = p_destino and r.referido_estado = 'reserva') then
    raise exception '% no tiene un lugar de referido libre. Solo se pueden usar lugares libres.', v_dest.nombre_usuario;
  end if;

  update public.perfiles set invitado_por = p_destino where id = p_user_id;
  if (select referido_estado from public.perfiles where id = p_user_id) <> 'activo' then
    raise exception '% no tiene un lugar de referido libre. Solo se pueden usar lugares libres.', v_dest.nombre_usuario;
  end if;

  perform public.notificar(p_user_id, 'Tienes un nuevo patrocinador',
    format('%s te ubicó debajo de %s: ahora eres su referido y lo seguirás. Ve a Niveles y toca Participar para entrar en su grupo.',
           (select nombre_usuario from public.perfiles where id = v_yo), v_dest.nombre_usuario));
  perform public.notificar(p_destino, 'Tienes un nuevo referido',
    format('%s ubicó a %s en uno de tus lugares libres: ahora es tu referido y te seguirá.',
           (select nombre_usuario from public.perfiles where id = v_yo), v_per.nombre_usuario));
  return v_dest.nombre_usuario;
end;
$$;

-- Si estoy en la lista de espera de mi patrocinador: "Eres el N en espera"
create or replace function public.mi_reserva()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
  v_p  public.perfiles;
  v_n  integer;
begin
  select * into v_p from public.perfiles where id = v_yo;
  if not found or v_p.invitado_por is null or v_p.referido_estado not in ('reserva', 'eliminado') then
    return jsonb_build_object('estado', coalesce(v_p.referido_estado, 'activo'));
  end if;
  if v_p.referido_estado = 'reserva' then
    select count(*) + 1 into v_n
    from public.perfiles pe
    where pe.invitado_por = v_p.invitado_por and pe.referido_estado = 'reserva'
      and (coalesce(pe.reserva_desde, pe.creado_en), pe.id) < (coalesce(v_p.reserva_desde, v_p.creado_en), v_p.id);
  end if;
  return jsonb_build_object(
    'estado',       v_p.referido_estado,
    'numero',       v_n,
    'patrocinador', (select nombre_usuario from public.perfiles where id = v_p.invitado_por),
    'desde',        coalesce(v_p.reserva_desde, v_p.creado_en),
    'plazo_tarea',  public.texto_duracion(public.intervalo_config('horas_tarea')),
    'plazo_elegir', public.texto_duracion(public.intervalo_config('horas_elegir_reserva'))
  );
end;
$$;

-- Mis referidos: los activos, los lugares libres por elegir y la lista de espera en orden
create or replace function public.mis_referidos_detalle()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
begin
  if not exists (select 1 from public.perfiles where id = v_yo) then
    raise exception 'No se encontró tu perfil.';
  end if;
  return jsonb_build_object(
    'activos', (
      select coalesce(jsonb_agg(jsonb_build_object('user_id', pe.id, 'nombre_usuario', pe.nombre_usuario, 'desde', pe.creado_en,
               'posicion', (select jsonb_build_object('posicion', p.posicion, 'nivel', n.nombre)
                            from public.posiciones p join public.niveles n on n.id = p.nivel_id
                            where p.user_id = pe.id order by n.orden desc limit 1))
             order by pe.creado_en, pe.id), '[]'::jsonb)
      from public.perfiles pe
      where pe.invitado_por = v_yo and pe.referido_estado = 'activo'
    ),
    'lugares', (
      select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'liberado_en', l.liberado_en,
               'vence_en', l.liberado_en + public.intervalo_config('horas_elegir_reserva')) order by l.liberado_en), '[]'::jsonb)
      from public.lugares_libres l where l.patrocinador_id = v_yo
    ),
    'espera', (
      select coalesce(jsonb_agg(jsonb_build_object('user_id', pe.id, 'nombre_usuario', pe.nombre_usuario,
               'registrado', pe.creado_en, 'desde', coalesce(pe.reserva_desde, pe.creado_en))
             order by coalesce(pe.reserva_desde, pe.creado_en), pe.id), '[]'::jsonb)
      from public.perfiles pe
      where pe.invitado_por = v_yo and pe.referido_estado = 'reserva'
    )
  );
end;
$$;

-- =====================================================================
-- 11. SALIR DE LA RED (abre el lugar para la reserva del patrocinador)
-- =====================================================================
create or replace function public.borrar_cuenta_participante(p_user_id uuid, p_por_admin boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_perfil  public.perfiles;
  r         record;
  v_rec     uuid;
  v_cuantas int := 0;
  v_pat     uuid;
  v_casilla uuid;
begin
  if exists (select 1 from public.administradores a where a.user_id = p_user_id) then
    raise exception '%', case when p_por_admin
      then 'No se puede eliminar la cuenta de un administrador desde aquí.'
      else 'Un administrador no puede eliminar su cuenta desde aquí.' end;
  end if;

  select * into v_perfil from public.perfiles where id = p_user_id for update;
  if not found then
    raise exception '%', case when p_por_admin then 'No se encontró ese usuario.' else 'No se encontró tu perfil.' end;
  end if;

  if exists (
    select 1
    from public.posiciones yo
    join public.grupos g on g.id = yo.grupo_id and g.estado = 'activo'
    where yo.user_id = p_user_id and yo.posicion = 'recibidor'
      and exists (select 1 from public.posiciones o
                  where o.grupo_id = yo.grupo_id and o.user_id is not null and o.user_id <> p_user_id)
  ) then
    raise exception '%', case when p_por_admin
      then format('%s es el recibidor de un grupo activo con personas. Primero reemplázalo en la pestaña Grupos.', v_perfil.nombre_usuario)
      else 'Eres el recibidor de un grupo activo. Pide ayuda al administrador.' end;
  end if;

  if v_perfil.invitado_por is not null and v_perfil.referido_estado = 'activo' then
    v_pat := v_perfil.invitado_por;
  end if;

  for r in
    select p.id, p.grupo_id, p.posicion, p.nivel_id, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = p_user_id
    order by n.orden
    for update of p
  loop
    perform public.liberar_posicion(r.id, 'retirada');
    if v_casilla is null then
      v_casilla := r.id;
    end if;
    perform public.avisar_patrocinador(p_user_id, r.posicion, r.nivel_id, 'se retiró. Tienes un lugar disponible.');
    v_rec := public.recibidor_de_grupo(r.grupo_id);
    if v_rec is not null and v_rec <> p_user_id then
      perform public.notificar(v_rec, 'Alguien salió de tu grupo',
        format('%s salió de la plataforma y dejó libre la posición %s (%s) de tu grupo del nivel %s.',
               v_perfil.nombre_usuario, public.nombre_posicion(r.posicion), public.lado_posicion(r.posicion), r.nivel));
    end if;
    perform public.avisar_lista_espera(r.nivel_id);
    v_cuantas := v_cuantas + 1;
  end loop;

  if v_cuantas = 0 and v_pat is not null then
    perform public.notificar(v_pat, 'Tu socio se retiró',
      format('Tu socio %s se retiró de la plataforma. Se liberó uno de tus 2 lugares.', v_perfil.nombre_usuario));
  end if;

  delete from auth.users where id = p_user_id;

  -- En el lugar que dejó puede entrar alguien de la lista de espera de su patrocinador
  perform public.abrir_lugar_libre(v_pat, v_casilla);
  return v_perfil.nombre_usuario;
end;
$$;

-- =====================================================================
-- 12. PARTICIPAR (sin vueltas)
-- =====================================================================
create or replace function public.participar_usuario(p_user_id uuid, p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo        uuid := p_user_id;
  v_nivel     public.niveles;
  v_perfil    public.perfiles;
  v_pos_inv   public.posiciones;
  v_libre     public.posiciones;
  v_grupo     uuid;
  v_recibidor uuid;
  v_primero   boolean;
  v_derrame   boolean := false;
  v_cand      record;
  v_sin_pat   boolean;
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

  -- En espera o eliminado: no sigue a su patrocinador; entra por derrame
  v_sin_pat := v_perfil.invitado_por is not null and v_perfil.referido_estado in ('reserva', 'eliminado');
  v_primero := public.nivel_anterior(p_nivel_id) is null;

  if exists (select 1 from public.posiciones where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya tienes una posición en este nivel.';
  end if;
  if exists (select 1 from public.lista_espera where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya estás en la lista de espera de este nivel.';
  end if;
  if exists (select 1 from public.ciclos_completados where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya completaste este nivel. Para volver a entrar usa "Repetir con mi equipo" en Niveles.';
  end if;
  if not public.nivel_habilitado(v_yo, p_nivel_id) then
    raise exception 'Este nivel todavía no está habilitado para ti. Primero completa el nivel anterior.';
  end if;

  if not v_primero and v_perfil.es_fundador then
    -- Fundador: crea su propio grupo como recibidor
    v_grupo := public.crear_grupo_vacio(p_nivel_id);
    select * into v_libre from public.posiciones where grupo_id = v_grupo and posicion = 'recibidor';
  else
    if not v_sin_pat and v_perfil.invitado_por is not null then
      select po.* into v_pos_inv
      from public.posiciones po
      join public.grupos g on g.id = po.grupo_id and g.estado = 'activo'
      where po.user_id = v_perfil.invitado_por and po.nivel_id = p_nivel_id
      limit 1;

      if v_pos_inv.id is not null then
        if v_primero then
          -- Solo regaladores: primero debajo del invitador (si es constructor); si no, el primero
          -- libre de su grupo que no guarde otro constructor para sus referidos
          select p.* into v_libre
          from public.posiciones p
          where p.grupo_id = v_pos_inv.grupo_id
            and p.user_id is null
            and p.posicion like 'regalador%'
            and (p.cuelga_de = v_pos_inv.posicion or not public.lugar_guardado(p.grupo_id, p.cuelga_de))
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

    -- Derrame en el nivel 1 (21): 0 = constructor con plazo vencido; 1 = constructor que no
    -- espera referidos; 2 = al final, los lugares que un constructor guarda para sus referidos.
    -- Lista sin bloquear y después bloqueo de UNA casilla con FOR UPDATE SKIP LOCKED.
    if v_libre.id is null and v_primero then
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
  end if;

  if v_libre.id is null then
    insert into public.lista_espera (user_id, nivel_id) values (v_yo, p_nivel_id);
    perform public.notificar(v_yo, 'Estás en lista de espera',
      format('No hay un lugar libre para ti en el nivel %s. El administrador te asignará un lugar.', v_nivel.nombre));
    perform public.notificar_admins('Nueva persona en lista de espera',
      format('%s tocó Participar en el nivel %s y quedó en lista de espera.', v_perfil.nombre_usuario, v_nivel.nombre));
    return jsonb_build_object('resultado', 'lista_espera', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre);
  end if;

  perform public.ocupar_posicion(v_libre.id, v_yo, true);

  if v_sin_pat then
    update public.perfiles set referido_estado = 'derrame', reserva_desde = null where id = v_yo;
    if v_perfil.referido_estado = 'reserva' then
      perform public.notificar(v_perfil.invitado_por, 'Una persona dejó tu lista de espera',
        format('%s entró por derrame y ya no está en tu lista de espera.', v_perfil.nombre_usuario));
    end if;
  end if;

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
                            'grupo_id', v_libre.grupo_id, 'posicion', v_libre.posicion, 'derrame', v_derrame);
end;
$$;

create or replace function public.participar(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  return public.participar_usuario(v_yo, p_nivel_id);
end;
$$;

-- =====================================================================
-- 13. PLAZOS (tarea vencida -> reserva del patrocinador; lugares libres sin elegir en 24 h)
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
  v_retirados int := 0;
  v_avisos    int := 0;
  v_vencidos  int := 0;
  v_lugares   int := 0;
  v_entro     uuid;
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
      format('Pasaron %s sin que marcaras tu tarea como hecha y saliste de la posición %s del nivel %s.',
             public.texto_duracion(v_tarea), public.nombre_posicion(r.posicion), r.nivel));
    perform public.avisar_patrocinador(r.user_id, r.posicion, r.nivel_id,
      'salió de su posición porque se acabó su tiempo para hacer la tarea. Tienes un lugar disponible.');
    -- Si su patrocinador tiene gente en espera, elige quién toma esta casilla (24 h)
    perform public.reserva_tras_vencer(r.user_id, r.id);
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

  -- (c) Constructor con reloj: menos de 2 referidos con posición al vencer los días
  for r in
    select p.id, p.user_id, p.nivel_id, n.nombre as nivel, pe.nombre_usuario, pe.invitado_por
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    join public.perfiles pe on pe.id = p.user_id
    where p.posicion like 'constructor%'
      and p.ascendido_en is not null
      and p.estado is null
      and p.ascendido_en + public.dias_invitar_de(p.nivel_id) <= now()
      and public.contar_invitados(p.user_id, p.nivel_id) < 2
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

  -- (d) Lugar libre sin elegir en horas_elegir_reserva: entra automáticamente el 1.º en espera
  for r in
    select l.id, l.patrocinador_id, l.casilla_id
    from public.lugares_libres l
    where l.liberado_en + public.intervalo_config('horas_elegir_reserva') <= now()
    order by l.liberado_en
    for update of l skip locked
  loop
    v_entro := public.promover_reserva(r.patrocinador_id, r.casilla_id, null);
    delete from public.lugares_libres where id = r.id;
    if v_entro is not null then
      perform public.notificar(r.patrocinador_id, 'Entró automáticamente el 1.º en espera',
        format('No elegiste a tiempo quién tomaba tu lugar libre, así que entró automáticamente %s, el 1.º de tu lista de espera.',
               (select nombre_usuario from public.perfiles where id = v_entro)));
      v_lugares := v_lugares + 1;
    end if;
  end loop;

  return jsonb_build_object('retirados', v_retirados, 'avisos', v_avisos, 'plazos_vencidos', v_vencidos,
                            'reservas_automaticas', v_lugares);
end;
$$;

-- =====================================================================
-- 14. REPETIR UN NIVEL CON MI EQUIPO
-- =====================================================================
-- Mi equipo de siempre: mis 2 primeros referidos activos (constructores) y los 2 primeros
-- referidos activos de cada uno (regaladores 1-2 debajo del constructor 1; 3-4 del constructor 2)
create or replace function public.equipo_de(p_user_id uuid)
returns table (posicion text, user_id uuid, patrocinador uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with c as (
    select pe.id, row_number() over (order by pe.creado_en, pe.id) as n
    from public.perfiles pe
    where pe.invitado_por = p_user_id and pe.referido_estado = 'activo'
  ), c2 as (
    select id, n from c where n <= 2
  ), r as (
    select c2.n as cn, c2.id as cid, pe.id,
           row_number() over (partition by c2.n order by pe.creado_en, pe.id) as rn
    from c2 join public.perfiles pe on pe.invitado_por = c2.id and pe.referido_estado = 'activo'
  )
  select 'constructor_' || n, id, p_user_id from c2
  union all
  select 'regalador_' || ((cn - 1) * 2 + rn), id, cid from r where rn <= 2;
$$;

-- Pone a una persona del equipo en su casilla del grupo repetido (los regaladores con su plazo)
create or replace function public.colocar_en_repetido(p_grupo_id uuid, p_posicion text, p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.posiciones
     set user_id        = p_user_id,
         asignado_en    = now(),
         origen         = 'automatico',
         estado         = case when posicion like 'regalador%' then 'reservada' end,
         reservada_en   = case when posicion like 'regalador%' then now() end,
         ascendido_en   = null,
         tarea_hecha_en = null,
         aviso_enviado  = false
   where grupo_id = p_grupo_id and posicion = p_posicion;

  delete from public.lista_espera
   where user_id = p_user_id and nivel_id = (select nivel_id from public.grupos where id = p_grupo_id);
$$;

-- Para el botón: mi equipo y quién ya tiene posición en ese nivel
create or replace function public.mi_equipo(p_nivel_id integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'posicion', s.posicion,
             'user_id', e.user_id,
             'nombre_usuario', pe.nombre_usuario,
             'ocupado', exists (select 1 from public.posiciones x where x.user_id = e.user_id and x.nivel_id = p_nivel_id))
           order by array_position(array['constructor_1', 'constructor_2', 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], s.posicion)), '[]'::jsonb)
    from unnest(array['constructor_1', 'constructor_2', 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4']) as s(posicion)
    left join public.equipo_de(v_yo) e on e.posicion = s.posicion
    left join public.perfiles pe on pe.id = e.user_id
  );
end;
$$;

-- Qué niveles puedo repetir: los de orden menor al más alto que alcancé, sin posición mía
create or replace function public.niveles_para_repetir()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo   uuid := (select auth.uid());
  v_max  integer;
  v_ult  timestamptz;
  v_hasta timestamptz;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select max(n.orden) into v_max
  from public.niveles n
  where exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id)
     or exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id);
  select max(creado_en) into v_ult from public.grupos where repetido_por = v_yo;
  v_hasta := v_ult + public.intervalo_config('horas_espera_repetir');
  return jsonb_build_object(
    'max_orden', v_max,
    'espera_hasta', case when v_hasta > now() then v_hasta end,
    'niveles', (
      select coalesce(jsonb_agg(n.id order by n.orden), '[]'::jsonb)
      from public.niveles n
      where n.orden < coalesce(v_max, 0)
        and not exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id)
    )
  );
end;
$$;

create or replace function public.repetir_nivel(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := (select auth.uid());
  v_nivel   public.niveles;
  v_perfil  public.perfiles;
  v_eq      jsonb;
  v_ids     uuid[];
  v_max     integer;
  v_ult     timestamptz;
  v_g       uuid;
  v_seat    text;
  v_user    uuid;
  v_pat     uuid;
  v_casilla uuid;
  v_col     jsonb := '[]'::jsonb;
  v_vac     jsonb := '[]'::jsonb;
  v_motivo  text;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_nivel from public.niveles where id = p_nivel_id;
  if not found then
    raise exception 'El nivel elegido no existe.';
  end if;

  -- Mi equipo y bloqueo de los perfiles (yo + equipo) SIEMPRE en el mismo orden: así dos
  -- personas del mismo equipo que repiten a la vez no se bloquean entre sí
  select coalesce(jsonb_object_agg(e.posicion, jsonb_build_object('user_id', e.user_id, 'pat', e.patrocinador)), '{}'::jsonb),
         coalesce(array_agg(e.user_id), '{}')
    into v_eq, v_ids
  from public.equipo_de(v_yo) e;
  perform 1 from public.perfiles where id = any(v_ids || v_yo) order by id for update;
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

  select max(creado_en) into v_ult from public.grupos where repetido_por = v_yo;
  if v_ult + public.intervalo_config('horas_espera_repetir') > now() then
    raise exception 'Debes esperar % para volver a repetir un nivel.',
      public.texto_duracion(v_ult + public.intervalo_config('horas_espera_repetir') - now());
  end if;

  -- Grupo nuevo: yo al centro
  v_g := public.crear_grupo_vacio(p_nivel_id);
  update public.grupos set tipo = 'repetido', repetido_por = v_yo where id = v_g;
  perform public.colocar_en_repetido(v_g, 'recibidor', v_yo);

  foreach v_seat in array array['constructor_1', 'constructor_2', 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'] loop
    v_user := (v_eq -> v_seat ->> 'user_id')::uuid;
    -- Patrocinador de ese asiento: yo para los constructores; el constructor de esa pierna para sus regaladores
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
      -- Asiento vacío: lo puede llenar la reserva de su patrocinador; si nadie, queda para el derrame
      perform public.abrir_lugar_libre(v_pat, v_casilla);
    end if;
  end loop;

  perform public.notificar(v_yo, 'Repetiste el nivel ' || v_nivel.nombre,
    format('Armaste otra vez tu grupo del nivel %s: tú estás al centro. Entraron %s de tu equipo%s.',
           v_nivel.nombre, jsonb_array_length(v_col),
           case when jsonb_array_length(v_vac) > 0
                then format(' y quedaron %s lugares libres (los puede tomar la lista de espera de su patrocinador o el derrame)', jsonb_array_length(v_vac))
                else '' end));

  return jsonb_build_object('grupo_id', v_g, 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                            'colocados', v_col, 'vacios', v_vac);
end;
$$;

-- =====================================================================
-- 15. PERMISOS
-- =====================================================================
revoke execute on function public.contar_activos(uuid)                          from public, anon, authenticated;
revoke execute on function public.contar_referidos(uuid)                        from public, anon, authenticated;
revoke execute on function public.contar_invitados(uuid, integer)               from public, anon, authenticated;
revoke execute on function public.lugar_guardado(uuid, text)                    from public, anon, authenticated;
revoke execute on function public.limitar_referidos()                           from public, anon, authenticated;
revoke execute on function public.ocupar_posicion(uuid, uuid, boolean)          from public, anon, authenticated;
revoke execute on function public.liberar_posicion(uuid, text)                  from public, anon, authenticated;
revoke execute on function public.validar_asignacion(uuid, uuid)                from public, anon, authenticated;
revoke execute on function public.colocar_ascendido(uuid, text, uuid)           from public, anon, authenticated;
revoke execute on function public.ascender_grupo(uuid)                          from public, anon, authenticated;
revoke execute on function public.promover_reserva(uuid, uuid, uuid)            from public, anon, authenticated;
revoke execute on function public.abrir_lugar_libre(uuid, uuid)                 from public, anon, authenticated;
revoke execute on function public.reserva_tras_vencer(uuid, uuid)               from public, anon, authenticated;
revoke execute on function public.borrar_cuenta_participante(uuid, boolean)     from public, anon, authenticated;
revoke execute on function public.participar_usuario(uuid, integer)             from public, anon, authenticated;
revoke execute on function public.revisar_plazos()                              from public, anon, authenticated;
revoke execute on function public.equipo_de(uuid)                               from public, anon, authenticated;
revoke execute on function public.colocar_en_repetido(uuid, text, uuid)         from public, anon, authenticated;

revoke execute on function public.participar(integer)                           from public, anon;
revoke execute on function public.mi_reloj(integer)                             from public, anon;
revoke execute on function public.mi_grupo_resumen(integer)                     from public, anon;
revoke execute on function public.mi_resumen_perfil()                           from public, anon;
revoke execute on function public.retirar_y_reemplazar(uuid, uuid)              from public, anon;
revoke execute on function public.eliminar_referido(uuid)                       from public, anon;
revoke execute on function public.elegir_para_lugar(bigint, uuid)               from public, anon;
revoke execute on function public.candidatos_ubicar()                           from public, anon;
revoke execute on function public.ubicar_debajo_de(uuid, uuid)                  from public, anon;
revoke execute on function public.mi_reserva()                                  from public, anon;
revoke execute on function public.mis_referidos_detalle()                       from public, anon;
revoke execute on function public.mi_equipo(integer)                            from public, anon;
revoke execute on function public.niveles_para_repetir()                        from public, anon;
revoke execute on function public.repetir_nivel(integer)                        from public, anon;
grant  execute on function public.participar(integer)                           to authenticated;
grant  execute on function public.mi_reloj(integer)                             to authenticated;
grant  execute on function public.mi_grupo_resumen(integer)                     to authenticated;
grant  execute on function public.mi_resumen_perfil()                           to authenticated;
grant  execute on function public.retirar_y_reemplazar(uuid, uuid)              to authenticated;
grant  execute on function public.eliminar_referido(uuid)                       to authenticated;
grant  execute on function public.elegir_para_lugar(bigint, uuid)               to authenticated;
grant  execute on function public.candidatos_ubicar()                           to authenticated;
grant  execute on function public.ubicar_debajo_de(uuid, uuid)                  to authenticated;
grant  execute on function public.mi_reserva()                                  to authenticated;
grant  execute on function public.mis_referidos_detalle()                       to authenticated;
grant  execute on function public.mi_equipo(integer)                            to authenticated;
grant  execute on function public.niveles_para_repetir()                        to authenticated;
grant  execute on function public.repetir_nivel(integer)                        to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- 16. RESULTADO: casos de la migración para revisar y comprobaciones
-- =====================================================================
select tipo, nombre_usuario, detalle, creado_en
from public.revision_migracion_25
order by id;
