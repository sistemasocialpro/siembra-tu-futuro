-- =====================================================================
-- 34_mantenimiento.sql  (va DESPUÉS de 33_claves_admin.sql)
-- Para que el sistema no se vuelva pesado:
--   1) Limpieza diaria (pg_cron, 03:30 de Ecuador): borra notificaciones LEÍDAS de más de 90 días y
--      NO LEÍDAS de más de 180 días. Los días se editan en Configuración (configuracion:
--      dias_notif_leidas, dias_notif_no_leidas). Cada limpieza queda en mantenimiento_log.
--   2) admin_salud_sistema(): tamaño de la base, filas de las tablas más grandes, último mantenimiento
--      y aviso al pasar el 70% del límite del plan (configuracion.limite_bd_mb, 500 MB = plan gratis).
--   3) Índices para las consultas que crecen: contador de notificaciones sin leer, limpieza por fecha,
--      grupos por nivel paginados e historial por grupo.
--   El historial (tareas_historial, ciclos, tableros) y el Registro NO se borran: son la memoria del sistema.
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

-- =====================================================================
-- 1. CONFIGURACIÓN (no pisa lo que el administrador haya cambiado)
-- =====================================================================
insert into public.configuracion (clave, valor, descripcion) values
  ('dias_notif_leidas', 90, 'Días que se guardan las notificaciones leídas antes de la limpieza diaria'),
  ('dias_notif_no_leidas', 180, 'Días que se guardan las notificaciones sin leer antes de la limpieza diaria'),
  ('limite_bd_mb', 500, 'Límite de tamaño de la base de datos del plan de Supabase, en MB (plan gratis: 500)')
on conflict (clave) do nothing;

create table if not exists public.mantenimiento_log (
  id                 bigint generated always as identity primary key,
  ejecutado_en       timestamptz not null default now(),
  origen             text not null default 'automatica',
  borradas_leidas    integer not null default 0,
  borradas_no_leidas integer not null default 0
);
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
create or replace function public.limpiar_notificaciones(p_origen text default 'automatica')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dl  numeric := coalesce((select valor from public.configuracion where clave = 'dias_notif_leidas'), 90);
  v_dnl numeric := coalesce((select valor from public.configuracion where clave = 'dias_notif_no_leidas'), 180);
  v_l   integer;
  v_nl  integer;
begin
  delete from public.notificaciones where leida and creada_en < now() - make_interval(days => v_dl::int);
  get diagnostics v_l = row_count;
  delete from public.notificaciones where not leida and creada_en < now() - make_interval(days => v_dnl::int);
  get diagnostics v_nl = row_count;
  insert into public.mantenimiento_log (origen, borradas_leidas, borradas_no_leidas) values (p_origen, v_l, v_nl);
  -- El propio registro de limpiezas se guarda un año
  delete from public.mantenimiento_log where ejecutado_en < now() - interval '365 days';
  return jsonb_build_object('borradas_leidas', v_l, 'borradas_no_leidas', v_nl, 'dias_leidas', v_dl, 'dias_no_leidas', v_dnl);
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
    format('%s leídas y %s sin leer borradas', v ->> 'borradas_leidas', v ->> 'borradas_no_leidas'));
  return v;
end;
$$;

create or replace function public.admin_guardar_mantenimiento(p_dias_leidas numeric, p_dias_no_leidas numeric, p_limite_mb numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar el mantenimiento.';
  end if;
  if p_dias_leidas is null or p_dias_leidas < 7 or p_dias_leidas > 3650 then
    raise exception 'Los días para las notificaciones leídas deben estar entre 7 y 3650.';
  end if;
  if p_dias_no_leidas is null or p_dias_no_leidas < 7 or p_dias_no_leidas > 3650 then
    raise exception 'Los días para las notificaciones sin leer deben estar entre 7 y 3650.';
  end if;
  if p_limite_mb is null or p_limite_mb < 100 then
    raise exception 'El límite de la base debe ser de al menos 100 MB.';
  end if;
  -- El trigger del 30 deja cada cambio en el Registro
  update public.configuracion set valor = round(p_dias_leidas), actualizado_en = now() where clave = 'dias_notif_leidas';
  update public.configuracion set valor = round(p_dias_no_leidas), actualizado_en = now() where clave = 'dias_notif_no_leidas';
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
    'dias_notif_leidas', (select valor from public.configuracion where clave = 'dias_notif_leidas'),
    'dias_notif_no_leidas', (select valor from public.configuracion where clave = 'dias_notif_no_leidas'),
    'limpieza_programada', v_cron,
    'ultima_limpieza', (select to_jsonb(l) - 'id' from public.mantenimiento_log l order by l.ejecutado_en desc limit 1)
  );
end;
$$;

-- =====================================================================
-- 5. PERMISOS
-- =====================================================================
revoke execute on function public.limpiar_notificaciones(text)                              from public, anon, authenticated;
revoke execute on function public.admin_limpiar_ahora()                                     from public, anon;
revoke execute on function public.admin_guardar_mantenimiento(numeric, numeric, numeric)    from public, anon;
revoke execute on function public.admin_salud_sistema()                                     from public, anon;
grant  execute on function public.admin_limpiar_ahora()                                     to authenticated;
grant  execute on function public.admin_guardar_mantenimiento(numeric, numeric, numeric)    to authenticated;
grant  execute on function public.admin_salud_sistema()                                     to authenticated;

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
