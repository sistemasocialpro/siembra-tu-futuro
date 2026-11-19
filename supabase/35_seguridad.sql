-- =====================================================================
-- 35_seguridad.sql — Revisión de seguridad (va DESPUÉS de 34)
-- Se puede ejecutar las veces que quieras.
--
-- 1) Corrige: desde la fase 1 (01_perfiles.sql) un socio podía cambiar
--    su propio nombre de usuario escribiendo directo en la tabla perfiles,
--    saltándose la regla "Para cambiar tu usuario escribe a Soporte".
--    Ninguna pantalla lo usa: se quita el permiso y la política.
--    (El admin lo sigue cambiando con admin_editar_usuario, que queda
--    en el Registro de cambios.)
-- 2) Al final muestra un INFORME de tu base real. Si todo está bien,
--    sale una sola fila: "Todo bien".
-- =====================================================================

revoke update on table public.perfiles from anon, authenticated;
revoke update (nombre_usuario) on table public.perfiles from anon, authenticated;
drop policy if exists "perfiles: actualizar el propio" on public.perfiles;

-- ---------------------------------------------------------------------
-- INFORME (solo lectura)
-- ---------------------------------------------------------------------
with
tablas_sin_rls as (
  select 'Tabla SIN RLS' as problema, n.nspname || '.' || c.relname as objeto
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.relkind in ('r', 'p') and n.nspname = 'public' and not c.relrowsecurity
),
escritura_directa as (
  select 'Escritura directa permitida (' || g.grantee || ': ' || g.privilege_type || ')', g.table_schema || '.' || g.table_name
    from information_schema.role_table_grants g
   where g.table_schema = 'public' and g.grantee in ('anon', 'authenticated', 'PUBLIC')
     and g.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
),
columnas_editables as (
  select 'Columna editable directo (' || cp.grantee || ')', cp.table_name || '.' || cp.column_name
    from information_schema.column_privileges cp
   where cp.table_schema = 'public' and cp.grantee in ('anon', 'authenticated') and cp.privilege_type = 'UPDATE'
     and not (cp.table_name = 'notificaciones' and cp.column_name = 'leida')
     and not (cp.table_name = 'configuracion' and cp.column_name in ('valor', 'actualizado_en'))  -- su RLS: solo admin
),
vistas_abiertas as (
  select 'Vista que salta el RLS', c.relname::text
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('v', 'm')
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select'))
     and coalesce(array_to_string(c.reloptions, ','), '') !~ 'security_invoker=(true|on)'
),
admin_sin_control as (
  select 'Función de admin que NO llama a es_admin()', p.oid::regprocedure::text
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%'
     and position('es_admin(' in p.prosrc) = 0
),
admin_para_anon as (
  select 'Función de admin que puede ejecutar alguien sin sesión', p.oid::regprocedure::text
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%'
     and has_function_privilege('anon', p.oid, 'execute')
),
definer_sin_path as (
  select 'Función security definer sin search_path fijo', p.oid::regprocedure::text
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')
),
internas_expuestas as (
  select 'Función interna expuesta', p.oid::regprocedure::text
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('revisar_plazos', 'limpiar_notificaciones', 'notificacion_pendiente', 'ascender_grupo',
                       'ocupar_posicion', 'liberar_posicion', 'registrar_admin', 'crear_grupo_vacio',
                       'avisar_patrocinador', 'contar_referidos', 'intervalo_config')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
),
todo as (
  select * from tablas_sin_rls union all select * from escritura_directa union all select * from columnas_editables
  union all select * from vistas_abiertas union all select * from admin_sin_control union all select * from admin_para_anon
  union all select * from definer_sin_path union all select * from internas_expuestas
)
select problema, objeto from todo
union all
select 'Todo bien', (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p'))
                    || ' tablas con RLS; '
                    || (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%')
                    || ' funciones de admin verifican al administrador'
 where not exists (select 1 from todo)
order by 1, 2;
