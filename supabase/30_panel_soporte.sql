-- =====================================================================
-- 30_panel_soporte.sql  (va DESPUÉS de 29_mapa_historial.sql)
-- Panel de soporte del administrador:
--   1) perfiles.numero: número de socio fijo (001, 002, …) por orden de registro; sirve para buscar.
--   2) admin_ficha_usuario(): datos, posiciones, referidos y resumen de tareas por nivel
--      (recibidas como Recibidor y hechas como Regalador, separando normal y repetición).
--   3) admin_arbol(): todos los socios con su patrocinador (el árbol se arma en la página).
--   4) Acciones desde la ficha (todas validan reglas para no dejar grupos rotos):
--      admin_editar_usuario (nombre, usuario, correo, WhatsApp), admin_casillas_libres,
--      admin_mover_posicion, admin_cambiar_patrocinador. Eliminar cuenta usa admin_eliminar_cuenta (15).
--   5) admin_registro: cada cambio hecho por un administrador queda guardado (fecha, quién, qué,
--      valor anterior y nuevo), con triggers en perfiles, posiciones, grupos, configuración y
--      enlaces; se ve con admin_ver_registro().
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

-- =====================================================================
-- 1. NÚMERO DE SOCIO
-- =====================================================================
create sequence if not exists public.perfiles_numero_seq;
alter table public.perfiles add column if not exists numero integer;

-- Relleno por orden de registro (solo los que no tienen número)
do $$
declare
  v_max integer;
begin
  select coalesce(max(numero), 0) into v_max from public.perfiles;
  update public.perfiles pe
     set numero = x.n
    from (select id, v_max + row_number() over (order by creado_en, id) as n
          from public.perfiles where numero is null) x
   where pe.id = x.id;
  perform setval('public.perfiles_numero_seq', greatest((select coalesce(max(numero), 0) from public.perfiles), 1),
                 (select count(*) > 0 from public.perfiles));
end;
$$;

alter table public.perfiles alter column numero set default nextval('public.perfiles_numero_seq');
create unique index if not exists perfiles_numero_uk on public.perfiles (numero);

create or replace function public.numero_socio(p_numero integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_numero is null then null else lpad(p_numero::text, 3, '0') end;
$$;

-- =====================================================================
-- 2. REGISTRO DE CAMBIOS DEL ADMINISTRADOR
-- =====================================================================
create table if not exists public.admin_registro (
  id             bigint generated always as identity primary key,
  creado_en      timestamptz not null default now(),
  admin_id       uuid,
  admin_nombre   text,
  accion         text not null,
  usuario_id     uuid,           -- sin FK: el registro queda aunque se borre la cuenta
  usuario_nombre text,
  detalle        text,
  valor_anterior text,
  valor_nuevo    text
);
create index if not exists admin_registro_fecha_idx on public.admin_registro (creado_en desc);
create index if not exists admin_registro_usuario_idx on public.admin_registro (usuario_id, creado_en desc);
alter table public.admin_registro enable row level security;
revoke all on public.admin_registro from anon, authenticated;

create or replace function public.registrar_admin(p_accion text, p_usuario uuid, p_detalle text, p_anterior text, p_nuevo text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin uuid := (select auth.uid());
begin
  insert into public.admin_registro (admin_id, admin_nombre, accion, usuario_id, usuario_nombre, detalle, valor_anterior, valor_nuevo)
  values (v_admin,
          coalesce((select nombre_usuario from public.perfiles where id = v_admin),
                   (select email::text from auth.users where id = v_admin), 'administrador'),
          p_accion, p_usuario,
          (select nombre_usuario from public.perfiles where id = p_usuario),
          p_detalle, p_anterior, p_nuevo);
end;
$$;

-- Perfiles: cambios de datos, patrocinador, fundador y estado de referido
create or replace function public.reg_admin_perfiles()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    insert into public.admin_registro (admin_id, admin_nombre, accion, usuario_id, usuario_nombre, detalle, valor_anterior, valor_nuevo)
    values ((select auth.uid()),
            coalesce((select nombre_usuario from public.perfiles where id = (select auth.uid())),
                     (select email::text from auth.users where id = (select auth.uid())), 'administrador'),
            'Cuenta eliminada', old.id, old.nombre_usuario, 'Socio ' || public.numero_socio(old.numero),
            concat_ws(' · ', old.nombre_usuario, old.nombre_completo, old.whatsapp), null);
    return old;
  end if;
  if new.nombre_usuario is distinct from old.nombre_usuario then
    perform public.registrar_admin('Datos editados', new.id, 'Usuario', old.nombre_usuario, new.nombre_usuario);
  end if;
  if new.nombre_completo is distinct from old.nombre_completo then
    perform public.registrar_admin('Datos editados', new.id, 'Nombre completo', old.nombre_completo, new.nombre_completo);
  end if;
  if new.whatsapp is distinct from old.whatsapp then
    perform public.registrar_admin('Datos editados', new.id, 'WhatsApp', old.whatsapp, new.whatsapp);
  end if;
  if new.pais is distinct from old.pais then
    perform public.registrar_admin('Datos editados', new.id, 'País', old.pais, new.pais);
  end if;
  if new.invitado_por is distinct from old.invitado_por then
    perform public.registrar_admin('Patrocinador cambiado', new.id, 'Patrocinador',
      (select nombre_usuario from public.perfiles where id = old.invitado_por),
      (select nombre_usuario from public.perfiles where id = new.invitado_por));
  end if;
  if new.es_fundador is distinct from old.es_fundador then
    perform public.registrar_admin('Fundador', new.id, 'Fundador',
      case when old.es_fundador then 'Sí' else 'No' end, case when new.es_fundador then 'Sí' else 'No' end);
  end if;
  if new.referido_estado is distinct from old.referido_estado then
    perform public.registrar_admin('Estado de referido', new.id, 'Estado de referido', old.referido_estado, new.referido_estado);
  end if;
  return new;
end;
$$;

drop trigger if exists perfiles_reg_admin on public.perfiles;
create trigger perfiles_reg_admin
  after update on public.perfiles
  for each row when (public.es_admin())
  execute function public.reg_admin_perfiles();
drop trigger if exists perfiles_reg_admin_borrar on public.perfiles;
create trigger perfiles_reg_admin_borrar
  before delete on public.perfiles
  for each row when (public.es_admin())
  execute function public.reg_admin_perfiles();

-- Casillas: quién estaba y quién quedó
create or replace function public.reg_admin_posiciones()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_det text;
begin
  select format('%s · nivel %s · grupo de %s', public.nombre_posicion(new.posicion), n.nombre,
                coalesce((select pe.nombre_usuario from public.posiciones r join public.perfiles pe on pe.id = r.user_id
                          where r.grupo_id = new.grupo_id and r.posicion = 'recibidor'), 'recibidor libre'))
    into v_det
  from public.niveles n where n.id = new.nivel_id;
  perform public.registrar_admin(
    case when new.user_id is null then 'Casilla liberada' when old.user_id is null then 'Casilla asignada' else 'Casilla reemplazada' end,
    coalesce(new.user_id, old.user_id), v_det,
    coalesce((select nombre_usuario from public.perfiles where id = old.user_id), 'Libre'),
    coalesce((select nombre_usuario from public.perfiles where id = new.user_id), 'Libre'));
  return null;
end;
$$;

drop trigger if exists posiciones_reg_admin on public.posiciones;
create trigger posiciones_reg_admin
  after update of user_id on public.posiciones
  for each row when (old.user_id is distinct from new.user_id and public.es_admin())
  execute function public.reg_admin_posiciones();

-- Grupos creados / eliminados
create or replace function public.reg_admin_grupos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform public.registrar_admin('Grupo creado', null,
      'Nivel ' || (select nombre from public.niveles where id = new.nivel_id), null, new.id::text);
    return null;
  end if;
  perform public.registrar_admin('Grupo eliminado', null,
    'Nivel ' || (select nombre from public.niveles where id = old.nivel_id), old.id::text, null);
  return null;
end;
$$;

drop trigger if exists grupos_reg_admin on public.grupos;
create trigger grupos_reg_admin
  after insert or delete on public.grupos
  for each row when (public.es_admin())
  execute function public.reg_admin_grupos();

-- Configuración, días por nivel y enlaces de soporte
create or replace function public.reg_admin_config()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'configuracion' then
    if tg_op = 'INSERT' or new.valor is distinct from old.valor then
      perform public.registrar_admin('Configuración', null, new.clave,
        case when tg_op = 'UPDATE' then old.valor::text end, new.valor::text);
    end if;
  elsif tg_table_name = 'dias_invitar_nivel' then
    perform public.registrar_admin('Días para invitar', null,
      'Nivel ' || (select nombre from public.niveles where id = coalesce(new.nivel_id, old.nivel_id)),
      case when tg_op <> 'INSERT' then old.dias::text end,
      case when tg_op <> 'DELETE' then new.dias::text else 'valor general' end);
  elsif tg_table_name = 'enlaces_soporte' then
    if tg_op = 'INSERT' or new.valor is distinct from old.valor or new.activo is distinct from old.activo then
      perform public.registrar_admin('Enlace de soporte', null, new.clave,
        case when tg_op = 'UPDATE' then concat(coalesce(old.valor, '—'), case when old.activo then ' (activo)' else ' (inactivo)' end) end,
        concat(coalesce(new.valor, '—'), case when new.activo then ' (activo)' else ' (inactivo)' end));
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists configuracion_reg_admin on public.configuracion;
create trigger configuracion_reg_admin after insert or update on public.configuracion
  for each row when (public.es_admin()) execute function public.reg_admin_config();
drop trigger if exists dias_invitar_nivel_reg_admin on public.dias_invitar_nivel;
create trigger dias_invitar_nivel_reg_admin after insert or update or delete on public.dias_invitar_nivel
  for each row when (public.es_admin()) execute function public.reg_admin_config();
drop trigger if exists enlaces_soporte_reg_admin on public.enlaces_soporte;
create trigger enlaces_soporte_reg_admin after insert or update on public.enlaces_soporte
  for each row when (public.es_admin()) execute function public.reg_admin_config();

-- Redefinida (15): además queda en el registro (sin guardar la contraseña)
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

  begin
    delete from auth.sessions where user_id = p_user_id;
  exception when others then
    null;
  end;

  perform public.notificar(p_user_id, 'Tu contraseña fue cambiada',
    'El administrador te puso una contraseña nueva. Puedes cambiarla cuando quieras en Info personal.');
  perform public.registrar_admin('Contraseña cambiada', p_user_id, 'Contraseña', '(oculta)', '(nueva, oculta)');
  return v_nombre;
end;
$$;

create or replace function public.admin_ver_registro(p_buscar text default null, p_cuantos integer default 50, p_desde integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := nullif(lower(trim(coalesce(p_buscar, ''))), '');
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver el registro.';
  end if;
  return jsonb_build_object(
    'total', (select count(*) from public.admin_registro r
              where v_q is null or lower(concat_ws(' ', r.accion, r.usuario_nombre, r.admin_nombre, r.detalle, r.valor_anterior, r.valor_nuevo)) like '%' || v_q || '%'),
    'filas', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.creado_en desc, x.id desc), '[]'::jsonb)
      from (
        select r.id, r.creado_en, r.admin_nombre, r.accion, r.usuario_id, r.usuario_nombre, r.detalle, r.valor_anterior, r.valor_nuevo
        from public.admin_registro r
        where v_q is null or lower(concat_ws(' ', r.accion, r.usuario_nombre, r.admin_nombre, r.detalle, r.valor_anterior, r.valor_nuevo)) like '%' || v_q || '%'
        order by r.creado_en desc, r.id desc
        limit least(greatest(coalesce(p_cuantos, 50), 1), 200) offset greatest(coalesce(p_desde, 0), 0)
      ) x
    )
  );
end;
$$;

-- =====================================================================
-- 3. FICHA DEL USUARIO
-- =====================================================================
create or replace function public.admin_ficha_usuario(p_user_id uuid)
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
    raise exception 'Solo un administrador puede ver la ficha.';
  end if;
  select * into v_pe from public.perfiles where id = p_user_id;
  if not found then
    raise exception 'No se encontró ese usuario.';
  end if;

  return jsonb_build_object(
    'datos', jsonb_build_object(
      'id', v_pe.id,
      'numero', public.numero_socio(v_pe.numero),
      'nombre_usuario', v_pe.nombre_usuario,
      'nombre_completo', v_pe.nombre_completo,
      'correo', (select email::text from auth.users where id = v_pe.id),
      'ultimo_acceso', (select last_sign_in_at from auth.users where id = v_pe.id),
      'whatsapp', v_pe.whatsapp,
      'pais', v_pe.pais,
      'acepta_whatsapp_visible', v_pe.acepta_whatsapp_visible,
      'codigo_invitacion', v_pe.codigo_invitacion,
      'creado_en', v_pe.creado_en,
      'es_fundador', v_pe.es_fundador,
      'referido_estado', v_pe.referido_estado,
      'patrocinador_id', v_pe.invitado_por,
      'patrocinador', (select nombre_usuario from public.perfiles where id = v_pe.invitado_por),
      'patrocinador_numero', (select public.numero_socio(numero) from public.perfiles where id = v_pe.invitado_por)
    ),
    'referidos', jsonb_build_object(
      'activos', (select count(*) from public.perfiles where invitado_por = v_pe.id and referido_estado = 'activo'),
      'espera', (select count(*) from public.perfiles where invitado_por = v_pe.id and referido_estado = 'reserva'),
      'total', (select count(*) from public.perfiles where invitado_por = v_pe.id)
    ),
    'posiciones', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'posicion_id', p.id, 'posicion', p.posicion, 'estado', p.estado, 'origen', p.origen,
               'nivel_id', n.id, 'nivel', n.nombre, 'nivel_orden', n.orden, 'grupo_id', p.grupo_id, 'tipo_grupo', g.tipo,
               'recibidor', (select pe.nombre_usuario from public.posiciones r join public.perfiles pe on pe.id = r.user_id
                             where r.grupo_id = p.grupo_id and r.posicion = 'recibidor'))
             order by n.orden), '[]'::jsonb)
      from public.posiciones p
      join public.niveles n on n.id = p.nivel_id
      join public.grupos g on g.id = p.grupo_id
      where p.user_id = v_pe.id
    ),
    'espera', (
      select coalesce(jsonb_agg(n.nombre order by n.orden), '[]'::jsonb)
      from public.lista_espera e join public.niveles n on n.id = e.nivel_id
      where e.user_id = v_pe.id
    ),
    -- Tareas por nivel. Una tarea es de "repetición" si esa persona ya había completado ese nivel antes.
    'tareas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nivel_id', n.id, 'nivel', n.nombre, 'nivel_orden', n.orden,
               'recibidas_normal', t.rn, 'recibidas_repeticion', t.rr,
               'hechas_normal', t.hn, 'hechas_repeticion', t.hr) order by n.orden), '[]'::jsonb)
      from public.niveles n
      cross join lateral (
        select
          count(*) filter (where h.recibidor_id = v_pe.id and not h.rep_rec)::int as rn,
          count(*) filter (where h.recibidor_id = v_pe.id and h.rep_rec)::int     as rr,
          count(*) filter (where h.regalador_id = v_pe.id and not h.rep_reg)::int as hn,
          count(*) filter (where h.regalador_id = v_pe.id and h.rep_reg)::int     as hr
        from (
          select th.recibidor_id, th.regalador_id,
                 exists (select 1 from public.ciclos_completados c
                         where c.user_id = th.recibidor_id and c.nivel_id = th.nivel_id
                           and c.completado_en < th.aprobada_en
                           and c.grupo_id is distinct from th.grupo_id) as rep_rec,
                 exists (select 1 from public.ciclos_completados c
                         where c.user_id = th.regalador_id and c.nivel_id = th.nivel_id
                           and c.completado_en < th.aprobada_en) as rep_reg
          from public.tareas_historial th
          where th.nivel_id = n.id and (th.recibidor_id = v_pe.id or th.regalador_id = v_pe.id)
        ) h
      ) t
    ),
    'ultimos_cambios', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.creado_en desc), '[]'::jsonb)
      from (select r.creado_en, r.admin_nombre, r.accion, r.detalle, r.valor_anterior, r.valor_nuevo
            from public.admin_registro r where r.usuario_id = v_pe.id
            order by r.creado_en desc limit 10) x
    )
  );
end;
$$;

-- Todos los socios (para el árbol y la lista): número, usuario, patrocinador y datos cortos
create or replace function public.admin_arbol()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver el árbol.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', pe.id,
             'numero', public.numero_socio(pe.numero),
             'nombre_usuario', pe.nombre_usuario,
             'nombre_completo', pe.nombre_completo,
             'patrocinador_id', pe.invitado_por,
             'referido_estado', pe.referido_estado,
             'es_fundador', pe.es_fundador,
             'nivel', (select n.nombre from public.posiciones p join public.niveles n on n.id = p.nivel_id
                       where p.user_id = pe.id order by n.orden desc limit 1))
           order by pe.numero), '[]'::jsonb)
    from public.perfiles pe
  );
end;
$$;

-- =====================================================================
-- 4. ACCIONES DESDE LA FICHA
-- =====================================================================
create or replace function public.admin_editar_usuario(p_user_id uuid, p_nombre_completo text, p_nombre_usuario text,
                                                      p_correo text, p_whatsapp text, p_pais text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pe      public.perfiles;
  v_nombre  text := regexp_replace(trim(coalesce(p_nombre_completo, '')), '\s+', ' ', 'g');
  v_usuario text := lower(trim(coalesce(p_nombre_usuario, '')));
  v_correo  text := lower(trim(coalesce(p_correo, '')));
  v_pais    text := nullif(trim(coalesce(p_pais, '')), '');
  v_wa      text;
  v_antes   text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede editar usuarios.';
  end if;
  select * into v_pe from public.perfiles where id = p_user_id for update;
  if not found then
    raise exception 'No se encontró ese usuario.';
  end if;
  if exists (select 1 from public.administradores a where a.user_id = p_user_id) then
    raise exception 'Los datos de un administrador no se editan desde aquí.';
  end if;

  if char_length(v_nombre) not between 3 and 80 or v_nombre !~ '[[:alpha:]]' then
    raise exception 'El nombre completo debe tener entre 3 y 80 caracteres y contener letras.';
  end if;
  if v_usuario !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'El usuario debe tener de 3 a 20 caracteres: minúsculas, números o guion bajo (_).';
  end if;
  if exists (select 1 from public.perfiles where nombre_usuario = v_usuario and id <> p_user_id) then
    raise exception 'El usuario % ya está en uso. Elige otro.', v_usuario;
  end if;
  if v_correo !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_correo) > 120 then
    raise exception 'El correo no es válido.';
  end if;
  if exists (select 1 from auth.users where lower(email) = v_correo and id <> p_user_id) then
    raise exception 'El correo % ya lo usa otra cuenta.', v_correo;
  end if;
  v_wa := public.normalizar_whatsapp(p_whatsapp, coalesce(v_pais, v_pe.pais, 'Ecuador'));
  if v_wa is null then
    raise exception 'El WhatsApp no es válido. Para Ecuador escribe, por ejemplo, 0999999999. Para otros países usa + y el código de país.';
  end if;

  update public.perfiles
     set nombre_completo = v_nombre, nombre_usuario = v_usuario, whatsapp = v_wa,
         pais = coalesce(v_pais, pais)
   where id = p_user_id;

  -- Correo de acceso (auth.users e identidad de correo)
  select lower(email) into v_antes from auth.users where id = p_user_id;
  if v_antes is distinct from v_correo then
    update auth.users set email = v_correo, updated_at = now() where id = p_user_id;
    begin
      update auth.identities
         set identity_data = jsonb_set(coalesce(identity_data, '{}'::jsonb), '{email}', to_jsonb(v_correo)), updated_at = now()
       where user_id = p_user_id and provider = 'email';
    exception when others then
      null;
    end;
    perform public.registrar_admin('Datos editados', p_user_id, 'Correo', v_antes, v_correo);
    perform public.notificar(p_user_id, 'Tu correo fue cambiado',
      format('El administrador cambió tu correo de acceso a %s.', v_correo));
  end if;

  return jsonb_build_object('nombre_usuario', v_usuario, 'whatsapp', v_wa, 'correo', v_correo);
end;
$$;

-- Casillas libres de un nivel donde se puede poner a alguien (grupo activo; la de arriba ocupada)
create or replace function public.admin_casillas_libres(p_nivel_id integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver las casillas.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'posicion_id', p.id, 'posicion', p.posicion, 'grupo_id', p.grupo_id,
             'recibidor', (select pe.nombre_usuario from public.posiciones r join public.perfiles pe on pe.id = r.user_id
                           where r.grupo_id = p.grupo_id and r.posicion = 'recibidor'),
             'debajo_de', (select pe.nombre_usuario from public.posiciones c join public.perfiles pe on pe.id = c.user_id
                           where c.grupo_id = p.grupo_id and c.posicion = p.cuelga_de))
           order by g.creado_en, array_position(array['recibidor', 'constructor_1', 'constructor_2',
             'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], p.posicion)), '[]'::jsonb)
    from public.posiciones p
    join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
    where p.nivel_id = p_nivel_id and p.user_id is null
      and (p.posicion = 'recibidor'
           or exists (select 1 from public.posiciones c where c.grupo_id = p.grupo_id and c.posicion = p.cuelga_de and c.user_id is not null))
  );
end;
$$;

-- Mover a una persona de una casilla a otra casilla libre, sin dejar grupos rotos
create or replace function public.admin_mover_posicion(p_desde uuid, p_hacia uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_de    public.posiciones;
  v_a     public.posiciones;
  v_user  uuid;
  v_nom   text;
  v_nivel text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede mover posiciones.';
  end if;
  if p_desde = p_hacia then
    raise exception 'Elige otra casilla.';
  end if;
  -- Bloqueo de las 2 casillas en orden fijo
  perform 1 from public.posiciones where id in (p_desde, p_hacia) order by id for update;
  select * into v_de from public.posiciones where id = p_desde;
  select * into v_a from public.posiciones where id = p_hacia;
  if v_de.id is null or v_a.id is null then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if v_de.user_id is null then
    raise exception 'La casilla de origen ya está libre.';
  end if;
  v_user := v_de.user_id;
  select nombre_usuario into v_nom from public.perfiles where id = v_user;

  -- Reglas para no dejar el grupo de origen roto
  if v_de.posicion = 'recibidor'
     and exists (select 1 from public.posiciones o where o.grupo_id = v_de.grupo_id and o.user_id is not null and o.id <> v_de.id) then
    raise exception '% es el recibidor de un grupo con personas: no se puede sacar de ahí. Primero mueve a las demás personas o usa Reemplazar en Grupos.', v_nom;
  end if;
  if v_de.posicion like 'constructor%'
     and exists (select 1 from public.posiciones o where o.grupo_id = v_de.grupo_id and o.cuelga_de = v_de.posicion and o.user_id is not null) then
    raise exception '% tiene regaladores debajo: no se puede mover sin dejarlos colgando. Primero mueve a sus regaladores.', v_nom;
  end if;
  if v_de.estado = 'confirmada' then
    raise exception 'La tarea de % ya fue aprobada en ese grupo: moverla haría perder esa aprobación.', v_nom;
  end if;

  -- Casilla de destino
  if v_a.user_id is not null then
    raise exception 'La casilla de destino ya está ocupada. Recarga la página.';
  end if;
  if exists (select 1 from public.grupos where id = v_a.grupo_id and estado <> 'activo') then
    raise exception 'El grupo de destino ya se completó.';
  end if;
  if v_a.nivel_id <> v_de.nivel_id
     and exists (select 1 from public.posiciones where user_id = v_user and nivel_id = v_a.nivel_id) then
    raise exception '% ya tiene una posición en ese nivel.', v_nom;
  end if;
  if v_a.posicion <> 'recibidor'
     and not exists (select 1 from public.posiciones c where c.grupo_id = v_a.grupo_id and c.posicion = v_a.cuelga_de
                     and c.user_id is not null and c.id <> v_de.id) then
    raise exception 'La casilla de destino no tiene a nadie arriba (%). Elige otra.', public.nombre_posicion(v_a.cuelga_de);
  end if;

  perform public.liberar_posicion(v_de.id, null);
  perform public.ocupar_posicion(v_a.id, v_user, v_de.origen = 'automatico');
  select nombre into v_nivel from public.niveles where id = v_a.nivel_id;
  perform public.notificar(v_user, 'Te movieron de casilla',
    format('El administrador te movió a %s en el nivel %s.', public.nombre_posicion(v_a.posicion), v_nivel));
  return v_nom;
end;
$$;

-- Cambiar el patrocinador (quién lo invitó). El estado de referido se recalcula con la regla de
-- siempre (activo si el nuevo patrocinador tiene lugar; si no, a su lista de espera).
create or replace function public.admin_cambiar_patrocinador(p_user_id uuid, p_nuevo uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pe     public.perfiles;
  v_viejo  uuid;
  v_activo boolean;
  v_nom    text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar el patrocinador.';
  end if;
  if p_nuevo is null then
    raise exception 'Elige al nuevo patrocinador.';
  end if;
  if p_nuevo = p_user_id then
    raise exception 'Una persona no puede ser su propio patrocinador.';
  end if;
  perform 1 from public.perfiles where id in (p_user_id, p_nuevo) order by id for update;
  select * into v_pe from public.perfiles where id = p_user_id;
  if not found or not exists (select 1 from public.perfiles where id = p_nuevo) then
    raise exception 'No se encontró ese usuario.';
  end if;
  if v_pe.invitado_por = p_nuevo then
    raise exception 'Ese ya es su patrocinador.';
  end if;
  -- Sin ciclos: el nuevo patrocinador no puede estar debajo de esta persona
  if exists (
    with recursive red as (
      select id from public.perfiles where invitado_por = p_user_id
      union
      select pe.id from public.perfiles pe join red on pe.invitado_por = red.id
    )
    select 1 from red where id = p_nuevo
  ) then
    raise exception 'El nuevo patrocinador está en la red de esta persona: se formaría un círculo.';
  end if;

  v_viejo := v_pe.invitado_por;
  v_activo := v_pe.referido_estado = 'activo';
  update public.perfiles set invitado_por = p_nuevo where id = p_user_id;   -- limitar_referidos recalcula el estado
  delete from public.repeticion_sigue where user_id = p_user_id and sigue_a = v_viejo;

  -- Si era activo del patrocinador anterior, se le libera ese lugar
  if v_activo and v_viejo is not null then
    perform public.abrir_lugar_libre(v_viejo, null);
  end if;
  select nombre_usuario into v_nom from public.perfiles where id = p_nuevo;
  perform public.notificar(p_user_id, 'Cambió tu patrocinador',
    format('El administrador cambió tu patrocinador. Ahora es %s.', v_nom));
  perform public.notificar(p_nuevo, 'Tienes un nuevo referido',
    format('El administrador puso a %s como tu referido.', v_pe.nombre_usuario));
  return v_pe.nombre_usuario;
end;
$$;

-- =====================================================================
-- 5. PERMISOS
-- =====================================================================
revoke execute on function public.registrar_admin(text, uuid, text, text, text)      from public, anon, authenticated;
revoke execute on function public.reg_admin_perfiles()                               from public, anon, authenticated;
revoke execute on function public.reg_admin_posiciones()                             from public, anon, authenticated;
revoke execute on function public.reg_admin_grupos()                                 from public, anon, authenticated;
revoke execute on function public.reg_admin_config()                                 from public, anon, authenticated;

revoke execute on function public.admin_cambiar_clave(uuid, text)                    from public, anon;
revoke execute on function public.admin_ver_registro(text, integer, integer)         from public, anon;
revoke execute on function public.admin_ficha_usuario(uuid)                          from public, anon;
revoke execute on function public.admin_arbol()                                      from public, anon;
revoke execute on function public.admin_editar_usuario(uuid, text, text, text, text, text) from public, anon;
revoke execute on function public.admin_casillas_libres(integer)                     from public, anon;
revoke execute on function public.admin_mover_posicion(uuid, uuid)                   from public, anon;
revoke execute on function public.admin_cambiar_patrocinador(uuid, uuid)             from public, anon;
grant  execute on function public.admin_cambiar_clave(uuid, text)                    to authenticated;
grant  execute on function public.admin_ver_registro(text, integer, integer)         to authenticated;
grant  execute on function public.admin_ficha_usuario(uuid)                          to authenticated;
grant  execute on function public.admin_arbol()                                      to authenticated;
grant  execute on function public.admin_editar_usuario(uuid, text, text, text, text, text) to authenticated;
grant  execute on function public.admin_casillas_libres(integer)                     to authenticated;
grant  execute on function public.admin_mover_posicion(uuid, uuid)                   to authenticated;
grant  execute on function public.admin_cambiar_patrocinador(uuid, uuid)             to authenticated;

notify pgrst, 'reload schema';
