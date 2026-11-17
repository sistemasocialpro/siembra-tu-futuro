-- =====================================================================
-- Sistema Siembra tu Futuro — 15_admin_separado.sql
-- Ejecutar DESPUÉS de 01 a 14. Se puede volver a ejecutar sin problema.
--
-- Cuenta de ADMINISTRADOR separada, que NO participa en el sistema:
--   * Se usa la tabla que ya existe, public.administradores (user_id -> auth.users),
--     y es_admin() de 03. No hace falta una tabla "admins" nueva.
--   * Nueva tabla public.administradores_correos: los correos de esta lista, al crearse en
--     Authentication -> Users -> Add user, quedan como administradores SIN perfil
--     (sin nivel, sin código, sin link de referido, fuera de los grupos y sin tareas).
--     Como no tienen perfil, no pueden ocupar casillas (posiciones.user_id -> perfiles),
--     no aparecen en las listas de usuarios ni de candidatos y no reciben tareas.
--   * Nuevas acciones solo para administradores: admin_cambiar_clave, admin_eliminar_cuenta,
--     admin_correos. salir_de_la_red (11) se redefine sobre la misma función interna.
--   * Endurecimiento: se quitan los permisos de escritura directa sobre niveles, grupos,
--     posiciones y configuracion. Todo se escribe con funciones security definer que
--     comprueban es_admin(); RLS sigue permitiendo leer según corresponda.
-- =====================================================================

-- =====================================================================
-- 1. CORREOS QUE SON ADMINISTRADORES SIN PERFIL
-- =====================================================================
create table if not exists public.administradores_correos (
  email     text primary key check (email = lower(trim(email)) and email like '%@%'),
  creado_en timestamptz not null default now()
);

alter table public.administradores_correos enable row level security;
revoke all on table public.administradores_correos from anon, authenticated;
-- Sin políticas ni GRANT: solo se maneja desde el SQL Editor.

insert into public.administradores_correos (email)
values ('soporteplataforma.2027@gmail.com')
on conflict (email) do nothing;

-- =====================================================================
-- 2. TRIGGER DE REGISTRO (14) + administradores sin perfil
-- =====================================================================
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
  -- (15) Cuenta de administrador: entra a la tabla administradores y NO se le crea perfil
  if exists (select 1 from public.administradores_correos c where c.email = lower(trim(coalesce(new.email, '')))) then
    insert into public.administradores (user_id) values (new.id) on conflict (user_id) do nothing;
    return new;
  end if;

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

-- Si el usuario administrador ya existía en Authentication antes de correr este archivo:
-- se agrega a administradores y, si se le había creado un perfil vacío, se borra.
do $$
declare
  r record;
begin
  insert into public.administradores (user_id)
  select u.id
  from auth.users u
  join public.administradores_correos c on c.email = lower(u.email)
  on conflict (user_id) do nothing;

  for r in
    select pe.id, pe.nombre_usuario
    from public.perfiles pe
    join auth.users u on u.id = pe.id
    join public.administradores_correos c on c.email = lower(u.email)
  loop
    if exists (select 1 from public.posiciones p where p.user_id = r.id)
       or exists (select 1 from public.perfiles i where i.invitado_por = r.id)
       or exists (select 1 from public.ciclos_completados cc where cc.user_id = r.id) then
      raise notice 'La cuenta % ya participa (tiene posiciones, invitados o ciclos): no se borró su perfil. Revísala a mano.', r.nombre_usuario;
    else
      delete from public.lista_espera where user_id = r.id;
      delete from public.perfiles where id = r.id;
      raise notice 'Se quitó el perfil de participante de la cuenta de administrador %.', r.nombre_usuario;
    end if;
  end loop;
end;
$$;

-- =====================================================================
-- 3. BORRAR UNA CUENTA DE PARTICIPANTE (interna; la usan salir_de_la_red y el admin)
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

  -- Recibidor de un grupo activo con otras personas
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

  -- Libera cada posición ANTES de borrar la cuenta y avisa
  for r in
    select p.id, p.grupo_id, p.posicion, p.nivel_id, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = p_user_id
    for update of p
  loop
    perform public.liberar_posicion(r.id, 'retirada');
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

  -- Sin posiciones: igual se avisa al patrocinador (se libera un cupo de su link)
  if v_cuantas = 0 and v_perfil.invitado_por is not null then
    perform public.notificar(v_perfil.invitado_por, 'Tu socio se retiró',
      format('Tu socio %s se retiró de la plataforma. Tienes un cupo libre en tu link de invitación.', v_perfil.nombre_usuario));
  end if;

  -- Borra la cuenta: perfiles, notificaciones, lista de espera y ciclos se borran en cascada;
  -- sus invitados quedan con invitado_por nulo y el link del patrocinador recupera el cupo.
  delete from auth.users where id = p_user_id;
  return v_perfil.nombre_usuario;
end;
$$;

-- salir_de_la_red (11): misma lógica, ahora sobre la función interna
create or replace function public.salir_de_la_red()
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
  perform public.borrar_cuenta_participante(v_yo, false);
end;
$$;

-- =====================================================================
-- 4. ACCIONES DEL ADMINISTRADOR (todas comprueban es_admin())
-- =====================================================================

-- Eliminar la cuenta de un participante. Devuelve su nombre de usuario.
create or replace function public.admin_eliminar_cuenta(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede eliminar cuentas.';
  end if;
  if p_user_id is null then
    raise exception 'Elige un usuario.';
  end if;
  if p_user_id = (select auth.uid()) then
    raise exception 'No puedes eliminar tu propia cuenta desde aquí.';
  end if;
  return public.borrar_cuenta_participante(p_user_id, true);
end;
$$;

-- Poner una contraseña nueva a un participante (por ejemplo, si no recibe el correo de
-- recuperación). Cierra sus sesiones abiertas para que entre con la clave nueva.
create or replace function public.admin_cambiar_clave(p_user_id uuid, p_clave text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar contraseñas.';
  end if;
  if p_clave is null or char_length(p_clave) < 6 then
    raise exception 'La contraseña nueva debe tener al menos 6 caracteres.';
  end if;
  if char_length(p_clave) > 72 then
    raise exception 'La contraseña nueva puede tener como máximo 72 caracteres.';
  end if;
  if exists (select 1 from public.administradores a where a.user_id = p_user_id) then
    raise exception 'No se puede cambiar desde aquí la contraseña de un administrador. Usa "¿Olvidaste tu clave?" en el inicio de sesión.';
  end if;

  select pe.nombre_usuario into v_nombre from public.perfiles pe where pe.id = p_user_id;
  if v_nombre is null then
    raise exception 'No se encontró ese usuario.';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_clave, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_user_id;

  -- Cierra sus sesiones (si la base no lo permite, la clave igual queda cambiada)
  begin
    delete from auth.sessions where user_id = p_user_id;
  exception when others then
    null;
  end;

  perform public.notificar(p_user_id, 'Tu contraseña fue cambiada',
    'El administrador te puso una contraseña nueva. Puedes cambiarla cuando quieras en Info personal.');
  return v_nombre;
end;
$$;

-- Correo y último acceso de cada participante (solo para la pestaña Usuarios)
create or replace function public.admin_correos()
returns table (user_id uuid, email text, ultimo_acceso timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver los correos.';
  end if;
  return query
    select u.id, u.email::text, u.last_sign_in_at
    from auth.users u
    join public.perfiles pe on pe.id = u.id;
end;
$$;

-- =====================================================================
-- 5. ENDURECIMIENTO: sin escritura directa sobre las tablas del sistema
-- (la web solo escribe con funciones; RLS sigue igual para leer)
-- =====================================================================
-- admin_crear_grupo y admin_eliminar_grupo (03) eran "security invoker" y escribían con los
-- permisos del admin: pasan a security definer (ya comprueban es_admin() y search_path = '').
alter function public.admin_crear_grupo(integer) security definer;
alter function public.admin_eliminar_grupo(uuid) security definer;
revoke execute on function public.admin_crear_grupo(integer) from public, anon;
revoke execute on function public.admin_eliminar_grupo(uuid) from public, anon;
grant  execute on function public.admin_crear_grupo(integer) to authenticated;
grant  execute on function public.admin_eliminar_grupo(uuid) to authenticated;

revoke insert, update, delete on table public.niveles       from anon, authenticated;
revoke insert, update, delete on table public.grupos        from anon, authenticated;
revoke insert, update, delete on table public.posiciones    from anon, authenticated;
revoke insert, update, delete on table public.configuracion from anon, authenticated;
revoke insert, update, delete on table public.administradores from anon, authenticated;

-- =====================================================================
-- 6. GRANTs
-- =====================================================================
revoke execute on function public.crear_perfil_nuevo_usuario()                 from public, anon, authenticated;
revoke execute on function public.borrar_cuenta_participante(uuid, boolean)    from public, anon, authenticated;

revoke execute on function public.salir_de_la_red()                            from public, anon;
revoke execute on function public.admin_eliminar_cuenta(uuid)                  from public, anon;
revoke execute on function public.admin_cambiar_clave(uuid, text)              from public, anon;
revoke execute on function public.admin_correos()                              from public, anon;

grant execute on function public.salir_de_la_red()                             to authenticated;
grant execute on function public.admin_eliminar_cuenta(uuid)                   to authenticated;
grant execute on function public.admin_cambiar_clave(uuid, text)               to authenticated;
grant execute on function public.admin_correos()                               to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Para agregar OTRO administrador sin perfil (antes de crearlo en Authentication):
--   insert into public.administradores_correos (email) values ('otro@correo.com');
-- Para que tu cuenta personal deje de ser administradora (sigue como participante):
--   delete from public.administradores
--    where user_id = (select id from auth.users where email = 'TU_CORREO_PERSONAL');
-- ---------------------------------------------------------------------
