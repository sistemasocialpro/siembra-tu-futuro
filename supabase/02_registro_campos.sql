-- =====================================================================
-- Sistema Siembra tu Futuro — 02_registro_campos.sql
-- Ejecutar DESPUÉS de 01_perfiles.sql. Se puede volver a ejecutar sin problema.
-- Agrega nombre_completo, whatsapp y acepta_whatsapp_visible a public.perfiles
-- y actualiza el trigger de registro para llenarlas.
-- =====================================================================

-- ---------- Quitar el login por nombre de usuario ----------
-- (por si 01_perfiles.sql se ejecutó cuando todavía incluía esta función)
drop function if exists public.correo_para_login(text);

-- ---------- Columnas nuevas ----------
-- Son NULL-ables solo para no romper a los usuarios creados antes de este cambio;
-- el formulario de registro las exige siempre.
alter table public.perfiles add column if not exists nombre_completo text;
alter table public.perfiles add column if not exists whatsapp text;
alter table public.perfiles add column if not exists acepta_whatsapp_visible boolean not null default false;

comment on column public.perfiles.nombre_completo is 'Nombre y apellidos del usuario.';
comment on column public.perfiles.whatsapp is 'WhatsApp en formato internacional E.164, p. ej. +593999999999. Por ahora solo lo ve el propio usuario.';
comment on column public.perfiles.acepta_whatsapp_visible is 'Aceptó que su grupo vea su WhatsApp para coordinar las tareas.';

alter table public.perfiles drop constraint if exists perfiles_nombre_completo_chk;
alter table public.perfiles add constraint perfiles_nombre_completo_chk
  check (nombre_completo is null or char_length(nombre_completo) between 3 and 80);

alter table public.perfiles drop constraint if exists perfiles_whatsapp_chk;
alter table public.perfiles add constraint perfiles_whatsapp_chk
  check (whatsapp is null or whatsapp ~ '^\+[1-9][0-9]{7,14}$');

-- ---------- Trigger de registro actualizado ----------
-- Lee raw_user_meta_data: { nombre_usuario, nombre_completo, whatsapp,
--                           acepta_whatsapp_visible, codigo_ref }
create or replace function public.crear_perfil_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta      jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_usuario   text  := lower(trim(coalesce(v_meta ->> 'nombre_usuario', '')));
  v_nombre    text  := regexp_replace(trim(coalesce(v_meta ->> 'nombre_completo', '')), '\s+', ' ', 'g');
  v_whatsapp  text  := regexp_replace(coalesce(v_meta ->> 'whatsapp', ''), '[\s().-]', '', 'g');
  v_acepta    boolean := coalesce(v_meta ->> 'acepta_whatsapp_visible', '') = 'true';
  v_ref       text  := upper(trim(coalesce(v_meta ->> 'codigo_ref', '')));
  v_invitador uuid;
begin
  -- Usuarios creados sin nombre válido (p. ej. desde el panel de Supabase) reciben uno automático.
  if v_usuario !~ '^[a-z0-9_]{3,20}$' then
    v_usuario := 'u_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;

  -- Valores inválidos se guardan vacíos (NULL) en vez de impedir el registro.
  if char_length(v_nombre) not between 3 and 80 then
    v_nombre := null;
  end if;
  if v_whatsapp !~ '^\+[1-9][0-9]{7,14}$' then
    v_whatsapp := null;
  end if;

  if v_ref <> '' then
    select p.id into v_invitador from public.perfiles p where p.codigo_invitacion = v_ref;
  end if;

  -- Si el nombre de usuario ya existe, la restricción unique hace fallar el registro.
  insert into public.perfiles
    (id, nombre_usuario, codigo_invitacion, invitado_por, nombre_completo, whatsapp, acepta_whatsapp_visible)
  values
    (new.id, v_usuario, public.generar_codigo_invitacion(), v_invitador, v_nombre, v_whatsapp, v_acepta);

  return new;
end;
$$;

revoke execute on function public.crear_perfil_nuevo_usuario() from public, anon, authenticated;

-- ---------- Seguridad ----------
-- RLS SIN CAMBIOS: cada usuario solo puede ver su propia fila, así que nadie más ve su WhatsApp.
-- GRANTs: "select" ya cubre las columnas nuevas (solo la fila propia). No se da permiso de
-- "update" sobre ellas: por ahora solo se llenan al registrarse.
-- Las funciones públicas (usuario_por_codigo, usuario_disponible) no devuelven estas columnas.

notify pgrst, 'reload schema';
