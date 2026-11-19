-- =====================================================================
-- 31_registro_socio.sql  (va DESPUÉS de 30_panel_soporte.sql)
-- "Editar mis datos" (Info personal): los cambios que hace el propio socio también quedan en el
-- Registro de cambios del administrador.
--   1) Nombre y apellido, WhatsApp, país y "WhatsApp visible" (actualizar_mi_perfil): trigger en perfiles.
--   2) Correo: trigger en auth.users. Queda registrado cuando el socio PIDE el cambio (Supabase
--      guarda el correo nuevo en email_change y manda el correo de confirmación) y cuando el
--      cambio se CONFIRMA (cambia email). Los cambios que hace el admin ya se registran en el 30.
--   El usuario (login) no se cambia desde Info personal: solo el admin desde el panel de soporte.
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

-- =====================================================================
-- 1. DATOS DEL PERFIL EDITADOS POR EL PROPIO SOCIO
-- =====================================================================
create or replace function public.reg_socio_perfiles()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.nombre_completo is distinct from old.nombre_completo then
    perform public.registrar_admin('Datos editados por el socio', new.id, 'Nombre y apellido', old.nombre_completo, new.nombre_completo);
  end if;
  if new.whatsapp is distinct from old.whatsapp then
    perform public.registrar_admin('Datos editados por el socio', new.id, 'WhatsApp', old.whatsapp, new.whatsapp);
  end if;
  if new.pais is distinct from old.pais then
    perform public.registrar_admin('Datos editados por el socio', new.id, 'País', old.pais, new.pais);
  end if;
  if new.acepta_whatsapp_visible is distinct from old.acepta_whatsapp_visible then
    perform public.registrar_admin('Datos editados por el socio', new.id, 'WhatsApp visible para su grupo',
      case when old.acepta_whatsapp_visible then 'Sí' else 'No' end, case when new.acepta_whatsapp_visible then 'Sí' else 'No' end);
  end if;
  return null;
end;
$$;

drop trigger if exists perfiles_reg_socio on public.perfiles;
create trigger perfiles_reg_socio
  after update of nombre_completo, whatsapp, pais, acepta_whatsapp_visible on public.perfiles
  for each row
  when (auth.uid() = new.id and not public.es_admin())
  execute function public.reg_socio_perfiles();

-- =====================================================================
-- 2. CORREO (auth.users): solicitud y confirmación
-- =====================================================================
-- Nunca debe impedir que Supabase cambie el correo: cualquier error se ignora.
create or replace function public.reg_auth_correo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text;
begin
  -- Los cambios hechos por el admin (admin_editar_usuario) ya quedan registrados en el 30
  if public.es_admin() then
    return null;
  end if;
  select nombre_usuario into v_nombre from public.perfiles where id = new.id;
  if v_nombre is null then
    return null;   -- administradores sin perfil
  end if;
  begin
    if new.email_change is distinct from old.email_change and coalesce(new.email_change, '') <> '' then
      insert into public.admin_registro (admin_id, admin_nombre, accion, usuario_id, usuario_nombre, detalle, valor_anterior, valor_nuevo)
      values (new.id, v_nombre, 'Cambio de correo solicitado', new.id, v_nombre,
              'Correo (pendiente de confirmar por correo)', old.email, new.email_change);
    end if;
    if new.email is distinct from old.email then
      insert into public.admin_registro (admin_id, admin_nombre, accion, usuario_id, usuario_nombre, detalle, valor_anterior, valor_nuevo)
      values (new.id, v_nombre, 'Correo cambiado', new.id, v_nombre, 'Correo (confirmado)', old.email, new.email);
    end if;
  exception when others then
    null;
  end;
  return null;
end;
$$;

drop trigger if exists auth_users_reg_correo on auth.users;
create trigger auth_users_reg_correo
  after update of email, email_change on auth.users
  for each row
  when (old.email is distinct from new.email or old.email_change is distinct from new.email_change)
  execute function public.reg_auth_correo();

-- =====================================================================
-- 3. PERMISOS
-- =====================================================================
revoke execute on function public.reg_socio_perfiles() from public, anon, authenticated;
revoke execute on function public.reg_auth_correo()    from public, anon, authenticated;

notify pgrst, 'reload schema';
