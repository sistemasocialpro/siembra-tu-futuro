-- =====================================================================
-- Sistema Siembra tu Futuro — 12_registro_con_link.sql
-- Ejecutar DESPUÉS de 01 a 11. Se puede volver a ejecutar sin problema.
--
-- Interruptor 'registro_exige_link' en configuracion (1 = sí, 0 = no; por defecto 1).
-- Con 1, solo se puede crear una cuenta con un link de invitación válido (?ref=).
-- Con 0, se permite registrarse sin link (para crear a los fundadores).
-- El cierre real está en la base: el trigger que crea el perfil rechaza el registro sin
-- invitado_por cuando el interruptor está en 1.
-- =====================================================================

-- configuracion.valor tenía "check (valor > 0)": se permite 0 para el interruptor.
alter table public.configuracion drop constraint if exists configuracion_valor_check;
alter table public.configuracion drop constraint if exists configuracion_valor_chk;
alter table public.configuracion add constraint configuracion_valor_chk
  check (
    valor >= 0
    and (clave <> 'registro_exige_link' or valor in (0, 1))
    and (clave = 'registro_exige_link' or valor > 0)
  );

-- Al re-ejecutar NO se pisa el valor que haya puesto el administrador.
insert into public.configuracion (clave, valor, descripcion) values
  ('registro_exige_link', 1, 'Exigir link de referido para registrarse: 1 = sí, 0 = no (para crear fundadores).')
on conflict (clave) do update set descripcion = excluded.descripcion;

-- ¿Se exige link para registrarse? (pública: la usa la pantalla de registro sin sesión)
create or replace function public.registro_exige_link()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select c.valor <> 0 from public.configuracion c where c.clave = 'registro_exige_link'), true);
$$;

-- Solo administradores
create or replace function public.admin_guardar_registro_exige_link(p_exige boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar esta opción.';
  end if;
  insert into public.configuracion (clave, valor) values ('registro_exige_link', case when coalesce(p_exige, true) then 1 else 0 end)
  on conflict (clave) do update set valor = excluded.valor, actualizado_en = now();
end;
$$;

-- admin_guardar_configuracion (05) no se toca: sigue validando solo sus 3 plazos (> 0).

-- ---------- Trigger de registro (02) con el refuerzo ----------
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
  if v_usuario !~ '^[a-z0-9_]{3,20}$' then
    v_usuario := 'u_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;
  if char_length(v_nombre) not between 3 and 80 then
    v_nombre := null;
  end if;
  if v_whatsapp !~ '^\+[1-9][0-9]{7,14}$' then
    v_whatsapp := null;
  end if;

  if v_ref <> '' then
    select p.id into v_invitador from public.perfiles p where p.codigo_invitacion = v_ref;
  end if;

  -- Refuerzo: sin link válido no hay registro mientras el interruptor esté en 1
  -- (también aplica a usuarios creados desde el panel de Supabase).
  if v_invitador is null and public.registro_exige_link() then
    raise exception 'Para registrarte necesitas el link de invitación de alguien de la comunidad.'
      using errcode = 'P0001';
  end if;

  -- El límite de 2 referidos lo aplica el trigger perfiles_limitar_referidos (10).
  insert into public.perfiles
    (id, nombre_usuario, codigo_invitacion, invitado_por, nombre_completo, whatsapp, acepta_whatsapp_visible)
  values
    (new.id, v_usuario, public.generar_codigo_invitacion(), v_invitador, v_nombre, v_whatsapp, v_acepta);

  return new;
end;
$$;

revoke execute on function public.crear_perfil_nuevo_usuario()                 from public, anon, authenticated;
revoke execute on function public.registro_exige_link()                         from public;
revoke execute on function public.admin_guardar_registro_exige_link(boolean)    from public, anon;

grant execute on function public.registro_exige_link()                          to anon, authenticated;
grant execute on function public.admin_guardar_registro_exige_link(boolean)     to authenticated;

notify pgrst, 'reload schema';

-- Para crear fundadores:  update public.configuracion set valor = 0 where clave = 'registro_exige_link';
-- Y para volver a cerrar: update public.configuracion set valor = 1 where clave = 'registro_exige_link';
