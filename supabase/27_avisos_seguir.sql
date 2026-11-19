-- =====================================================================
-- 27_avisos_seguir.sql  (va DESPUÉS de 26_quitar_de_repeticion.sql)
-- "¡[patrocinador] volvió a sembrar!":
--   1) Cuando alguien (no fundador) repite un nivel inferior y entra como regalador, sus 2 referidos
--      (los 2 primeros que lo siguen en repeticiones) que pueden entrar a ese nivel reciben un aviso
--      (tabla avisos_seguir) y una notificación.
--   2) "Seguir a X en el nivel Y": queda anotado; cuando X sube a constructor en ese nivel, entra
--      automático debajo de él como regalador y empiezan sus 4 horas. Si X ya es constructor y tiene
--      un lugar libre, entra en el momento.
--   3) "Ahora no": se oculta de Inicio; el aviso sigue en Notificaciones y se puede aceptar después
--      desde Niveles. Mientras no acepte, el lugar lo puede tomar otra persona (derrame, la lista de
--      espera o un invitado nuevo de X).
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

-- =====================================================================
-- 1. TABLA
-- =====================================================================
create table if not exists public.avisos_seguir (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.perfiles (id) on delete cascade,   -- el referido
  patrocinador_id uuid not null references public.perfiles (id) on delete cascade,   -- quien volvió a sembrar
  nivel_id        integer not null references public.niveles (id),                   -- nivel que repite
  nivel_max_id    integer references public.niveles (id),                            -- nivel más alto que alcanzó
  estado          text not null default 'pendiente'
                  check (estado in ('pendiente', 'oculto', 'aceptado', 'cumplido', 'vencido')),
  creado_en       timestamptz not null default now(),
  respondido_en   timestamptz,
  constraint avisos_seguir_uk unique (user_id, patrocinador_id, nivel_id)
);
create index if not exists avisos_seguir_pat_idx on public.avisos_seguir (patrocinador_id, nivel_id, estado);
alter table public.avisos_seguir enable row level security;
revoke all on public.avisos_seguir from anon, authenticated;

-- =====================================================================
-- 2. FUNCIONES INTERNAS
-- =====================================================================
-- Texto "nivel 3 (Sembrar)"
create or replace function public.etiqueta_nivel(p_nivel_id integer)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select format('nivel %s (%s)', orden, nombre) from public.niveles where id = p_nivel_id;
$$;

-- Casilla libre de regalador debajo de p_pat si es constructor (sin plazo vencido) en ese nivel
create or replace function public.lugar_debajo_de(p_pat uuid, p_nivel_id integer)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
  from public.posiciones c
  join public.grupos g on g.id = c.grupo_id and g.estado = 'activo'
  join public.posiciones p on p.grupo_id = c.grupo_id and p.cuelga_de = c.posicion and p.user_id is null
  where c.user_id = p_pat and c.nivel_id = p_nivel_id and c.posicion like 'constructor%'
    and c.estado is distinct from 'plazo_vencido'
  order by p.posicion
  limit 1;
$$;

-- Avisa a los 2 referidos de quien volvió a entrar a un nivel inferior
create or replace function public.crear_avisos_seguir(p_pat uuid, p_nivel_id integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nivel   public.niveles;
  v_max     integer;
  v_nombre  text;
  s         record;
begin
  select * into v_nivel from public.niveles where id = p_nivel_id;
  select nombre_usuario into v_nombre from public.perfiles where id = p_pat;
  select n.id into v_max
  from public.niveles n
  where exists (select 1 from public.posiciones p where p.user_id = p_pat and p.nivel_id = n.id)
     or exists (select 1 from public.ciclos_completados c where c.user_id = p_pat and c.nivel_id = n.id)
  order by n.orden desc
  limit 1;

  for s in
    select f.id
    from public.seguidores_rep(p_pat) f
    where f.n <= 2
      and not exists (select 1 from public.posiciones x where x.user_id = f.id and x.nivel_id = p_nivel_id)
      and not exists (select 1 from public.lista_espera e where e.user_id = f.id and e.nivel_id = p_nivel_id)
      -- Puede entrar a ese nivel: ya lo alcanzó (o uno más alto) o lo tiene habilitado
      and (exists (select 1 from public.niveles n
                   where n.orden >= v_nivel.orden
                     and (exists (select 1 from public.posiciones p where p.user_id = f.id and p.nivel_id = n.id)
                          or exists (select 1 from public.ciclos_completados c where c.user_id = f.id and c.nivel_id = n.id)))
           or public.nivel_habilitado(f.id, p_nivel_id))
  loop
    insert into public.avisos_seguir (user_id, patrocinador_id, nivel_id, nivel_max_id)
    values (s.id, p_pat, p_nivel_id, v_max)
    on conflict on constraint avisos_seguir_uk
    do update set estado = 'pendiente', nivel_max_id = excluded.nivel_max_id, creado_en = now(), respondido_en = null;

    perform public.notificar(s.id, '¡' || v_nombre || ' volvió a sembrar!',
      format('Tu patrocinador %s subió al %s y volvió a entrar al %s. Sigue su secuencia: en Inicio o en Niveles toca "Seguir a %s". Si aceptas, cuando suba a constructor entrarás debajo de él como regalador y empezarán tus %s.',
             v_nombre, public.etiqueta_nivel(v_max), public.etiqueta_nivel(p_nivel_id), v_nombre,
             public.texto_duracion(public.intervalo_config('horas_tarea'))));
  end loop;
end;
$$;

-- Al subir a constructor: entran debajo de él quienes aceptaron seguirlo (en orden de aceptación)
create or replace function public.colocar_seguidores_aceptados(p_pat uuid, p_nivel_id integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  a       record;
  v_cas   public.posiciones;
  v_nivel text;
  v_pat   text;
  v_nom   text;
begin
  select nombre into v_nivel from public.niveles where id = p_nivel_id;
  select nombre_usuario into v_pat from public.perfiles where id = p_pat;
  for a in
    select av.id, av.user_id from public.avisos_seguir av
    where av.patrocinador_id = p_pat and av.nivel_id = p_nivel_id and av.estado = 'aceptado'
    order by av.respondido_en, av.id
  loop
    -- Si esa persona está haciendo otra cosa en este momento, no se espera (sin bloqueos cruzados)
    perform 1 from public.perfiles where id = a.user_id for update skip locked;
    continue when not found;
    if exists (select 1 from public.posiciones where user_id = a.user_id and nivel_id = p_nivel_id) then
      update public.avisos_seguir set estado = 'vencido' where id = a.id;
      continue;
    end if;
    select p.* into v_cas from public.posiciones p
    where p.id = public.lugar_debajo_de(p_pat, p_nivel_id) and p.user_id is null
    for update skip locked;
    exit when v_cas.id is null;

    perform public.ocupar_posicion(v_cas.id, a.user_id, true);
    update public.avisos_seguir set estado = 'cumplido' where id = a.id;
    select nombre_usuario into v_nom from public.perfiles where id = a.user_id;
    perform public.notificar(a.user_id, 'Entraste debajo de ' || v_pat,
      format('%s subió a constructor en el nivel %s y entraste debajo de él como %s. Empezaron tus %s para hacer tu tarea, escribir al recibidor y marcarla como hecha.',
             v_pat, v_nivel, public.nombre_posicion(v_cas.posicion),
             public.texto_duracion(public.intervalo_config('horas_tarea'))));
    perform public.notificar(p_pat, 'Tu referido entró debajo de ti',
      format('%s te siguió y entró debajo de ti como %s en el nivel %s.', v_nom, public.nombre_posicion(v_cas.posicion), v_nivel));
    v_cas := null;
  end loop;
end;
$$;

-- =====================================================================
-- 3. PARA LA PÁGINA
-- =====================================================================
-- Mis avisos vigentes: el patrocinador sigue en ese nivel como regalador, o es constructor con
-- un lugar libre; yo todavía no tengo posición ni espera en ese nivel
create or replace function public.mis_avisos_seguir()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', a.id,
             'estado', a.estado,
             'patrocinador', pe.nombre_usuario,
             'nivel_id', a.nivel_id,
             'nivel', n.nombre,
             'nivel_orden', n.orden,
             'nivel_max', nm.nombre,
             'nivel_max_orden', nm.orden,
             'pat_constructor', pp.posicion like 'constructor%',
             'creado_en', a.creado_en)
           order by a.creado_en desc), '[]'::jsonb)
    from public.avisos_seguir a
    join public.perfiles pe on pe.id = a.patrocinador_id
    join public.niveles n on n.id = a.nivel_id
    left join public.niveles nm on nm.id = a.nivel_max_id
    join public.posiciones pp on pp.user_id = a.patrocinador_id and pp.nivel_id = a.nivel_id
    join public.grupos g on g.id = pp.grupo_id and g.estado = 'activo'
    where a.user_id = v_yo
      and a.estado in ('pendiente', 'oculto', 'aceptado')
      and (pp.posicion like 'regalador%'
           or (pp.posicion like 'constructor%' and public.lugar_debajo_de(a.patrocinador_id, a.nivel_id) is not null))
      and not exists (select 1 from public.posiciones x where x.user_id = v_yo and x.nivel_id = a.nivel_id)
      and not exists (select 1 from public.lista_espera e where e.user_id = v_yo and e.nivel_id = a.nivel_id)
  );
end;
$$;

-- "Seguir a X en el nivel Y" (p_acepta = true) o "Ahora no" (false)
create or replace function public.responder_aviso_seguir(p_aviso_id bigint, p_acepta boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo    uuid := (select auth.uid());
  v_av    public.avisos_seguir;
  v_pp    public.posiciones;
  v_cas   public.posiciones;
  v_pat   text;
  v_yo_n  text;
  v_nivel text;
  v_rec   uuid;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  perform 1 from public.perfiles where id = v_yo for update;
  select * into v_av from public.avisos_seguir where id = p_aviso_id and user_id = v_yo for update;
  if not found then
    raise exception 'Ese aviso ya no existe. Recarga la página.';
  end if;
  select nombre_usuario into v_pat from public.perfiles where id = v_av.patrocinador_id;
  select nombre_usuario into v_yo_n from public.perfiles where id = v_yo;
  select nombre into v_nivel from public.niveles where id = v_av.nivel_id;

  if not coalesce(p_acepta, false) then
    if v_av.estado = 'pendiente' then
      update public.avisos_seguir set estado = 'oculto', respondido_en = now() where id = v_av.id;
    end if;
    return jsonb_build_object('resultado', 'oculto');
  end if;

  if v_av.estado in ('cumplido', 'vencido') then
    raise exception 'Ese aviso ya no está vigente. Puedes repetir el nivel % desde Niveles.', v_nivel;
  end if;
  if v_av.estado = 'aceptado' then
    return jsonb_build_object('resultado', 'anotado', 'nivel_id', v_av.nivel_id, 'nivel', v_nivel, 'patrocinador', v_pat);
  end if;
  if exists (select 1 from public.posiciones where user_id = v_yo and nivel_id = v_av.nivel_id) then
    raise exception 'Ya tienes una posición en el nivel %.', v_nivel;
  end if;

  select p.* into v_pp from public.posiciones p
  join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
  where p.user_id = v_av.patrocinador_id and p.nivel_id = v_av.nivel_id;

  if v_pp.id is null then
    update public.avisos_seguir set estado = 'vencido', respondido_en = now() where id = v_av.id;
    return jsonb_build_object('resultado', 'sin_lugar', 'nivel_id', v_av.nivel_id, 'nivel', v_nivel, 'patrocinador', v_pat,
      'mensaje', format('%s ya no está en el nivel %s. Puedes repetirlo desde Niveles.', v_pat, v_nivel));
  end if;

  if v_pp.posicion like 'constructor%' then
    -- Ya es constructor: entra ahora si queda un lugar libre debajo de él
    select p.* into v_cas from public.posiciones p
    where p.id = public.lugar_debajo_de(v_av.patrocinador_id, v_av.nivel_id) and p.user_id is null
    for update skip locked;
    if v_cas.id is null then
      update public.avisos_seguir set estado = 'vencido', respondido_en = now() where id = v_av.id;
      return jsonb_build_object('resultado', 'sin_lugar', 'nivel_id', v_av.nivel_id, 'nivel', v_nivel, 'patrocinador', v_pat,
        'mensaje', format('Los lugares debajo de %s ya se ocuparon. Puedes repetir el nivel %s desde Niveles.', v_pat, v_nivel));
    end if;
    perform public.ocupar_posicion(v_cas.id, v_yo, true);
    update public.avisos_seguir set estado = 'cumplido', respondido_en = now() where id = v_av.id;
    perform public.notificar(v_av.patrocinador_id, 'Tu referido entró debajo de ti',
      format('%s te siguió y entró debajo de ti como %s en el nivel %s.', v_yo_n, public.nombre_posicion(v_cas.posicion), v_nivel));
    v_rec := public.recibidor_de_grupo(v_cas.grupo_id);
    if v_rec is not null and v_rec <> v_av.patrocinador_id then
      perform public.notificar(v_rec, 'Nueva persona en tu grupo',
        format('%s entró a tu grupo del nivel %s como %s.', v_yo_n, v_nivel, public.nombre_posicion(v_cas.posicion)));
    end if;
    return jsonb_build_object('resultado', 'colocado', 'nivel_id', v_av.nivel_id, 'nivel', v_nivel, 'patrocinador', v_pat,
                              'posicion', v_cas.posicion);
  end if;

  if v_pp.posicion like 'regalador%' then
    update public.avisos_seguir set estado = 'aceptado', respondido_en = now() where id = v_av.id;
    perform public.notificar(v_av.patrocinador_id, v_yo_n || ' te sigue',
      format('%s aceptó seguirte en el nivel %s. Cuando subas a constructor entrará debajo de ti como regalador.', v_yo_n, v_nivel));
    return jsonb_build_object('resultado', 'anotado', 'nivel_id', v_av.nivel_id, 'nivel', v_nivel, 'patrocinador', v_pat);
  end if;

  -- Es el recibidor en ese nivel: ya no hay lugar para seguirlo
  update public.avisos_seguir set estado = 'vencido', respondido_en = now() where id = v_av.id;
  return jsonb_build_object('resultado', 'sin_lugar', 'nivel_id', v_av.nivel_id, 'nivel', v_nivel, 'patrocinador', v_pat,
    'mensaje', format('%s ya está en el centro de su grupo del nivel %s. Puedes repetir ese nivel desde Niveles.', v_pat, v_nivel));
end;
$$;

-- =====================================================================
-- 4. REDEFINIDAS DEL 26 (una línea nueva en cada una)
-- =====================================================================
-- ascender_grupo (26) + colocar_seguidores_aceptados
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

  -- (26) Grupo repetido con un lugar de constructor vacío: no sube; se avisa al patrocinador
  if v_grupo.tipo = 'repetido'
     and exists (select 1 from public.posiciones
                 where grupo_id = p_grupo_id and posicion like 'constructor%' and user_id is null) then
    perform public.notificar(public.recibidor_de_grupo(p_grupo_id), 'Tu grupo no puede subir todavía',
      format('Tus 4 regaladores del nivel %s ya están aprobados, pero tu grupo repetido tiene un lugar de constructor vacío. En Mi grupo toca "Elegir de mi lista de espera" en esa casilla: el grupo sube en cuanto lo llenes.',
             v_nivel.nombre));
    return false;
  end if;

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
    insert into public.ciclos_completados (user_id, nivel_id, grupo_id) values (v_rec, v_nivel.id, p_grupo_id);
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

  v_ultimo := public.nivel_siguiente(v_nivel.id) is null;
  perform public.notificar(v_rec, 'Completaste el nivel ' || v_nivel.nombre,
    case when v_grupo.tipo = 'repetido'
         then format('Completaste otra vez el nivel %s con tu equipo. Puedes volver a repetir niveles inferiores desde Niveles.', v_nivel.nombre)
         when v_ultimo
         then format('Completaste el nivel %s, el último nivel. ¡Felicitaciones! Puedes repetir niveles inferiores con tu equipo desde Niveles.', v_nivel.nombre)
         else format('Completaste el nivel %s. Ya puedes participar en el siguiente desde Niveles.', v_nivel.nombre)
    end);

  foreach u in array v_r loop
    if u is not null and exists (select 1 from public.ciclos_completados c where c.user_id = u and c.nivel_id = v_nivel.id) then
      -- (26) Constructor que está repitiendo el nivel: sus 2 lugares son para quienes lo siguen
      perform public.notificar(u, 'Subiste a constructor',
        format('Subiste a constructor en el nivel %s que estás repitiendo. Tus referidos que te siguen pueden entrar debajo de ti tocando Repetir (o Participar) en Niveles. Si no tienes referidos disponibles, invita a 2 personas nuevas con tu enlace: entran directo debajo de ti, son tu equipo de repeticiones y no cuentan en tu límite de 2. Tienes %s.',
               v_nivel.nombre, public.texto_dias_invitar(v_nivel.id)));
      -- (27) Quienes aceptaron seguirlo entran ya debajo de él (empiezan sus 4 horas)
      perform public.colocar_seguidores_aceptados(u, v_nivel.id);
      perform public.notificar(s.id, 'Tu patrocinador tiene un lugar para ti',
        format('%s es constructor en el nivel %s y tiene un lugar para ti debajo de él. Entra desde Niveles.',
               (select nombre_usuario from public.perfiles where id = u), v_nivel.nombre))
      from public.seguidores_rep(u) s
      where not exists (select 1 from public.posiciones x where x.user_id = s.id and x.nivel_id = v_nivel.id)
        and not exists (select 1 from public.lista_espera e where e.user_id = s.id and e.nivel_id = v_nivel.id)
        and public.lugar_debajo_de(u, v_nivel.id) is not null;
    else
      perform public.notificar(u, 'Subiste a constructor',
        format('La persona del centro recibió todas las tareas y subiste a constructor. Tienes %s para invitar a 2 personas. (Nivel %s)',
               public.texto_dias_invitar(v_nivel.id), v_nivel.nombre));
    end if;
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


-- repetir_nivel (26) + crear_avisos_seguir
create or replace function public.repetir_nivel(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_nivel  public.niveles;
  v_perfil public.perfiles;
  v_max    integer;
  v_ult    timestamptz;
  v_res    jsonb;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_nivel from public.niveles where id = p_nivel_id;
  if not found then
    raise exception 'El nivel elegido no existe.';
  end if;
  select * into v_perfil from public.perfiles where id = v_yo;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  select max(n.orden) into v_max
  from public.niveles n
  where exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id)
     or exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id);
  if v_max is null or v_nivel.orden >= v_max then
    raise exception 'Solo puedes repetir niveles inferiores al más alto que alcanzaste.';
  end if;
  if exists (select 1 from public.posiciones where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya tienes una posición activa en el nivel %. Solo puedes tener una por nivel.', v_nivel.nombre;
  end if;
  if exists (select 1 from public.lista_espera where user_id = v_yo and nivel_id = p_nivel_id) then
    raise exception 'Ya estás en la lista de espera de este nivel.';
  end if;

  v_ult := public.ultima_repeticion(v_yo);
  if v_ult + public.intervalo_config('horas_espera_repetir') > now() then
    raise exception 'Debes esperar % para volver a repetir un nivel.',
      public.texto_duracion(v_ult + public.intervalo_config('horas_espera_repetir') - now());
  end if;

  if v_perfil.es_fundador then
    v_res := public.repetir_con_equipo(v_yo, p_nivel_id);
  else
    v_res := public.entrar_repitiendo(v_yo, p_nivel_id);
    -- (27) Aviso "¡volvió a sembrar!" a sus 2 referidos
    if v_res ->> 'resultado' = 'colocado' then
      perform public.crear_avisos_seguir(v_yo, p_nivel_id);
    end if;
  end if;
  insert into public.repeticiones (user_id, nivel_id, modo)
  values (v_yo, p_nivel_id, case when v_perfil.es_fundador then 'equipo' else 'regalador' end);
  return v_res;
end;
$$;


-- =====================================================================
-- 5. PERMISOS
-- =====================================================================
revoke execute on function public.etiqueta_nivel(integer)                        from public, anon, authenticated;
revoke execute on function public.lugar_debajo_de(uuid, integer)                 from public, anon, authenticated;
revoke execute on function public.crear_avisos_seguir(uuid, integer)             from public, anon, authenticated;
revoke execute on function public.colocar_seguidores_aceptados(uuid, integer)    from public, anon, authenticated;
revoke execute on function public.ascender_grupo(uuid)                           from public, anon, authenticated;

revoke execute on function public.mis_avisos_seguir()                            from public, anon;
revoke execute on function public.responder_aviso_seguir(bigint, boolean)        from public, anon;
revoke execute on function public.repetir_nivel(integer)                         from public, anon;
grant  execute on function public.mis_avisos_seguir()                            to authenticated;
grant  execute on function public.responder_aviso_seguir(bigint, boolean)        to authenticated;
grant  execute on function public.repetir_nivel(integer)                         to authenticated;

notify pgrst, 'reload schema';
