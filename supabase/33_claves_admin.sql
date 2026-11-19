-- =====================================================================
-- 33_claves_admin.sql  (va DESPUÉS de 32_admin_usuarios.sql)
-- Apoyo en la base para la Edge Function "admin-claves" (supabase/functions/admin-claves):
--   1) "Cambiar clave" (clave temporal): la función genera la clave y la pone con la service_role
--      (solo en el servidor). La base marca perfiles.debe_cambiar_clave para que la persona cree su
--      propia clave al entrar, cierra sus sesiones, le avisa y lo deja en el Registro SIN la clave.
--   2) "Copiar enlace de recuperación": la función genera el enlace; la base lo deja en el Registro.
--   Las funciones del admin se llaman con la sesión del administrador (comprueban es_admin()).
--   3) debo_cambiar_clave() y clave_cambiada(): para el propio socio (pantalla "Crea tu clave nueva").
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

alter table public.perfiles add column if not exists debe_cambiar_clave boolean not null default false;

-- Valida que quien pide sea admin y que la persona exista y no sea administrador.
-- Devuelve lo que la Edge Function necesita (correo para el enlace) y lo que muestra la página.
create or replace function public.admin_preparar_clave(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pe public.perfiles;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar claves.';
  end if;
  select * into v_pe from public.perfiles where id = p_user_id;
  if not found then
    raise exception 'No se encontró ese usuario.';
  end if;
  if exists (select 1 from public.administradores a where a.user_id = p_user_id) then
    raise exception 'La clave de un administrador no se cambia desde aquí.';
  end if;
  return jsonb_build_object(
    'nombre_usuario', v_pe.nombre_usuario,
    'whatsapp', v_pe.whatsapp,
    'correo', (select email::text from auth.users where id = p_user_id)
  );
end;
$$;

-- Después de poner la clave temporal: obliga a cambiarla, cierra sesiones, avisa y registra
create or replace function public.admin_clave_temporal_lista(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar claves.';
  end if;
  update public.perfiles set debe_cambiar_clave = true where id = p_user_id;
  if not found then
    raise exception 'No se encontró ese usuario.';
  end if;
  begin
    delete from auth.sessions where user_id = p_user_id;
  exception when others then
    null;
  end;
  perform public.notificar(p_user_id, 'Tienes una clave temporal',
    'El administrador te dio una clave temporal. Al entrar te pediremos que crees tu propia clave nueva.');
  perform public.registrar_admin('Clave temporal generada', p_user_id, 'Contraseña', '(oculta)', '(temporal, oculta; debe cambiarla al entrar)');
end;
$$;

create or replace function public.admin_registrar_enlace_recuperacion(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede generar enlaces de recuperación.';
  end if;
  if not exists (select 1 from public.perfiles where id = p_user_id) then
    raise exception 'No se encontró ese usuario.';
  end if;
  perform public.registrar_admin('Enlace de recuperación generado', p_user_id, 'Enlace para crear una clave nueva', null, '(enlace, no se guarda)');
end;
$$;

-- El propio socio: ¿tiene que crear su clave nueva?
create or replace function public.debo_cambiar_clave()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select debe_cambiar_clave from public.perfiles where id = (select auth.uid())), false);
$$;

-- El propio socio ya creó su clave nueva (con la temporal o con un enlace de recuperación)
create or replace function public.clave_cambiada()
returns void
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
  update public.perfiles set debe_cambiar_clave = false where id = v_yo and debe_cambiar_clave;
  if found then
    perform public.registrar_admin('Clave nueva creada por el socio', v_yo, 'Contraseña', '(temporal)', '(propia, oculta)');
  end if;
end;
$$;

revoke execute on function public.admin_preparar_clave(uuid)                  from public, anon;
revoke execute on function public.admin_clave_temporal_lista(uuid)            from public, anon;
revoke execute on function public.admin_registrar_enlace_recuperacion(uuid)   from public, anon;
revoke execute on function public.debo_cambiar_clave()                        from public, anon;
revoke execute on function public.clave_cambiada()                            from public, anon;
grant  execute on function public.admin_preparar_clave(uuid)                  to authenticated;
grant  execute on function public.admin_clave_temporal_lista(uuid)            to authenticated;
grant  execute on function public.admin_registrar_enlace_recuperacion(uuid)   to authenticated;
grant  execute on function public.debo_cambiar_clave()                        to authenticated;
grant  execute on function public.clave_cambiada()                            to authenticated;

notify pgrst, 'reload schema';
