-- =====================================================================
-- 34_mantenimiento.sql  (va DESPUÉS de 33_claves_admin.sql)
-- Para que el sistema no se vuelva pesado:
--   1) Limpieza diaria (pg_cron, 03:30 de Ecuador): borra las notificaciones de más de 30 días de cada
--      persona (configuracion.dias_borrar_notificaciones, editable en Administración → Configuración),
--      EXCEPTO los avisos que todavía piden una acción (por ejemplo "¡X volvió a sembrar!" sin aceptar,
--      "Tarea por aprobar" o "Llena el lugar de constructor"): esos se borran cuando la acción ya no
--      está pendiente. Cada limpieza queda en mantenimiento_log.
--      NUNCA se borran historial, tableros, posiciones, tareas, grupos ni el Registro de cambios:
--      la limpieza solo toca la tabla notificaciones.
--   2) admin_salud_sistema(): tamaño de la base, filas de las tablas más grandes, último mantenimiento
--      y aviso al pasar el 70% del límite del plan (configuracion.limite_bd_mb, 500 MB = plan gratis).
--   3) Índices para las consultas que crecen: contador de notificaciones sin leer, limpieza por fecha,
--      grupos por nivel paginados e historial por grupo.
-- Se puede volver a ejecutar sin problema (también si ya ejecutaste la versión anterior del 34).
-- =====================================================================

-- =====================================================================
-- 1. CONFIGURACIÓN (no pisa lo que el administrador haya cambiado)
-- =====================================================================
insert into public.configuracion (clave, valor, descripcion) values
  ('dias_borrar_notificaciones', 30, 'Días que se guardan las notificaciones antes de la limpieza diaria (salvo avisos que todavía piden una acción)'),
  ('limite_bd_mb', 500, 'Límite de tamaño de la base de datos del plan de Supabase, en MB (plan gratis: 500)')
on conflict (clave) do nothing;
-- Claves de la versión anterior del 34 (90 días leídas / 180 sin leer): ya no se usan
delete from public.configuracion where clave in ('dias_notif_leidas', 'dias_notif_no_leidas');

create table if not exists public.mantenimiento_log (
  id                 bigint generated always as identity primary key,
  ejecutado_en       timestamptz not null default now(),
  origen             text not null default 'automatica',
  borradas           integer not null default 0,
  conservadas        integer not null default 0
);
-- Si existía la tabla de la versión anterior del 34, se agregan las columnas nuevas
alter table public.mantenimiento_log add column if not exists borradas integer not null default 0;
alter table public.mantenimiento_log add column if not exists conservadas integer not null default 0;
alter table public.mantenimiento_log drop column if exists borradas_leidas;
alter table public.mantenimiento_log drop column if exists borradas_no_leidas;
alter table public.mantenimiento_log enable row level security;
revoke all on public.mantenimiento_log from anon, authenticated;

-- =====================================================================
-- 2. ÍNDICES
-- =====================================================================
-- Contador de notificaciones sin leer (se pide en cada página)
create index if not exists notificaciones_no_leidas_idx on public.notificaciones (user_id) where not leida;
-- Limpieza diaria por fecha
create index if not exists notificaciones_creada_idx on public.notificaciones (creada_en);
-- Administración → Grupos: grupos de un nivel por estado, de los más nuevos a los más viejos (paginado)
create index if not exists grupos_nivel_estado_fecha_idx on public.grupos (nivel_id, estado, creado_en desc);
-- Historial: tareas de un tablero
create index if not exists tareas_historial_grupo_idx on public.tareas_historial (grupo_id);
-- Tableros de un grupo (Historial, ficha del admin)
create index if not exists ciclos_completados_grupo_idx on public.ciclos_completados (grupo_id);

-- =====================================================================
-- 3. LIMPIEZA
-- =====================================================================
-- ¿Ese aviso todavía le pide a la persona que haga algo? Entonces no se borra.
create or replace function public.notificacion_pendiente(p_user_id uuid, p_titulo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    -- "¡X volvió a sembrar!" / "Tu patrocinador tiene un lugar para ti": falta aceptar seguirlo
    when p_titulo like '¡% volvió a sembrar!' or p_titulo = 'Tu patrocinador tiene un lugar para ti' then
      exists (select 1 from public.avisos_seguir a where a.user_id = p_user_id and a.estado in ('pendiente', 'oculto'))
    -- El patrocinador tiene que elegir quién de su espera toma el lugar libre
    when p_titulo = 'Tienes un lugar libre: elige quién lo toma' then
      exists (select 1 from public.lugares_libres l where l.patrocinador_id = p_user_id)
    -- Falta llenar un lugar de constructor (casilla liberada o grupo repetido del fundador)
    when p_titulo in ('Llena el lugar de constructor', 'Un grupo espera tu elección', 'Tu grupo no puede subir todavía') then
      exists (select 1 from public.casillas_liberadas l join public.posiciones p on p.id = l.posicion_id
              where l.patrocinador_id = p_user_id and p.user_id is null)
      or exists (select 1 from public.posiciones r
                 join public.grupos g on g.id = r.grupo_id and g.estado = 'activo'
                 join public.posiciones c on c.grupo_id = r.grupo_id and c.posicion like 'constructor%' and c.user_id is null
                 where r.user_id = p_user_id and r.posicion = 'recibidor')
    -- El recibidor tiene tareas hechas sin aprobar
    when p_titulo = 'Tarea por aprobar' then
      exists (select 1 from public.posiciones r
              join public.posiciones x on x.grupo_id = r.grupo_id and x.estado = 'tarea_hecha'
              where r.user_id = p_user_id and r.posicion = 'recibidor')
    -- Su invitado sigue con el plazo vencido (puede "Retirar y reemplazar")
    when p_titulo = 'Tu invitado tiene el plazo vencido' then
      exists (select 1 from public.posiciones p join public.perfiles pe on pe.id = p.user_id
              where pe.invitado_por = p_user_id and p.estado = 'plazo_vencido')
    -- Todavía no creó su clave nueva
    when p_titulo = 'Tienes una clave temporal' then
      coalesce((select pe.debe_cambiar_clave from public.perfiles pe where pe.id = p_user_id), false)
    else false
  end;
$$;

-- Borra SOLO notificaciones (nunca historial, tableros, posiciones, tareas, grupos ni el Registro)
create or replace function public.limpiar_notificaciones(p_origen text default 'automatica')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dias numeric := coalesce((select valor from public.configuracion where clave = 'dias_borrar_notificaciones'), 30);
  v_corte timestamptz := now() - make_interval(days => greatest(v_dias, 1)::int);
  v_borradas integer;
  v_conservadas integer;
begin
  -- Solo los títulos de avisos que pueden pedir una acción se revisan uno por uno; el resto se borra directo
  delete from public.notificaciones n
   where n.creada_en < v_corte
     and (not (n.titulo like '¡% volvió a sembrar!'
               or n.titulo in ('Tu patrocinador tiene un lugar para ti', 'Tienes un lugar libre: elige quién lo toma',
                               'Llena el lugar de constructor', 'Un grupo espera tu elección', 'Tu grupo no puede subir todavía',
                               'Tarea por aprobar', 'Tu invitado tiene el plazo vencido', 'Tienes una clave temporal'))
          or not public.notificacion_pendiente(n.user_id, n.titulo));
  get diagnostics v_borradas = row_count;
  select count(*) into v_conservadas from public.notificaciones n where n.creada_en < v_corte;
  insert into public.mantenimiento_log (origen, borradas, conservadas) values (p_origen, v_borradas, v_conservadas);
  -- El propio registro de limpiezas se guarda un año
  delete from public.mantenimiento_log where ejecutado_en < now() - interval '365 days';
  return jsonb_build_object('borradas', v_borradas, 'conservadas', v_conservadas, 'dias', v_dias);
end;
$$;

-- "Limpiar ahora" desde Administración
create or replace function public.admin_limpiar_ahora()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ejecutar la limpieza.';
  end if;
  v := public.limpiar_notificaciones('administrador');
  perform public.registrar_admin('Limpieza de notificaciones', null, 'Mantenimiento', null,
    format('%s borradas; %s avisos pendientes conservados', v ->> 'borradas', v ->> 'conservadas'));
  return v;
end;
$$;

-- Versión anterior (días leídas / sin leer / límite): se reemplaza por (días, límite)
drop function if exists public.admin_guardar_mantenimiento(numeric, numeric, numeric);
create or replace function public.admin_guardar_mantenimiento(p_dias numeric, p_limite_mb numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar el mantenimiento.';
  end if;
  if p_dias is null or p_dias < 7 or p_dias > 3650 then
    raise exception 'Los días para borrar notificaciones deben estar entre 7 y 3650.';
  end if;
  if p_limite_mb is null or p_limite_mb < 100 then
    raise exception 'El límite de la base debe ser de al menos 100 MB.';
  end if;
  -- El trigger del 30 deja cada cambio en el Registro
  update public.configuracion set valor = round(p_dias), actualizado_en = now() where clave = 'dias_borrar_notificaciones';
  update public.configuracion set valor = round(p_limite_mb), actualizado_en = now() where clave = 'limite_bd_mb';
end;
$$;

-- =====================================================================
-- 4. SALUD DEL SISTEMA
-- =====================================================================
create or replace function public.admin_salud_sistema()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bytes   bigint := pg_database_size(current_database());
  v_lim     numeric := coalesce((select valor from public.configuracion where clave = 'limite_bd_mb'), 500);
  v_cron    boolean := false;
  v_tablas  jsonb;
  v_grandes jsonb;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver la salud del sistema.';
  end if;
  if to_regclass('cron.job') is not null then
    execute 'select exists (select 1 from cron.job where jobname = ''siembra-limpieza-diaria'')' into v_cron;
  end if;

  -- Filas exactas de las tablas que más crecen
  select jsonb_agg(jsonb_build_object('tabla', t.tabla, 'nombre', t.nombre, 'filas', t.filas,
                                      'bytes', pg_total_relation_size(('public.' || t.tabla)::regclass)) order by t.orden)
    into v_tablas
  from (values
    (1, 'notificaciones',   'Notificaciones',        (select count(*) from public.notificaciones)),
    (2, 'posiciones',       'Posiciones (casillas)', (select count(*) from public.posiciones)),
    (3, 'tareas_historial', 'Historial de tareas',   (select count(*) from public.tareas_historial)),
    (4, 'admin_registro',   'Registro de cambios',   (select count(*) from public.admin_registro)),
    (5, 'grupos',           'Grupos',                (select count(*) from public.grupos)),
    (6, 'perfiles',         'Usuarios',              (select count(*) from public.perfiles))
  ) as t(orden, tabla, nombre, filas);

  -- Las 8 tablas que más ocupan (incluye respaldos *_respaldo_NN que se pueden borrar si ya no sirven)
  select jsonb_agg(jsonb_build_object('tabla', x.relname, 'filas_aprox', x.n_live_tup, 'bytes', x.bytes) order by x.bytes desc)
    into v_grandes
  from (
    select s.relname, s.n_live_tup, pg_total_relation_size(s.relid) as bytes
    from pg_catalog.pg_stat_user_tables s
    where s.schemaname = 'public'
    order by pg_total_relation_size(s.relid) desc
    limit 8
  ) x;

  return jsonb_build_object(
    'bytes', v_bytes,
    'limite_mb', v_lim,
    'porcentaje', round(v_bytes / (v_lim * 1024 * 1024) * 100, 1),
    'tablas', coalesce(v_tablas, '[]'::jsonb),
    'grandes', coalesce(v_grandes, '[]'::jsonb),
    'dias_borrar_notificaciones', (select valor from public.configuracion where clave = 'dias_borrar_notificaciones'),
    'limpieza_programada', v_cron,
    'ultima_limpieza', (select to_jsonb(l) - 'id' from public.mantenimiento_log l order by l.ejecutado_en desc limit 1)
  );
end;
$$;

-- =====================================================================
-- 5. PERMISOS
-- =====================================================================
revoke execute on function public.notificacion_pendiente(uuid, text)                from public, anon, authenticated;
revoke execute on function public.limpiar_notificaciones(text)                      from public, anon, authenticated;
revoke execute on function public.admin_limpiar_ahora()                             from public, anon;
revoke execute on function public.admin_guardar_mantenimiento(numeric, numeric)     from public, anon;
revoke execute on function public.admin_salud_sistema()                             from public, anon;
grant  execute on function public.admin_limpiar_ahora()                             to authenticated;
grant  execute on function public.admin_guardar_mantenimiento(numeric, numeric)     to authenticated;
grant  execute on function public.admin_salud_sistema()                             to authenticated;

-- =====================================================================
-- 6. PROGRAMAR LA LIMPIEZA DIARIA (pg_cron) — 08:30 UTC = 03:30 en Ecuador
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('siembra-limpieza-diaria', '30 8 * * *', 'select public.limpiar_notificaciones();');
    raise notice 'Tarea pg_cron "siembra-limpieza-diaria" programada todos los días a las 03:30 (Ecuador).';
  else
    raise notice 'pg_cron NO está activado. Actívalo (Database > Extensions > pg_cron) y vuelve a ejecutar este archivo.';
  end if;
end;
$$;
-- Para ver las tareas:   select jobname, schedule, command from cron.job;
-- Para quitarla:         select cron.unschedule('siembra-limpieza-diaria');

notify pgrst, 'reload schema';
