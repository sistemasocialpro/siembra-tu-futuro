-- =====================================================================
-- Sistema Siembra tu Futuro — 14_whatsapp_formato.sql
-- Ejecutar DESPUÉS de 01 a 13. Se puede volver a ejecutar sin problema.
--
-- El WhatsApp se acepta en formato local de Ecuador (0991234567, 991234567) y con código de
-- país (593…, +593…, 00593…), con o sin espacios, y se guarda SIEMPRE como +593991234567.
-- Otros países: con + y código de país. Un celular de Ecuador es +593 9 + 8 dígitos.
-- El CHECK perfiles_whatsapp_chk (02: '^\+[1-9][0-9]{7,14}$') es compatible con el resultado.
-- =====================================================================

-- ---------- a. Normalizar ----------
create or replace function public.normalizar_whatsapp(p_texto text, p_pais text default 'Ecuador')
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := regexp_replace(coalesce(p_texto, ''), '[\s().-]', '', 'g');
begin
  if v = '' then return null; end if;
  if v like '00%' then v := '+' || substr(v, 3); end if;
  if left(v, 1) <> '+' and coalesce(nullif(trim(p_pais), ''), 'Ecuador') in ('Ecuador', 'EC') then
    if    v ~ '^0[0-9]{9}$'   then v := '+593' || substr(v, 2);
    elsif v ~ '^593[0-9]{9}$' then v := '+' || v;
    elsif v ~ '^9[0-9]{8}$'   then v := '+593' || v;
    end if;
  end if;
  if v !~ '^\+[1-9][0-9]{7,14}$' then return null; end if;
  if v like '+593%' and v !~ '^\+5939[0-9]{8}$' then return null; end if;
  return v;
end;
$$;

grant execute on function public.normalizar_whatsapp(text, text) to public, anon, authenticated;

-- ---------- b. actualizar_mi_perfil (13) con normalizar_whatsapp ----------
create or replace function public.actualizar_mi_perfil(p_nombre text, p_whatsapp text, p_pais text, p_acepta_whatsapp boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_nombre text := regexp_replace(trim(coalesce(p_nombre, '')), '\s+', ' ', 'g');
  v_wa     text := public.normalizar_whatsapp(p_whatsapp, p_pais);
  v_pais   text := nullif(trim(coalesce(p_pais, '')), '');
  v_perfil public.perfiles;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  if char_length(v_nombre) not between 3 and 80 then
    raise exception 'El nombre completo debe tener entre 3 y 80 caracteres.';
  end if;
  if v_nombre !~ '[[:alpha:]]' then
    raise exception 'El nombre completo debe contener letras.';
  end if;
  if v_wa is null then
    raise exception 'El WhatsApp no es válido. Para Ecuador escribe, por ejemplo, 0999999999. Para otros países usa + y el código de país.';
  end if;
  if v_pais is not null and char_length(v_pais) not between 2 and 60 then
    raise exception 'El país no es válido.';
  end if;

  update public.perfiles
     set nombre_completo = v_nombre,
         whatsapp = v_wa,
         pais = v_pais,
         acepta_whatsapp_visible = coalesce(p_acepta_whatsapp, false)
   where id = v_yo
  returning * into v_perfil;

  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  return jsonb_build_object(
    'nombre_usuario', v_perfil.nombre_usuario,
    'nombre_completo', v_perfil.nombre_completo,
    'whatsapp', v_perfil.whatsapp,
    'pais', v_perfil.pais,
    'acepta_whatsapp_visible', v_perfil.acepta_whatsapp_visible,
    'creado_en', v_perfil.creado_en
  );
end;
$$;

-- ---------- c. Registro: trigger que crea el perfil (versión de 12 + normalizar_whatsapp) ----------
-- Lee raw_user_meta_data: { nombre_usuario, nombre_completo, whatsapp, pais (opcional; si no
-- viene se asume Ecuador), acepta_whatsapp_visible, codigo_ref }.
-- Antes un WhatsApp inválido se guardaba vacío; ahora el registro falla con un mensaje claro
-- (salvo usuarios creados desde el panel de Supabase sin WhatsApp, que siguen quedando en NULL).
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
  v_pais      text  := nullif(trim(coalesce(v_meta ->> 'pais', '')), '');
  v_wa_texto  text  := trim(coalesce(v_meta ->> 'whatsapp', ''));
  v_whatsapp  text;
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
  if v_pais is not null and char_length(v_pais) not between 2 and 60 then
    v_pais := null;
  end if;

  if v_wa_texto <> '' then
    v_whatsapp := public.normalizar_whatsapp(v_wa_texto, coalesce(v_pais, 'Ecuador'));
    if v_whatsapp is null then
      raise exception 'El WhatsApp no es válido. Para Ecuador escribe, por ejemplo, 0999999999. Para otros países usa + y el código de país.'
        using errcode = 'P0001';
    end if;
  end if;

  if v_ref <> '' then
    select p.id into v_invitador from public.perfiles p where p.codigo_invitacion = v_ref;
  end if;

  -- Sin link válido no hay registro mientras el interruptor esté en 1 (12)
  if v_invitador is null and public.registro_exige_link() then
    raise exception 'Para registrarte necesitas el link de invitación de alguien de la comunidad.'
      using errcode = 'P0001';
  end if;

  -- El límite de 2 referidos lo aplica el trigger perfiles_limitar_referidos (10).
  insert into public.perfiles
    (id, nombre_usuario, codigo_invitacion, invitado_por, nombre_completo, whatsapp, pais, acepta_whatsapp_visible)
  values
    (new.id, v_usuario, public.generar_codigo_invitacion(), v_invitador, v_nombre, v_whatsapp, v_pais, v_acepta);

  return new;
end;
$$;

revoke execute on function public.crear_perfil_nuevo_usuario() from public, anon, authenticated;

-- ---------- d. Normalizar los WhatsApp ya guardados (solo los que se pueden) ----------
update public.perfiles
   set whatsapp = coalesce(public.normalizar_whatsapp(whatsapp, pais), whatsapp)
 where whatsapp is distinct from coalesce(public.normalizar_whatsapp(whatsapp, pais), whatsapp);

-- ---------- e. WhatsApp de soporte: acepta 0999…, 593…, +593…; se guarda 593991234567 ----------
create or replace function public.admin_guardar_enlace(p_clave text, p_valor text, p_activo boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_valor text := nullif(trim(coalesce(p_valor, '')), '');
  v_wa    text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar los enlaces de soporte.';
  end if;
  if p_clave not in ('telegram', 'linktree', 'whatsapp', 'correo') then
    raise exception 'Ese enlace no existe.';
  end if;
  if coalesce(p_activo, false) and v_valor is null then
    raise exception 'Para activar un enlace primero escribe su valor.';
  end if;

  if v_valor is not null then
    if p_clave in ('telegram', 'linktree') and v_valor !~* '^https://[^\s]+\.[^\s]+$' then
      raise exception 'El enlace de % debe empezar con https://', case p_clave when 'telegram' then 'Telegram' else 'Linktree' end;
    end if;
    if p_clave = 'whatsapp' then
      v_wa := public.normalizar_whatsapp(v_valor, 'Ecuador');
      if v_wa is null then
        raise exception 'El WhatsApp de soporte no es válido. Para Ecuador escribe, por ejemplo, 0999999999. Para otros países usa + y el código de país.';
      end if;
      v_valor := substr(v_wa, 2); -- sin "+": así lo usa wa.me
    end if;
    if p_clave = 'correo' and v_valor !~* '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
      raise exception 'El correo de soporte no es válido.';
    end if;
  end if;

  update public.enlaces_soporte set valor = v_valor, activo = coalesce(p_activo, false) where clave = p_clave;
end;
$$;

revoke execute on function public.admin_guardar_enlace(text, text, boolean) from public, anon;
grant execute on function public.admin_guardar_enlace(text, text, boolean) to authenticated;

notify pgrst, 'reload schema';

-- Para revisar:
-- select public.normalizar_whatsapp('0991234567');        -- +593991234567
-- select public.normalizar_whatsapp('00593991234567');    -- +593991234567
-- select public.normalizar_whatsapp('3001234567', 'Colombia'); -- NULL (falta +57)
