-- !! OBSOLETO desde 25_repetir_nivel.sql: NO volver a ejecutar este archivo (crea las vueltas que el 25 quita).
--    Se deja solo como historial. Su contenido vigente (sin vueltas) está en el 25.
-- =====================================================================
-- Sistema Siembra tu Futuro — 23_reserva_referidos.sql
-- Ejecutar DESPUÉS de 22_seguir_en_vuelta_nueva.sql. Se puede volver a ejecutar sin problema.
-- Si re-ejecutas 15, 18, 19, 20, 21 o 22, vuelve a ejecutar este archivo después.
--
-- Regla del cliente: el enlace YA NO tiene límite de registros.
--   * En cada vuelta del patrocinador, sus 2 primeros seguidores son REFERIDOS ACTIVOS (como
--     antes: invitados de esa vuelta + socios de vueltas anteriores que volvieron con él).
--   * Del 3.º en adelante quedan en su RESERVA, en orden de llegada, "Pendiente de posición"
--     (perfiles.referido_estado = 'reserva').
--   * Cuando se libera uno de los 2 lugares, el 1.º de la reserva lo toma AUTOMÁTICAMENTE
--     (promover_reserva): recibe un mensaje y, si la casilla que quedó libre es de regalador
--     del primer nivel, la ocupa con su plazo de la tarea (horas_tarea, 4 h). Se libera cuando:
--       - el patrocinador ELIMINA a uno de sus 2 referidos activos (eliminar_referido); solo
--         puede eliminar activos que todavía son regaladores (no constructores ni recibidores);
--       - el referido SALE de la red (borrar_cuenta_participante);
--       - al referido se le VENCE el plazo de su tarea (revisar_plazos): si hay alguien en la
--         reserva, el vencido pasa al final de la reserva y el 1.º toma su casilla.
--   * La persona en reserva puede "Entrar por derrame" (participar en el nivel 1): sale de la
--     reserva (estado 'derrame') y ya no sigue a su patrocinador. Lo mismo quien fue eliminado.
-- =====================================================================

-- =====================================================================
-- 1. ESTADO DEL REFERIDO
-- =====================================================================
alter table public.perfiles add column if not exists referido_estado text not null default 'activo';
alter table public.perfiles add column if not exists reserva_desde timestamptz;
alter table public.perfiles drop constraint if exists perfiles_referido_estado_chk;
alter table public.perfiles add constraint perfiles_referido_estado_chk
  check (referido_estado in ('activo', 'reserva', 'eliminado', 'derrame'));
create index if not exists perfiles_reserva_idx
  on public.perfiles (invitado_por, invitado_vuelta, reserva_desde)
  where referido_estado = 'reserva';

-- =====================================================================
-- 2. CONTEOS (solo cuentan los referidos ACTIVOS)
-- =====================================================================
create or replace function public.contar_seguidores(p_user_id uuid, p_vuelta integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select ((select count(*) from public.perfiles r
            where r.invitado_por = p_user_id and coalesce(r.invitado_vuelta, 1) = coalesce(p_vuelta, 1)
              and r.referido_estado = 'activo')
        + (select count(*) from public.seguimientos s
            where s.patrocinador_id = p_user_id and s.vuelta_patrocinador = coalesce(p_vuelta, 1)))::int;
$$;

create or replace function public.contar_invitados_vuelta(p_user_id uuid, p_nivel_id integer, p_vuelta integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select ((select count(*) from public.perfiles pe
            where pe.invitado_por = p_user_id and coalesce(pe.invitado_vuelta, 1) = coalesce(p_vuelta, 1)
              and pe.referido_estado = 'activo'
              and exists (select 1 from public.posiciones po
                          where po.user_id = pe.id and po.nivel_id = p_nivel_id and po.vuelta = 1))
        + (select count(*) from public.seguimientos s
            where s.patrocinador_id = p_user_id and s.vuelta_patrocinador = coalesce(p_vuelta, 1)
              and exists (select 1 from public.posiciones po
                          where po.user_id = s.user_id and po.nivel_id = p_nivel_id and po.vuelta = s.vuelta)))::int;
$$;

-- La vuelta 1 de una persona sigue a quien la invitó solo si es su referido ACTIVO
create or replace function public.patrocinador_en_vuelta(p_user_id uuid, p_vuelta integer,
  out patrocinador uuid, out vuelta_patrocinador integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  select s.patrocinador_id, s.vuelta_patrocinador into patrocinador, vuelta_patrocinador
  from public.seguimientos s where s.user_id = p_user_id and s.vuelta = p_vuelta;
  if patrocinador is null and p_vuelta = 1 then
    select pe.invitado_por, coalesce(pe.invitado_vuelta, 1) into patrocinador, vuelta_patrocinador
    from public.perfiles pe
    where pe.id = p_user_id and pe.invitado_por is not null and pe.referido_estado = 'activo';
  end if;
end;
$$;

-- El enlace ya no se cierra: si el código existe, se puede registrar (activo o en reserva)
create or replace function public.referido_disponible(p_codigo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.perfiles p
    where p.codigo_invitacion = upper(trim(coalesce(p_codigo, '')))
  );
$$;

-- =====================================================================
-- 3. ALTA: activo si hay lugar, si no a la reserva (ya no se rechaza)
-- =====================================================================
create or replace function public.limitar_referidos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vuelta integer;
begin
  if new.invitado_por is null then
    new.invitado_vuelta := null;
    new.referido_estado := 'activo';
    new.reserva_desde := null;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.invitado_por is not distinct from old.invitado_por then
    return new;
  end if;

  -- Bloquea al patrocinador (dos registros a la vez no toman el mismo lugar)
  select vuelta_actual into v_vuelta from public.perfiles where id = new.invitado_por for update;
  new.invitado_vuelta := coalesce(v_vuelta, 1);

  if public.contar_seguidores(new.invitado_por, new.invitado_vuelta) >= 2 then
    new.referido_estado := 'reserva';
    new.reserva_desde := now();
  else
    new.referido_estado := 'activo';
    new.reserva_desde := null;
  end if;
  return new;
end;
$$;

-- =====================================================================
-- 4. EL 1.º DE LA RESERVA TOMA EL LUGAR LIBRE
-- =====================================================================
-- p_casilla: la casilla que quedó libre (si es regalador del primer nivel, la ocupa el que entra)
create or replace function public.promover_reserva(p_patrocinador uuid, p_vuelta integer, p_casilla uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  r         record;
  v_pos     public.posiciones;
  v_nivel   text;
  v_ultimo  uuid;
  v_casilla uuid := p_casilla;
  v_rec     uuid;
begin
  if p_patrocinador is null then
    return null;
  end if;
  loop
    exit when public.contar_seguidores(p_patrocinador, p_vuelta) >= 2;

    select pe.id, pe.nombre_usuario, pe.vuelta_actual into r
    from public.perfiles pe
    where pe.invitado_por = p_patrocinador and coalesce(pe.invitado_vuelta, 1) = p_vuelta
      and pe.referido_estado = 'reserva'
    order by coalesce(pe.reserva_desde, pe.creado_en), pe.id
    limit 1
    for update skip locked;
    exit when not found;

    update public.perfiles set referido_estado = 'activo', reserva_desde = null where id = r.id;
    v_ultimo := r.id;

    -- La casilla libre (solo para el primero que entra), si es regalador del primer nivel
    v_pos := null;
    if v_casilla is not null then
      select p.* into v_pos
      from public.posiciones p
      join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
      where p.id = v_casilla and p.user_id is null and p.posicion like 'regalador%'
        and public.nivel_anterior(p.nivel_id) is null
        and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = r.id)
        and not exists (select 1 from public.posiciones x
                        where x.user_id = r.id and x.nivel_id = p.nivel_id and x.vuelta = r.vuelta_actual)
      for update of p skip locked;
      v_casilla := null;
    end if;

    if v_pos.id is not null then
      perform public.ocupar_posicion(v_pos.id, r.id, true, r.vuelta_actual);
      select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
      perform public.notificar(r.id, 'Ya tienes tu lugar',
        format('Se liberó un lugar de tu patrocinador y lo tomaste automáticamente: %s en el nivel %s. Tienes %s para hacer tu tarea, escribir al recibidor y marcarla como hecha.',
               public.nombre_posicion(v_pos.posicion), v_nivel, public.texto_duracion(public.intervalo_config('horas_tarea'))));
      v_rec := public.recibidor_de_grupo(v_pos.grupo_id);
      if v_rec is not null and v_rec <> r.id then
        perform public.notificar(v_rec, 'Nueva persona en tu grupo',
          format('%s entró a tu grupo del nivel %s como %s.', r.nombre_usuario, v_nivel, public.nombre_posicion(v_pos.posicion)));
      end if;
    else
      perform public.notificar(r.id, 'Ya eres referido activo',
        'Se liberó un lugar de tu patrocinador y ya no estás en espera. Ve a Niveles y toca Participar para entrar en su grupo.');
    end if;

    perform public.notificar(p_patrocinador, 'Entró una persona de tu lista de espera',
      format('%s salió de tu lista de espera y ocupa uno de tus 2 lugares de la vuelta %s.', r.nombre_usuario, p_vuelta));
  end loop;
  return v_ultimo;
end;
$$;

-- Al vencer el plazo de un regalador que es referido activo: si hay alguien en la reserva de
-- su patrocinador, el vencido pasa al final de la reserva y el 1.º toma la casilla libre.
create or replace function public.reserva_tras_vencer(p_user_id uuid, p_vuelta_pos integer, p_casilla uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_perfil public.perfiles;
  v_pat    uuid;
  v_vp     integer;
  v_socio  boolean := false;
  v_n      integer;
begin
  select * into v_perfil from public.perfiles where id = p_user_id;
  if not found then
    return;
  end if;
  if coalesce(p_vuelta_pos, 1) = 1 and v_perfil.invitado_por is not null and v_perfil.referido_estado = 'activo' then
    v_pat := v_perfil.invitado_por;
    v_vp  := coalesce(v_perfil.invitado_vuelta, 1);
  else
    select s.patrocinador_id, s.vuelta_patrocinador into v_pat, v_vp
    from public.seguimientos s where s.user_id = p_user_id and s.vuelta = p_vuelta_pos;
    v_socio := v_pat is not null;
  end if;
  if v_pat is null then
    return;
  end if;
  -- Sin nadie en la reserva todo sigue igual (puede volver a tocar Participar)
  if not exists (select 1 from public.perfiles pe
                 where pe.invitado_por = v_pat and coalesce(pe.invitado_vuelta, 1) = v_vp
                   and pe.referido_estado = 'reserva' and pe.id <> p_user_id) then
    return;
  end if;

  if v_socio then
    delete from public.seguimientos where user_id = p_user_id and vuelta = p_vuelta_pos;
    perform public.notificar(p_user_id, 'Dejaste tu lugar',
      'Se venció tu plazo y tu lugar pasó a otra persona. Puedes volver a participar desde Niveles.');
  else
    update public.perfiles set referido_estado = 'reserva', reserva_desde = now() where id = p_user_id;
    select count(*) into v_n from public.perfiles pe
    where pe.invitado_por = v_pat and coalesce(pe.invitado_vuelta, 1) = v_vp and pe.referido_estado = 'reserva';
    perform public.notificar(p_user_id, 'Pasaste a la lista de espera',
      format('Se venció tu plazo y tu lugar pasó a la siguiente persona en espera. Ahora eres el %s en espera de tu patrocinador. También puedes entrar por derrame desde Niveles.', v_n));
  end if;

  perform public.promover_reserva(v_pat, v_vp, p_casilla);
end;
$$;

-- =====================================================================
-- 5. EL PATROCINADOR ELIMINA A UNO DE SUS 2 REFERIDOS ACTIVOS
-- =====================================================================
create or replace function public.eliminar_referido(p_user_id uuid, p_vuelta integer default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo         uuid := (select auth.uid());
  v_ref        public.perfiles;
  v_vuelta_pat integer;
  v_vuelta_ref integer;
  v_tipo       text;
  r            record;
  v_casilla    uuid;
  v_rec        uuid;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  -- Bloquea mi perfil (y con él mis lugares) mientras se hace el cambio
  perform 1 from public.perfiles where id = v_yo for update;

  select * into v_ref from public.perfiles where id = p_user_id for update;
  if not found then
    raise exception 'No se encontró esa persona.';
  end if;

  if v_ref.invitado_por = v_yo and v_ref.referido_estado = 'activo'
     and (p_vuelta is null or coalesce(v_ref.invitado_vuelta, 1) = p_vuelta) then
    v_tipo := 'invitado';
    v_vuelta_pat := coalesce(v_ref.invitado_vuelta, 1);
    v_vuelta_ref := 1;
  else
    select s.vuelta_patrocinador, s.vuelta into v_vuelta_pat, v_vuelta_ref
    from public.seguimientos s
    where s.user_id = p_user_id and s.patrocinador_id = v_yo
      and (p_vuelta is null or s.vuelta_patrocinador = p_vuelta)
    order by s.vuelta_patrocinador desc
    limit 1;
    if v_vuelta_pat is null then
      if v_ref.invitado_por = v_yo and v_ref.referido_estado = 'reserva' then
        raise exception 'Esa persona está en tu lista de espera. Solo puedes eliminar a tus 2 referidos activos.';
      end if;
      raise exception 'Esa persona no es uno de tus 2 referidos activos.';
    end if;
    v_tipo := 'socio';
  end if;

  if exists (select 1 from public.posiciones
             where user_id = p_user_id and vuelta = v_vuelta_ref and posicion not like 'regalador%') then
    raise exception 'No puedes eliminar a % porque ya es constructor o recibidor. Si necesitas ayuda, escribe a Soporte.', v_ref.nombre_usuario;
  end if;

  -- Libera sus casillas de regalador de esa vuelta (la del primer nivel la toma el 1.º en espera)
  for r in
    select p.id, p.grupo_id, p.posicion, p.nivel_id, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = p_user_id and p.vuelta = v_vuelta_ref
    order by n.orden
    for update of p
  loop
    perform public.liberar_posicion(r.id, 'retirada');
    if v_casilla is null then
      v_casilla := r.id;
    end if;
    v_rec := public.recibidor_de_grupo(r.grupo_id);
    if v_rec is not null and v_rec <> p_user_id then
      perform public.notificar(v_rec, 'Alguien salió de tu grupo',
        format('%s dejó la posición %s de tu grupo del nivel %s.', v_ref.nombre_usuario, public.nombre_posicion(r.posicion), r.nivel));
    end if;
  end loop;
  delete from public.lista_espera where user_id = p_user_id and vuelta = v_vuelta_ref;

  if v_tipo = 'invitado' then
    update public.perfiles set referido_estado = 'eliminado', reserva_desde = null where id = p_user_id;
  else
    delete from public.seguimientos where user_id = p_user_id and vuelta = v_vuelta_ref;
  end if;

  perform public.notificar(p_user_id, 'Ya no eres referido activo',
    format('%s te quitó de sus 2 referidos de su vuelta %s. Puedes seguir participando: en Niveles toca "Entrar por derrame".',
           (select nombre_usuario from public.perfiles where id = v_yo), v_vuelta_pat));

  perform public.promover_reserva(v_yo, v_vuelta_pat, v_casilla);
  return v_ref.nombre_usuario;
end;
$$;

-- =====================================================================
-- 6. SALIR DE LA RED: libera el lugar y entra el 1.º en espera
-- =====================================================================
create or replace function public.borrar_cuenta_participante(p_user_id uuid, p_por_admin boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_perfil   public.perfiles;
  r          record;
  v_rec      uuid;
  v_cuantas  int := 0;
  v_pats     uuid[] := '{}';
  v_vps      integer[] := '{}';
  v_vrs      integer[] := '{}';
  v_lib_ids  uuid[] := '{}';
  v_lib_vs   integer[] := '{}';
  i          integer;
  j          integer;
  v_casilla  uuid;
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

  -- (23) Lugares de patrocinador que deja libres: como referido activo y como socio que volvió
  if v_perfil.invitado_por is not null and v_perfil.referido_estado = 'activo' then
    v_pats := v_pats || v_perfil.invitado_por;
    v_vps  := v_vps  || coalesce(v_perfil.invitado_vuelta, 1);
    v_vrs  := v_vrs  || 1;
  end if;
  for r in select s.patrocinador_id, s.vuelta_patrocinador, s.vuelta from public.seguimientos s where s.user_id = p_user_id loop
    v_pats := v_pats || r.patrocinador_id;
    v_vps  := v_vps  || r.vuelta_patrocinador;
    v_vrs  := v_vrs  || r.vuelta;
  end loop;

  -- Libera cada posición ANTES de borrar la cuenta y avisa
  for r in
    select p.id, p.grupo_id, p.posicion, p.nivel_id, p.vuelta, n.nombre as nivel
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    where p.user_id = p_user_id
    order by n.orden
    for update of p
  loop
    perform public.liberar_posicion(r.id, 'retirada');
    v_lib_ids := v_lib_ids || r.id;
    v_lib_vs  := v_lib_vs  || r.vuelta;
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

  -- Sin posiciones: igual se avisa al patrocinador (se libera un lugar)
  if v_cuantas = 0 and v_perfil.invitado_por is not null and v_perfil.referido_estado = 'activo' then
    perform public.notificar(v_perfil.invitado_por, 'Tu socio se retiró',
      format('Tu socio %s se retiró de la plataforma. Se liberó uno de tus 2 lugares.', v_perfil.nombre_usuario));
  end if;

  -- Borra la cuenta (perfiles, notificaciones, lista de espera, ciclos y seguimientos en cascada)
  delete from auth.users where id = p_user_id;

  -- (23) En cada lugar que dejó, entra el 1.º en espera de ese patrocinador
  for i in 1 .. coalesce(array_length(v_pats, 1), 0) loop
    v_casilla := null;
    for j in 1 .. coalesce(array_length(v_lib_ids, 1), 0) loop
      if v_lib_vs[j] = v_vrs[i] then
        v_casilla := v_lib_ids[j];
        exit;
      end if;
    end loop;
    perform public.promover_reserva(v_pats[i], v_vps[i], v_casilla);
  end loop;

  return v_perfil.nombre_usuario;
end;
$$;

-- =====================================================================
-- 7. PLAZOS: al vencer la tarea de un referido activo entra el 1.º en espera
-- =====================================================================
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
    select p.id, p.user_id, p.posicion, p.nivel_id, p.vuelta, n.nombre as nivel
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
    -- (23) Si su patrocinador tiene gente en espera, el 1.º toma esta casilla
    perform public.reserva_tras_vencer(r.user_id, r.vuelta, r.id);
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

  -- (c) Constructor: días del nivel desde ascendido_en con menos de 2 invitados (de su vuelta) con posición
  for r in
    select p.id, p.user_id, p.nivel_id, n.nombre as nivel, pe.nombre_usuario, pe.invitado_por
    from public.posiciones p
    join public.niveles n on n.id = p.nivel_id
    join public.perfiles pe on pe.id = p.user_id
    where p.posicion like 'constructor%'
      and p.ascendido_en is not null
      and p.estado is null
      and p.ascendido_en + public.dias_invitar_de(p.nivel_id) <= now()
      and public.contar_invitados_vuelta(p.user_id, p.nivel_id, p.vuelta) < 2
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
-- 8. PARTICIPAR: quien está en espera (o fue eliminado) entra por derrame
-- =====================================================================
create or replace function public.participar(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo          uuid := (select auth.uid());
  v_nivel       public.niveles;
  v_perfil      public.perfiles;
  v_pos_inv     public.posiciones;
  v_libre       public.posiciones;
  v_grupo       uuid;
  v_recibidor   uuid;
  v_primero     boolean;
  v_vuelta      integer;
  v_repite      boolean;
  v_nueva       boolean := false;
  v_derrame     boolean := false;
  v_cand        record;
  v_pat         uuid;
  v_pat_vuelta  integer;
  v_preferencia boolean := false;
  v_sin_pat     boolean;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;

  select * into v_nivel from public.niveles where id = p_nivel_id;
  if not found then
    raise exception 'El nivel elegido no existe.';
  end if;

  -- Bloquea mi perfil: evita que un doble toque me coloque dos veces
  select * into v_perfil from public.perfiles where id = v_yo for update;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  -- (23) En espera o eliminado: no sigue a su patrocinador; entra por derrame
  v_sin_pat := v_perfil.invitado_por is not null and v_perfil.referido_estado in ('reserva', 'eliminado');

  v_primero := public.nivel_anterior(p_nivel_id) is null;
  v_vuelta  := public.vuelta_para_participar(v_yo, p_nivel_id);

  if v_vuelta is null then
    if v_primero then
      if exists (select 1 from public.lista_espera where user_id = v_yo and nivel_id = p_nivel_id and vuelta = v_perfil.vuelta_actual) then
        raise exception 'Ya estás en la lista de espera de este nivel.';
      end if;
      raise exception 'Ya tienes una posición en este nivel en tu vuelta %. Cuando lo completes podrás empezar una vuelta nueva.', v_perfil.vuelta_actual;
    end if;
    if not public.nivel_habilitado(v_yo, p_nivel_id) then
      raise exception 'Este nivel todavía no está habilitado para ti. Primero completa el nivel anterior.';
    end if;
    raise exception 'Ya participas en este nivel en todas tus vueltas habilitadas. Completa el nivel anterior en otra vuelta para volver a entrar.';
  end if;

  v_repite := exists (select 1 from public.ciclos_completados where user_id = v_yo and nivel_id = p_nivel_id);

  if v_vuelta > v_perfil.vuelta_actual then
    update public.perfiles set vuelta_actual = v_vuelta where id = v_yo;
    v_nueva := true;
  end if;

  if not v_nueva and not v_sin_pat then
    select x.patrocinador, x.vuelta_patrocinador into v_pat, v_pat_vuelta
    from public.patrocinador_en_vuelta(v_yo, v_vuelta) x;
  end if;

  if not v_primero and v_perfil.es_fundador then
    v_grupo := public.crear_grupo_vacio(p_nivel_id);
    select * into v_libre from public.posiciones where grupo_id = v_grupo and posicion = 'recibidor';
  else
    if v_nueva and v_perfil.invitado_por is not null and v_perfil.referido_estado = 'activo' then
      -- (22) PREFERENCIA: vuelta nueva en el nivel 1 y mi patrocinador es constructor ahí
      select p.* into v_libre
      from public.posiciones c
      join public.grupos g on g.id = c.grupo_id and g.estado = 'activo'
      join public.posiciones p on p.grupo_id = c.grupo_id and p.cuelga_de = c.posicion and p.user_id is null
      where c.user_id = v_perfil.invitado_por and c.nivel_id = p_nivel_id
        and c.posicion like 'constructor%'
        and c.estado is distinct from 'plazo_vencido'
        and not exists (select 1 from public.posiciones yo where yo.grupo_id = c.grupo_id and yo.user_id = v_yo)
      order by c.vuelta desc, p.posicion
      limit 1
      for update of p skip locked;
      if v_libre.id is not null then
        v_pat := v_perfil.invitado_por;
        select c.vuelta into v_pat_vuelta from public.posiciones c
        where c.grupo_id = v_libre.grupo_id and c.posicion = v_libre.cuelga_de;
        v_preferencia := true;
      end if;
    elsif v_pat is not null then
      select po.* into v_pos_inv
      from public.posiciones po
      join public.grupos g on g.id = po.grupo_id and g.estado = 'activo'
      where po.user_id = v_pat and po.nivel_id = p_nivel_id and po.vuelta = v_pat_vuelta
      limit 1;

      if v_pos_inv.id is not null then
        if v_primero then
          select p.* into v_libre
          from public.posiciones p
          where p.grupo_id = v_pos_inv.grupo_id
            and p.user_id is null
            and p.posicion like 'regalador%'
            and (p.cuelga_de = v_pos_inv.posicion or not public.lugar_guardado(p.grupo_id, p.cuelga_de))
            and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
          order by (p.cuelga_de = v_pos_inv.posicion) desc,
                   array_position(array['regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], p.posicion)
          limit 1
          for update skip locked;
        elsif v_pos_inv.posicion = 'recibidor' then
          select p.* into v_libre
          from public.posiciones p
          where p.grupo_id = v_pos_inv.grupo_id
            and p.user_id is null
            and p.posicion in ('constructor_1', 'constructor_2')
            and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
          order by p.posicion
          limit 1
          for update skip locked;
        elsif v_pos_inv.posicion like 'constructor%' then
          select p.* into v_libre
          from public.posiciones p
          where p.grupo_id = v_pos_inv.grupo_id
            and p.user_id is null
            and p.cuelga_de = v_pos_inv.posicion
            and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
          order by p.posicion
          limit 1
          for update skip locked;
        end if;
      end if;
    end if;

    -- Derrame (21): 0 = constructor con plazo vencido; 1 = constructor que no espera
    -- seguidores; 2 = al final, los lugares que un constructor guarda para sus seguidores.
    if v_libre.id is null and (v_repite or v_primero) then
      for v_cand in
        select lib.id
        from public.grupos g
        cross join lateral (
          select p.id, p.posicion,
                 c.user_id as c_user, c.estado as c_estado, c.ascendido_en as c_ascendido,
                 c.nivel_id as c_nivel, c.vuelta as c_vuelta
          from public.posiciones p
          join public.posiciones c
            on c.grupo_id = p.grupo_id and c.posicion = p.cuelga_de and c.user_id is not null
          where p.grupo_id = g.id and p.user_id is null and p.posicion like 'regalador%'
          offset 0
        ) lib
        where g.nivel_id = p_nivel_id and g.estado = 'activo'
          and not exists (select 1 from public.posiciones yo where yo.grupo_id = g.id and yo.user_id = v_yo)
        order by case
                   when lib.c_estado = 'plazo_vencido' then 0
                   when lib.c_ascendido is null
                     or public.contar_invitados_vuelta(lib.c_user, lib.c_nivel, lib.c_vuelta) >= 2 then 1
                   else 2
                 end,
                 g.creado_en, g.id, lib.posicion
      loop
        select p.* into v_libre
        from public.posiciones p
        where p.id = v_cand.id and p.user_id is null
        for update skip locked;
        exit when v_libre.id is not null;
      end loop;
      v_derrame := v_libre.id is not null;
    end if;
  end if;

  if v_nueva then
    perform public.notificar(v_yo, 'Empezaste la vuelta ' || v_vuelta,
      format('Volviste al nivel %s y empezaste tu vuelta %s. En esta vuelta tus 2 primeros referidos son activos (las personas que invites y tus socios de vueltas anteriores que vuelvan contigo); los demás quedan en tu lista de espera.',
             v_nivel.nombre, v_vuelta));
  end if;

  if v_libre.id is null then
    insert into public.lista_espera (user_id, nivel_id, vuelta) values (v_yo, p_nivel_id, v_vuelta);
    perform public.notificar(v_yo, 'Estás en lista de espera',
      format('No hay un lugar libre para ti en el nivel %s (vuelta %s). El administrador te asignará un lugar.', v_nivel.nombre, v_vuelta));
    perform public.notificar_admins('Nueva persona en lista de espera',
      format('%s tocó Participar en el nivel %s (vuelta %s) y quedó en lista de espera.', v_perfil.nombre_usuario, v_nivel.nombre, v_vuelta));
    return jsonb_build_object('resultado', 'lista_espera', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                              'vuelta', v_vuelta, 'nueva_vuelta', v_nueva);
  end if;

  perform public.ocupar_posicion(v_libre.id, v_yo, true, v_vuelta);

  -- (23) Entró por derrame estando en espera: deja la lista de espera de su patrocinador
  if v_sin_pat then
    update public.perfiles set referido_estado = 'derrame', reserva_desde = null where id = v_yo;
    if v_perfil.referido_estado = 'reserva' then
      perform public.notificar(v_perfil.invitado_por, 'Una persona dejó tu lista de espera',
        format('%s entró por derrame y ya no está en tu lista de espera.', v_perfil.nombre_usuario));
    end if;
  end if;

  if v_preferencia then
    insert into public.seguimientos (user_id, vuelta, patrocinador_id, vuelta_patrocinador)
    values (v_yo, v_vuelta, v_pat, v_pat_vuelta)
    on conflict (user_id, vuelta) do update
      set patrocinador_id = excluded.patrocinador_id, vuelta_patrocinador = excluded.vuelta_patrocinador, creado_en = now();
    perform public.notificar(v_pat, 'Tu socio volvió contigo',
      format('%s volvió al nivel %s y ocupa uno de tus lugares de regalador (tu vuelta %s). Te seguirá en esa vuelta.',
             v_perfil.nombre_usuario, v_nivel.nombre, v_pat_vuelta));
  end if;

  perform public.notificar_lugar(v_yo, v_libre.posicion, v_nivel.nombre,
    case when v_libre.posicion = 'recibidor'
         then format('Como fundador creaste un grupo nuevo en el nivel %s (vuelta %s) y eres su recibidor.', v_nivel.nombre, v_vuelta)
         else format('Ocupas la posición %s en el nivel %s (vuelta %s).', public.nombre_posicion(v_libre.posicion), v_nivel.nombre, v_vuelta)
    end);

  v_recibidor := public.recibidor_de_grupo(v_libre.grupo_id);
  if v_recibidor is not null and v_recibidor <> v_yo then
    perform public.notificar(v_recibidor, 'Nueva persona en tu grupo',
      format('%s entró a tu grupo del nivel %s como %s.',
             v_perfil.nombre_usuario, v_nivel.nombre, public.nombre_posicion(v_libre.posicion)));
  end if;

  return jsonb_build_object('resultado', 'colocado', 'nivel_id', p_nivel_id, 'nivel', v_nivel.nombre,
                            'grupo_id', v_libre.grupo_id, 'posicion', v_libre.posicion,
                            'vuelta', v_vuelta, 'nueva_vuelta', v_nueva, 'derrame', v_derrame,
                            'con_patrocinador', v_preferencia);
end;
$$;

-- =====================================================================
-- 9. PARA LA PÁGINA
-- =====================================================================
-- Si estoy en la lista de espera de mi patrocinador: "Eres el N en espera"
create or replace function public.mi_reserva()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
  v_p  public.perfiles;
  v_n  integer;
begin
  select * into v_p from public.perfiles where id = v_yo;
  if not found or v_p.invitado_por is null or v_p.referido_estado not in ('reserva', 'eliminado') then
    return jsonb_build_object('estado', coalesce(v_p.referido_estado, 'activo'));
  end if;
  if v_p.referido_estado = 'reserva' then
    select count(*) + 1 into v_n
    from public.perfiles pe
    where pe.invitado_por = v_p.invitado_por and coalesce(pe.invitado_vuelta, 1) = coalesce(v_p.invitado_vuelta, 1)
      and pe.referido_estado = 'reserva'
      and (coalesce(pe.reserva_desde, pe.creado_en), pe.id) < (coalesce(v_p.reserva_desde, v_p.creado_en), v_p.id);
  end if;
  return jsonb_build_object(
    'estado',       v_p.referido_estado,
    'numero',       v_n,
    'patrocinador', (select nombre_usuario from public.perfiles where id = v_p.invitado_por),
    'vuelta',       coalesce(v_p.invitado_vuelta, 1),
    'desde',        coalesce(v_p.reserva_desde, v_p.creado_en),
    'plazo_tarea',  public.texto_duracion(public.intervalo_config('horas_tarea'))
  );
end;
$$;

-- Mis referidos por vuelta: los 2 activos y la lista de espera en orden
create or replace function public.mis_referidos_detalle()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_actual integer;
begin
  select vuelta_actual into v_actual from public.perfiles where id = v_yo;
  if v_actual is null then
    raise exception 'No se encontró tu perfil.';
  end if;

  return (
    select coalesce(jsonb_agg(x.obj order by x.v), '[]'::jsonb)
    from (
      select v.v,
             jsonb_build_object(
               'vuelta', v.v,
               'activos', (
                 select coalesce(jsonb_agg(a.obj order by a.desde), '[]'::jsonb)
                 from (
                   select pe.creado_en as desde,
                          jsonb_build_object('user_id', pe.id, 'nombre_usuario', pe.nombre_usuario,
                            'desde', pe.creado_en, 'tipo', 'invitado',
                            'posicion', (select jsonb_build_object('posicion', p.posicion, 'nivel', n.nombre)
                                         from public.posiciones p join public.niveles n on n.id = p.nivel_id
                                         where p.user_id = pe.id and p.vuelta = 1 order by n.orden desc limit 1)) as obj
                   from public.perfiles pe
                   where pe.invitado_por = v_yo and coalesce(pe.invitado_vuelta, 1) = v.v and pe.referido_estado = 'activo'
                   union all
                   select s.creado_en,
                          jsonb_build_object('user_id', pe.id, 'nombre_usuario', pe.nombre_usuario,
                            'desde', s.creado_en, 'tipo', 'socio',
                            'posicion', (select jsonb_build_object('posicion', p.posicion, 'nivel', n.nombre)
                                         from public.posiciones p join public.niveles n on n.id = p.nivel_id
                                         where p.user_id = pe.id and p.vuelta = s.vuelta order by n.orden desc limit 1))
                   from public.seguimientos s join public.perfiles pe on pe.id = s.user_id
                   where s.patrocinador_id = v_yo and s.vuelta_patrocinador = v.v
                 ) a
               ),
               'espera', (
                 select coalesce(jsonb_agg(jsonb_build_object('user_id', pe.id, 'nombre_usuario', pe.nombre_usuario,
                          'registrado', pe.creado_en, 'desde', coalesce(pe.reserva_desde, pe.creado_en))
                          order by coalesce(pe.reserva_desde, pe.creado_en), pe.id), '[]'::jsonb)
                 from public.perfiles pe
                 where pe.invitado_por = v_yo and coalesce(pe.invitado_vuelta, 1) = v.v and pe.referido_estado = 'reserva'
               )
             ) as obj
      from generate_series(1, v_actual) as v(v)
    ) x
    where x.v = v_actual
       or jsonb_array_length(x.obj -> 'activos') > 0
       or jsonb_array_length(x.obj -> 'espera') > 0
  );
end;
$$;

-- =====================================================================
-- 10. PERMISOS
-- =====================================================================
revoke execute on function public.contar_seguidores(uuid, integer)                 from public, anon, authenticated;
revoke execute on function public.contar_invitados_vuelta(uuid, integer, integer)  from public, anon, authenticated;
revoke execute on function public.patrocinador_en_vuelta(uuid, integer)            from public, anon, authenticated;
revoke execute on function public.limitar_referidos()                              from public, anon, authenticated;
revoke execute on function public.promover_reserva(uuid, integer, uuid)            from public, anon, authenticated;
revoke execute on function public.reserva_tras_vencer(uuid, integer, uuid)         from public, anon, authenticated;
revoke execute on function public.borrar_cuenta_participante(uuid, boolean)        from public, anon, authenticated;
revoke execute on function public.revisar_plazos()                                 from public, anon, authenticated;

revoke execute on function public.referido_disponible(text)                        from public;
grant  execute on function public.referido_disponible(text)                        to anon, authenticated;

revoke execute on function public.participar(integer)                              from public, anon;
revoke execute on function public.eliminar_referido(uuid, integer)                 from public, anon;
revoke execute on function public.mi_reserva()                                     from public, anon;
revoke execute on function public.mis_referidos_detalle()                          from public, anon;
grant  execute on function public.participar(integer)                              to authenticated;
grant  execute on function public.eliminar_referido(uuid, integer)                 to authenticated;
grant  execute on function public.mi_reserva()                                     to authenticated;
grant  execute on function public.mis_referidos_detalle()                          to authenticated;

notify pgrst, 'reload schema';
