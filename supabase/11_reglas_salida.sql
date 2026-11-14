-- =====================================================================
-- Sistema Siembra tu Futuro — 11_reglas_salida.sql
-- Ejecutar DESPUÉS de 01 a 10. Se puede volver a ejecutar sin problema.
-- (Es lo que pedía prompt-cambios-5 como "08_reglas_salida.sql".)
--
-- 1) Días para invitar POR NIVEL: tabla dias_invitar_nivel (si un nivel no tiene fila se usa
--    el valor global dias_invitar de configuracion). Se usa en revisar_plazos(), mi_reloj(),
--    ascender_grupo() y en los mensajes que mencionan los días.
-- 2) salir_de_la_red(): libera las posiciones de la persona, avisa a su patrocinador y al
--    recibidor, y BORRA su cuenta (auth.users -> perfiles en cascada). Como su perfil deja de
--    existir, contar_referidos() (10) ya no la cuenta y el cupo del link de su patrocinador
--    se libera.
-- 3) retirar_y_reemplazar, admin_quitar_posicion y revisar_plazos también avisan al patrocinador.
-- =====================================================================

-- =====================================================================
-- 1. DÍAS PARA INVITAR POR NIVEL
-- =====================================================================
create table if not exists public.dias_invitar_nivel (
  nivel_id integer primary key references public.niveles (id) on delete cascade,
  dias     numeric not null check (dias > 0)
);
comment on table public.dias_invitar_nivel is
  'Días para invitar a 2 personas en cada nivel. Sin fila = se usa configuracion.dias_invitar.';

-- Días (número) del nivel
create or replace function public.dias_invitar_valor(p_nivel_id integer)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select d.dias from public.dias_invitar_nivel d where d.nivel_id = p_nivel_id),
    (select c.valor from public.configuracion c where c.clave = 'dias_invitar'),
    7);
$$;

-- Plazo como intervalo
create or replace function public.dias_invitar_de(p_nivel_id integer)
returns interval
language sql
stable
security definer
set search_path = ''
as $$
  select interval '1 day' * public.dias_invitar_valor(p_nivel_id)::float8;
$$;

-- "7 días", "1 día" o, si es menos de un día (pruebas), "10 min"
create or replace function public.texto_dias_invitar(p_nivel_id integer)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when v >= 1 then public.texto_numero(v) || case when v = 1 then ' día' else ' días' end
           else public.texto_duracion(public.dias_invitar_de(p_nivel_id))
         end
  from (select public.dias_invitar_valor(p_nivel_id) as v) x;
$$;

-- Solo administradores. p_dias NULL = quitar el valor del nivel (vuelve al global).
create or replace function public.admin_guardar_dias_nivel(p_nivel_id integer, p_dias numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar los días por nivel.';
  end if;
  if not exists (select 1 from public.niveles where id = p_nivel_id) then
    raise exception 'El nivel elegido no existe.';
  end if;
  if p_dias is null then
    delete from public.dias_invitar_nivel where nivel_id = p_nivel_id;
    return;
  end if;
  if p_dias <= 0 then
    raise exception 'Los días deben ser un número mayor que 0.';
  end if;
  insert into public.dias_invitar_nivel (nivel_id, dias) values (p_nivel_id, p_dias)
  on conflict (nivel_id) do update set dias = excluded.dias;
end;
$$;

-- =====================================================================
-- 2. AVISOS AL PATROCINADOR
-- =====================================================================
-- Lado de la casilla: Regalador 1 y 2 y Constructor 1 = izquierda; Regalador 3 y 4 y
-- Constructor 2 = derecha; recibidor = centro.
create or replace function public.lado_posicion(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p in ('regalador_1', 'regalador_2', 'constructor_1') then 'izquierda'
    when p in ('regalador_3', 'regalador_4', 'constructor_2') then 'derecha'
    else 'centro'
  end;
$$;

-- "Tu socio juan, que estaba en Regalador 1 (izquierda) del nivel Terreno, <p_final>"
create or replace function public.avisar_patrocinador(p_user_id uuid, p_posicion text, p_nivel_id integer, p_final text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pat     uuid;
  v_usuario text;
  v_nivel   text;
begin
  select invitado_por, nombre_usuario into v_pat, v_usuario from public.perfiles where id = p_user_id;
  if v_pat is null then
    return;
  end if;
  select nombre into v_nivel from public.niveles where id = p_nivel_id;
  perform public.notificar(v_pat, 'Tu socio dejó su lugar',
    format('Tu socio %s, que estaba en %s (%s) del nivel %s, %s',
           v_usuario, public.nombre_posicion(p_posicion), public.lado_posicion(p_posicion), v_nivel, p_final));
end;
$$;

-- =====================================================================
-- 3. FUNCIONES REDEFINIDAS CON DÍAS POR NIVEL
-- =====================================================================

-- Notificación al ocupar una casilla con relojes (días del nivel)
create or replace function public.notificar_lugar(p_user_id uuid, p_posicion text, p_nivel text, p_intro text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nivel_id integer := (select id from public.niveles where nombre = p_nivel);
begin
  perform public.notificar(p_user_id, 'Reservaste tu lugar',
    p_intro || ' ' ||
    case
      when p_posicion like 'regalador%' then
        format('Tienes %s para hacer tu tarea, avisar al recibidor por WhatsApp y marcarla como hecha.', public.texto_horas_tarea())
      when p_posicion like 'constructor%' then
        format('Tienes %s para invitar a 2 personas que obtengan su lugar en el nivel %s.', public.texto_dias_invitar(v_nivel_id), p_nivel)
      else
        'Como recibidor no tienes relojes: espera las tareas de tus 4 regaladores y apruébalas en Mi grupo.'
    end);
end;
$$;

-- Ascenso (igual que en 07, con los días del nivel en el mensaje)
create or replace function public.ascender_grupo(p_grupo_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grupo  public.grupos;
  v_nivel  public.niveles;
  v_rec    uuid;
  v_c1     uuid;
  v_c2     uuid;
  v_r      uuid[];
  v_a      uuid;
  v_b      uuid;
  v_espera int;
  v_ultimo boolean;
  u        uuid;
begin
  select * into v_grupo from public.grupos where id = p_grupo_id for update;
  if not found or v_grupo.estado <> 'activo' then
    return false;
  end if;

  if (select count(*) from public.posiciones
       where grupo_id = p_grupo_id and posicion like 'regalador%'
         and user_id is not null and estado = 'confirmada') < 4 then
    return false;
  end if;

  select * into v_nivel from public.niveles where id = v_grupo.nivel_id;

  select (array_agg(user_id) filter (where posicion = 'recibidor'))[1],
         (array_agg(user_id) filter (where posicion = 'constructor_1'))[1],
         (array_agg(user_id) filter (where posicion = 'constructor_2'))[1],
         array[
           (array_agg(user_id) filter (where posicion = 'regalador_1'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_2'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_3'))[1],
           (array_agg(user_id) filter (where posicion = 'regalador_4'))[1]
         ]
    into v_rec, v_c1, v_c2, v_r
  from public.posiciones
  where grupo_id = p_grupo_id;

  if v_rec is not null then
    insert into public.ciclos_completados (user_id, nivel_id, grupo_id)
    values (v_rec, v_nivel.id, p_grupo_id)
    on conflict (user_id, nivel_id) do update
      set grupo_id = excluded.grupo_id, completado_en = now();
  end if;

  update public.posiciones
     set user_id = null, origen = null, estado = null, asignado_en = null,
         reservada_en = null, tarea_hecha_en = null, ascendido_en = null, aviso_enviado = false
   where grupo_id = p_grupo_id;
  update public.grupos set estado = 'completado' where id = p_grupo_id;

  v_a := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_a, 'recibidor',     v_c1);
  perform public.colocar_ascendido(v_a, 'constructor_1', v_r[1]);
  perform public.colocar_ascendido(v_a, 'constructor_2', v_r[2]);

  v_b := public.crear_grupo_vacio(v_nivel.id);
  perform public.colocar_ascendido(v_b, 'recibidor',     v_c2);
  perform public.colocar_ascendido(v_b, 'constructor_1', v_r[3]);
  perform public.colocar_ascendido(v_b, 'constructor_2', v_r[4]);

  -- Último nivel según el ORDEN (no según el id)
  v_ultimo := public.nivel_siguiente(v_nivel.id) is null;
  perform public.notificar(v_rec, 'Completaste el nivel ' || v_nivel.nombre,
    case when v_ultimo
         then format('Completaste el nivel %s, el último nivel. ¡Felicitaciones!', v_nivel.nombre)
         else format('Completaste el nivel %s. Ya puedes participar en el siguiente desde Niveles.', v_nivel.nombre)
    end);

  foreach u in array v_r loop
    perform public.notificar(u, 'Subiste a constructor',
      format('La persona del centro recibió todas las tareas y subiste a constructor. Tienes %s para invitar a 2 personas. (Nivel %s)',
             public.texto_dias_invitar(v_nivel.id), v_nivel.nombre));
  end loop;

  perform public.notificar(v_c1, 'Eres recibidor',
    format('Ahora eres el recibidor de un grupo nuevo. (Nivel %s)', v_nivel.nombre));
  perform public.notificar(v_c2, 'Eres recibidor',
    format('Ahora eres el recibidor de un grupo nuevo. (Nivel %s)', v_nivel.nombre));

  select count(*) into v_espera from public.lista_espera where nivel_id = v_nivel.id;
  if v_espera > 0 then
    perform public.notificar_admins('Grupos nuevos con lugares libres',
      format('Un grupo del nivel %s se completó y se dividió en 2 grupos nuevos con regaladores libres. Hay %s persona(s) en lista de espera de ese nivel: asígnalas en Administración → Lista de espera.',
             v_nivel.nombre, v_espera));
  end if;

  return true;
end;
$$;

-- confirmar_tarea: "último nivel" según el orden
create or replace function public.confirmar_tarea(p_posicion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := (select auth.uid());
  v_pos     public.posiciones;
  v_ascenso boolean;
  v_nivel   public.niveles;
begin
  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if public.recibidor_de_grupo(v_pos.grupo_id) is distinct from v_yo then
    raise exception 'Solo el recibidor del grupo puede aprobar tareas.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla está libre.';
  end if;
  if v_pos.posicion not like 'regalador%' then
    raise exception 'Solo se aprueban tareas de regaladores.';
  end if;
  if v_pos.estado = 'confirmada' then
    raise exception 'Esa tarea ya fue aprobada.';
  end if;
  if v_pos.estado is distinct from 'tarea_hecha' then
    raise exception 'Esa persona todavía no marcó su tarea como hecha.';
  end if;

  update public.posiciones set estado = 'confirmada' where id = p_posicion_id;

  perform public.notificar(v_pos.user_id, 'Tu tarea fue confirmada',
    'El recibidor confirmó que recibió tu tarea. Cuando los 4 regaladores estén aprobados subirás a constructor.');

  v_ascenso := public.ascender_grupo(v_pos.grupo_id);
  select * into v_nivel from public.niveles where id = v_pos.nivel_id;

  return jsonb_build_object(
    'ascenso', v_ascenso,
    'nivel', v_nivel.nombre,
    'ultimo_nivel', public.nivel_siguiente(v_nivel.id) is null
  );
end;
$$;

-- mi_reloj: fin_invitar con los días del nivel
create or replace function public.mi_reloj(p_nivel_id integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo   uuid := (select auth.uid());
  v_pos  public.posiciones;
  v_id   uuid;
  v_fase text;
  v_inv  int;
  v_nivel text;
  v_rec  uuid;
begin
  select x.id, x.fase into v_id, v_fase
  from (
    select p.id, n.orden,
           case
             when p.posicion like 'regalador%' and p.origen = 'automatico' and p.estado = 'reservada' then 'tarea'
             when p.posicion like 'regalador%' and p.origen = 'automatico' and p.estado in ('tarea_hecha', 'confirmada') then 'esperando'
             when p.posicion like 'constructor%' and p.ascendido_en is not null and p.estado = 'plazo_vencido' then 'plazo_vencido'
             when p.posicion like 'constructor%' and p.ascendido_en is not null then
               case when public.contar_invitados(v_yo, p.nivel_id) >= 2 then 'listo' else 'invitar' end
           end as fase
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = v_yo
      and (p_nivel_id is null or p.nivel_id = p_nivel_id)
  ) x
  where x.fase is not null
  order by array_position(array['tarea', 'plazo_vencido', 'invitar', 'esperando', 'listo'], x.fase), x.orden desc
  limit 1;

  if v_fase is null then
    return null;
  end if;

  select * into v_pos from public.posiciones where id = v_id;
  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  v_rec := public.recibidor_de_grupo(v_pos.grupo_id);
  v_inv := public.contar_invitados(v_yo, v_pos.nivel_id);

  return jsonb_build_object(
    'ahora',              now(),
    'fase',               v_fase,
    'posicion_id',        v_pos.id,
    'posicion',           v_pos.posicion,
    'nivel_id',           v_pos.nivel_id,
    'nivel_nombre',       v_nivel,
    'estado',             v_pos.estado,
    'reservada_en',       v_pos.reservada_en,
    'fin_tarea',          v_pos.reservada_en + public.intervalo_config('horas_tarea'),
    'tarea_hecha_en',     v_pos.tarea_hecha_en,
    'ascendido_en',       v_pos.ascendido_en,
    'fin_invitar',        v_pos.ascendido_en + public.dias_invitar_de(v_pos.nivel_id),
    'dias_invitar',       public.dias_invitar_valor(v_pos.nivel_id),
    'invitados',          v_inv,
    'aprobadas',          (select count(*) from public.posiciones
                            where grupo_id = v_pos.grupo_id and posicion like 'regalador%'
                              and user_id is not null and estado = 'confirmada'),
    'recibidor_nombre',   (select nombre_usuario from public.perfiles where id = v_rec),
    'recibidor_whatsapp', case when v_rec is not null then public.whatsapp_de(v_rec) end
  );
end;
$$;

-- revisar_plazos: días por nivel + aviso al patrocinador cuando alguien sale por tiempo
create or replace function public.revisar_plazos()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r           record;
  v_tarea     interval := public.intervalo_config('horas_tarea');
  v_aviso     interval := public.intervalo_config('horas_aviso');
  v_retirados int := 0;
  v_avisos    int := 0;
  v_vencidos  int := 0;
begin
  -- (a) Regalador reservado sin tarea hecha y pasaron horas_tarea: sale de la posición
  for r in
    select p.id, p.user_id, p.posicion, p.nivel_id, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.origen = 'automatico' and p.posicion like 'regalador%'
      and p.estado = 'reservada' and p.tarea_hecha_en is null
      and p.reservada_en + v_tarea <= now()
    for update of p skip locked
  loop
    perform public.liberar_posicion(r.id, 'retirada');
    perform public.notificar(r.user_id, 'Se acabó tu tiempo',
      format('Pasaron %s sin que marcaras tu tarea como hecha y saliste de la posición %s del nivel %s. Puedes volver a tocar Participar.',
             public.texto_duracion(v_tarea), public.nombre_posicion(r.posicion), r.nivel));
    perform public.avisar_patrocinador(r.user_id, r.posicion, r.nivel_id,
      'salió de su posición porque se acabó su tiempo para hacer la tarea. Tienes un lugar disponible.');
    perform public.avisar_lista_espera(r.nivel_id);
    v_retirados := v_retirados + 1;
  end loop;

  -- (b) A las horas_aviso sin tarea hecha: aviso (una sola vez)
  for r in
    select p.id, p.user_id, p.reservada_en, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.origen = 'automatico' and p.posicion like 'regalador%'
      and p.estado = 'reservada' and p.tarea_hecha_en is null
      and not p.aviso_enviado
      and p.reservada_en + v_aviso <= now()
    for update of p skip locked
  loop
    update public.posiciones set aviso_enviado = true where id = r.id;
    perform public.notificar(r.user_id, 'Se acaba tu tiempo',
      format('Te quedan unos %s para hacer tu tarea del nivel %s. Escribe al recibidor por WhatsApp y márcala como hecha o perderás tu lugar.',
             public.texto_duracion(r.reservada_en + v_tarea - now()), r.nivel));
    v_avisos := v_avisos + 1;
  end loop;

  -- (c) Constructor: días del nivel desde ascendido_en con menos de 2 invitados con posición
  for r in
    select p.id, p.user_id, p.nivel_id, n.nombre as nivel, pe.nombre_usuario, pe.invitado_por
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    join public.perfiles pe on pe.id = p.user_id
    where p.posicion like 'constructor%'
      and p.ascendido_en is not null
      and p.estado is null
      and p.ascendido_en + public.dias_invitar_de(p.nivel_id) <= now()
      and public.contar_invitados(p.user_id, p.nivel_id) < 2
    for update of p skip locked
  loop
    update public.posiciones set estado = 'plazo_vencido' where id = r.id;
    perform public.notificar(r.user_id, 'Plazo vencido',
      format('Pasaron %s desde que subiste a constructor y no completaste tus 2 invitados en el nivel %s. Tu posición quedó suspendida y quien te invitó puede reemplazarte.',
             public.texto_dias_invitar(r.nivel_id), r.nivel));
    perform public.notificar(r.invitado_por, 'Tu invitado tiene el plazo vencido',
      format('%s no completó sus 2 invitados a tiempo en el nivel %s. En Mi grupo puedes usar "Retirar y reemplazar" para poner a alguien que invitaste y esté en lista de espera.',
             r.nombre_usuario, r.nivel));
    perform public.notificar_admins('Plazo vencido',
      format('%s (constructor, nivel %s) no completó sus 2 invitados a tiempo.', r.nombre_usuario, r.nivel));
    v_vencidos := v_vencidos + 1;
  end loop;

  return jsonb_build_object('retirados', v_retirados, 'avisos', v_avisos, 'plazos_vencidos', v_vencidos);
end;
$$;

-- =====================================================================
-- 4. retirar_y_reemplazar y admin_quitar_posicion: avisan al patrocinador
-- =====================================================================
create or replace function public.retirar_y_reemplazar(p_posicion_id uuid, p_nuevo_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo           uuid := (select auth.uid());
  v_pos          public.posiciones;
  v_invitador    uuid;
  v_es_invitador boolean;
  v_retirado     uuid;
  v_nivel        text;
begin
  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla ya está libre.';
  end if;

  v_retirado := v_pos.user_id;
  select invitado_por into v_invitador from public.perfiles where id = v_retirado;
  v_es_invitador := v_invitador is not null and v_invitador = v_yo;

  if not (public.es_admin() or v_es_invitador) then
    raise exception 'Solo el administrador o quien invitó a esta persona puede retirarla.';
  end if;
  if not v_es_invitador and v_pos.estado is distinct from 'plazo_vencido' then
    raise exception 'Solo se puede retirar a alguien cuando su plazo está vencido.';
  end if;
  if v_invitador is null then
    raise exception 'Esta persona no tiene invitador. Usa "Reemplazar" en la pestaña Grupos.';
  end if;

  if p_nuevo_user_id is null or p_nuevo_user_id = v_retirado then
    raise exception 'Elige a otra persona para el reemplazo.';
  end if;
  if not exists (select 1 from public.perfiles where id = p_nuevo_user_id and invitado_por = v_invitador) then
    raise exception 'La persona nueva debe ser alguien invitado por quien invitó a la persona retirada.';
  end if;
  if not exists (select 1 from public.lista_espera where user_id = p_nuevo_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'La persona nueva debe estar en la lista de espera de este nivel.';
  end if;
  if exists (select 1 from public.posiciones where user_id = p_nuevo_user_id and nivel_id = v_pos.nivel_id) then
    raise exception 'La persona nueva ya tiene una posición en este nivel.';
  end if;

  perform public.liberar_posicion(p_posicion_id, 'retirada');
  perform public.ocupar_posicion(p_posicion_id, p_nuevo_user_id, true);

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;

  perform public.notificar(v_retirado, 'Fuiste retirado de tu posición',
    format('Saliste de la posición %s del nivel %s y tu lugar fue asignado a otra persona.',
           public.nombre_posicion(v_pos.posicion), v_nivel));
  perform public.notificar_lugar(p_nuevo_user_id, v_pos.posicion, v_nivel,
    format('Te colocaron como %s en el nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));

  -- Si lo hizo el administrador, el patrocinador se entera
  if not v_es_invitador then
    perform public.avisar_patrocinador(v_retirado, v_pos.posicion, v_pos.nivel_id,
      format('fue retirado por plazo vencido y su lugar lo ocupa %s.',
             (select nombre_usuario from public.perfiles where id = p_nuevo_user_id)));
  end if;
end;
$$;

create or replace function public.admin_quitar_posicion(p_posicion_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posiciones;
  v_nivel text;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede quitar posiciones.';
  end if;

  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla ya está libre.';
  end if;

  perform public.liberar_posicion(p_posicion_id, null);

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  perform public.notificar(v_pos.user_id, 'Saliste de tu posición',
    format('El administrador te quitó de la posición %s del nivel %s.', public.nombre_posicion(v_pos.posicion), v_nivel));
  perform public.avisar_patrocinador(v_pos.user_id, v_pos.posicion, v_pos.nivel_id,
    'salió de su posición. Tienes un lugar disponible.');
  perform public.avisar_lista_espera(v_pos.nivel_id);
end;
$$;

-- =====================================================================
-- 5. SALIR DE LA RED (borra la cuenta)
-- =====================================================================
create or replace function public.salir_de_la_red()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo      uuid := (select auth.uid());
  v_perfil  public.perfiles;
  r         record;
  v_rec     uuid;
  v_cuantas int := 0;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  -- (a)
  if public.es_admin() then
    raise exception 'Un administrador no puede eliminar su cuenta desde aquí.';
  end if;

  select * into v_perfil from public.perfiles where id = v_yo for update;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  -- (b) Recibidor de un grupo activo con otras personas
  if exists (
    select 1
    from public.posiciones yo
    join public.grupos g on g.id = yo.grupo_id and g.estado = 'activo'
    where yo.user_id = v_yo and yo.posicion = 'recibidor'
      and exists (select 1 from public.posiciones o
                  where o.grupo_id = yo.grupo_id and o.user_id is not null and o.user_id <> v_yo)
  ) then
    raise exception 'Eres el recibidor de un grupo activo. Pide ayuda al administrador.';
  end if;

  -- (c) (d) (e) Libera cada posición ANTES de borrar la cuenta y avisa
  for r in
    select p.id, p.grupo_id, p.posicion, p.nivel_id, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = v_yo
    for update of p
  loop
    perform public.liberar_posicion(r.id, 'retirada');
    perform public.avisar_patrocinador(v_yo, r.posicion, r.nivel_id, 'se retiró. Tienes un lugar disponible.');
    v_rec := public.recibidor_de_grupo(r.grupo_id);
    if v_rec is not null and v_rec <> v_yo then
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

  -- (f) Borra la cuenta: perfiles, notificaciones, lista de espera y ciclos se borran en
  -- cascada; sus invitados quedan con invitado_por nulo. Como el perfil ya no existe,
  -- contar_referidos() deja de contarlo y el link de su patrocinador recupera el cupo.
  delete from auth.users where id = v_yo;
end;
$$;

-- =====================================================================
-- 6. RLS Y GRANTs
-- =====================================================================
alter table public.dias_invitar_nivel enable row level security;

drop policy if exists "dias_invitar_nivel: leer con sesión" on public.dias_invitar_nivel;
create policy "dias_invitar_nivel: leer con sesión"
  on public.dias_invitar_nivel for select to authenticated using (true);

revoke all on table public.dias_invitar_nivel from anon, authenticated;
grant select on table public.dias_invitar_nivel to authenticated;   -- se escribe solo con admin_guardar_dias_nivel

-- Internas
revoke execute on function public.dias_invitar_valor(integer)                   from public, anon, authenticated;
revoke execute on function public.dias_invitar_de(integer)                      from public, anon, authenticated;
revoke execute on function public.texto_dias_invitar(integer)                   from public, anon, authenticated;
revoke execute on function public.lado_posicion(text)                           from public, anon, authenticated;
revoke execute on function public.avisar_patrocinador(uuid, text, integer, text) from public, anon, authenticated;
revoke execute on function public.notificar_lugar(uuid, text, text, text)       from public, anon, authenticated;
revoke execute on function public.ascender_grupo(uuid)                          from public, anon, authenticated;
revoke execute on function public.revisar_plazos()                              from public, anon, authenticated;

-- Para la web (solo con sesión)
revoke execute on function public.admin_guardar_dias_nivel(integer, numeric)    from public, anon;
revoke execute on function public.salir_de_la_red()                             from public, anon;
revoke execute on function public.confirmar_tarea(uuid)                         from public, anon;
revoke execute on function public.mi_reloj(integer)                             from public, anon;
revoke execute on function public.retirar_y_reemplazar(uuid, uuid)              from public, anon;
revoke execute on function public.admin_quitar_posicion(uuid)                   from public, anon;

grant execute on function public.admin_guardar_dias_nivel(integer, numeric)    to authenticated;
grant execute on function public.salir_de_la_red()                             to authenticated;
grant execute on function public.confirmar_tarea(uuid)                         to authenticated;
grant execute on function public.mi_reloj(integer)                             to authenticated;
grant execute on function public.retirar_y_reemplazar(uuid, uuid)              to authenticated;
grant execute on function public.admin_quitar_posicion(uuid)                   to authenticated;

notify pgrst, 'reload schema';
