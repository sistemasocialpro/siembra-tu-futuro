-- =====================================================================
-- 29_mapa_historial.sql  (va DESPUÉS de 28_aviso_al_entrar.sql)
-- 1) Eliminar persona de una casilla (solo su patrocinador, el que la invitó):
--    - sale SOLO de esa casilla (sus otras posiciones siguen) y, si era referido activo, deja de serlo
--      (queda 'eliminado': en las posiciones normales entra por derrame);
--    - la casilla queda "Libre" y guardada para el patrocinador, que la llena eligiendo a alguien de su
--      lista de espera (entra con su reloj; pasa a activo si al patrocinador le queda lugar);
--    - un grupo no sube de nivel mientras tenga un constructor eliminado sin reemplazo.
--    En el grupo repetido del fundador los constructores se siguen quitando con "Quitar de esta repetición".
-- 2) Historial de niveles completados: foto del grupo (7 nombres) al subir (ciclos_grupo) y
--    mi_historial_niveles(). Los niveles completados antes de este script se reconstruyen con
--    tareas_historial (recibidor y regaladores; los constructores no se guardaban).
-- 3) mapa_acciones(): qué puedo hacer en cada casilla (eliminar / elegir de mi lista de espera).
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

-- =====================================================================
-- 1. TABLAS
-- =====================================================================
create table if not exists public.ciclos_grupo (
  grupo_id       uuid not null,
  posicion       text not null,
  user_id        uuid references public.perfiles (id) on delete set null,
  nombre_usuario text,
  primary key (grupo_id, posicion)
);
alter table public.ciclos_grupo enable row level security;
revoke all on public.ciclos_grupo from anon, authenticated;

create table if not exists public.casillas_liberadas (
  posicion_id     uuid primary key references public.posiciones (id) on delete cascade,
  patrocinador_id uuid not null references public.perfiles (id) on delete cascade,
  quitado_id      uuid references public.perfiles (id) on delete set null,
  liberado_en     timestamptz not null default now()
);
create index if not exists casillas_liberadas_pat_idx on public.casillas_liberadas (patrocinador_id);
alter table public.casillas_liberadas enable row level security;
revoke all on public.casillas_liberadas from anon, authenticated;

-- =====================================================================
-- 2. ELIMINAR PERSONA Y LLENAR LA CASILLA LIBRE
-- =====================================================================
create or replace function public.eliminar_de_casilla(p_posicion_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_pos    public.posiciones;
  v_grupo  public.grupos;
  v_per    public.perfiles;
  v_nivel  text;
  v_yo_nom text;
  v_rec    uuid;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_pos from public.posiciones where id = p_posicion_id;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if v_pos.user_id is null then
    raise exception 'Esa casilla ya está libre.';
  end if;
  -- Bloqueo en el mismo orden que el resto: perfiles (por id) y después la casilla
  perform 1 from public.perfiles where id in (v_yo, v_pos.user_id) order by id for update;
  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if v_pos.user_id is null then
    raise exception 'Esa casilla ya está libre.';
  end if;
  select * into v_grupo from public.grupos where id = v_pos.grupo_id;
  select * into v_per from public.perfiles where id = v_pos.user_id;

  if v_grupo.estado <> 'activo' then
    raise exception 'Ese grupo ya se completó.';
  end if;
  if v_pos.posicion = 'recibidor' then
    raise exception 'No se puede eliminar a la persona del centro.';
  end if;
  if v_per.invitado_por is distinct from v_yo or v_per.id = v_yo then
    raise exception 'Solo el patrocinador de % (quien la invitó) puede eliminarla.', v_per.nombre_usuario;
  end if;
  if v_grupo.tipo = 'repetido' and v_pos.posicion like 'constructor%' then
    raise exception 'En el grupo repetido usa "Quitar de esta repetición".';
  end if;

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  select nombre_usuario into v_yo_nom from public.perfiles where id = v_yo;

  perform public.liberar_posicion(v_pos.id, 'retirada');
  insert into public.casillas_liberadas (posicion_id, patrocinador_id, quitado_id)
  values (v_pos.id, v_yo, v_per.id)
  on conflict (posicion_id) do update set patrocinador_id = excluded.patrocinador_id,
    quitado_id = excluded.quitado_id, liberado_en = now();

  if v_per.referido_estado = 'activo' then
    update public.perfiles set referido_estado = 'eliminado', reserva_desde = null where id = v_per.id;
  end if;

  perform public.notificar(v_per.id, 'Saliste de una casilla',
    format('%s te quitó de la casilla %s del nivel %s. Tus otras posiciones siguen igual.%s',
           v_yo_nom, public.nombre_posicion(v_pos.posicion), v_nivel,
           case when v_per.referido_estado = 'activo'
                then ' Ya no eres su referido activo: en Niveles puedes seguir participando por derrame.' else '' end));
  v_rec := public.recibidor_de_grupo(v_pos.grupo_id);
  if v_rec is not null and v_rec <> v_yo then
    perform public.notificar(v_rec, 'Alguien salió de tu grupo',
      format('%s dejó la casilla %s de tu grupo del nivel %s. Su patrocinador elegirá a quién poner en su lugar.',
             v_per.nombre_usuario, public.nombre_posicion(v_pos.posicion), v_nivel));
  end if;
  return v_per.nombre_usuario;
end;
$$;

create or replace function public.candidatos_casilla_libre(p_posicion_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo  uuid := (select auth.uid());
  v_pos public.posiciones;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_pos from public.posiciones where id = p_posicion_id;
  if not found or not exists (select 1 from public.casillas_liberadas where posicion_id = p_posicion_id and patrocinador_id = v_yo) then
    raise exception 'Esa casilla no la liberaste tú.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', pe.id,
             'nombre_usuario', pe.nombre_usuario,
             'en_espera_desde', coalesce(pe.reserva_desde, pe.creado_en))
           order by coalesce(pe.reserva_desde, pe.creado_en), pe.id), '[]'::jsonb)
    from public.perfiles pe
    where pe.invitado_por = v_yo and pe.referido_estado = 'reserva'
      and not exists (select 1 from public.posiciones x where x.user_id = pe.id and x.nivel_id = v_pos.nivel_id)
  );
end;
$$;

create or replace function public.llenar_casilla_libre(p_posicion_id uuid, p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_pos    public.posiciones;
  v_grupo  public.grupos;
  v_nuevo  public.perfiles;
  v_nivel  text;
  v_yo_nom text;
  v_activo boolean;
  v_rec    uuid;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  perform 1 from public.perfiles where id in (v_yo, p_user_id) order by id for update;
  select * into v_pos from public.posiciones where id = p_posicion_id for update;
  if not found then
    raise exception 'La casilla ya no existe. Recarga la página.';
  end if;
  if not exists (select 1 from public.casillas_liberadas where posicion_id = p_posicion_id and patrocinador_id = v_yo) then
    raise exception 'Esa casilla no la liberaste tú.';
  end if;
  if v_pos.user_id is not null then
    delete from public.casillas_liberadas where posicion_id = p_posicion_id;
    raise exception 'Esa casilla ya la ocupó otra persona. Recarga la página.';
  end if;
  select * into v_grupo from public.grupos where id = v_pos.grupo_id;
  if v_grupo.estado <> 'activo' then
    raise exception 'Ese grupo ya se completó.';
  end if;

  select * into v_nuevo from public.perfiles where id = p_user_id;
  if not found or v_nuevo.invitado_por is distinct from v_yo or v_nuevo.referido_estado <> 'reserva' then
    raise exception 'Esa persona no está en tu lista de espera.';
  end if;
  if exists (select 1 from public.posiciones where user_id = p_user_id and nivel_id = v_pos.nivel_id) then
    raise exception '% ya tiene una posición en este nivel. Elige a otra persona.', v_nuevo.nombre_usuario;
  end if;

  perform public.ocupar_posicion(v_pos.id, p_user_id, true);
  delete from public.casillas_liberadas where posicion_id = v_pos.id;
  -- Pasa a referido activo si al patrocinador le queda lugar (máximo 2)
  v_activo := public.contar_activos(v_yo) < 2;
  if v_activo then
    update public.perfiles set referido_estado = 'activo', reserva_desde = null where id = p_user_id;
  end if;

  select nombre into v_nivel from public.niveles where id = v_pos.nivel_id;
  select nombre_usuario into v_yo_nom from public.perfiles where id = v_yo;
  perform public.notificar(p_user_id, 'Ya tienes tu lugar',
    case when v_pos.posicion like 'regalador%'
         then format('%s te eligió de su lista de espera: eres %s en el nivel %s. Tienes %s para hacer tu tarea, escribir al recibidor y marcarla como hecha.',
                     v_yo_nom, public.nombre_posicion(v_pos.posicion), v_nivel,
                     public.texto_duracion(public.intervalo_config('horas_tarea')))
         else format('%s te eligió de su lista de espera: eres %s en el nivel %s. Tienes %s para invitar a 2 personas.',
                     v_yo_nom, public.nombre_posicion(v_pos.posicion), v_nivel, public.texto_dias_invitar(v_pos.nivel_id))
    end);
  v_rec := public.recibidor_de_grupo(v_pos.grupo_id);
  if v_rec is not null and v_rec <> v_yo then
    perform public.notificar(v_rec, 'Nueva persona en tu grupo',
      format('%s entró a tu grupo del nivel %s como %s.', v_nuevo.nombre_usuario, v_nivel, public.nombre_posicion(v_pos.posicion)));
  end if;

  -- Si era un constructor y las 4 tareas ya estaban aprobadas, el grupo sube ahora
  if v_pos.posicion like 'constructor%' then
    perform public.ascender_grupo(v_pos.grupo_id);
  end if;
  return v_nuevo.nombre_usuario;
end;
$$;

-- Qué puedo hacer en cada casilla del mapa
create or replace function public.mapa_acciones(p_grupo_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo    uuid := (select auth.uid());
  v_grupo public.grupos;
begin
  if v_yo is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  select * into v_grupo from public.grupos where id = p_grupo_id;
  if not found then
    return '[]'::jsonb;
  end if;
  if not public.es_admin()
     and not exists (select 1 from public.posiciones where grupo_id = p_grupo_id and user_id = v_yo) then
    raise exception 'No perteneces a ese grupo.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'posicion', p.posicion,
             'puedo_eliminar', v_grupo.estado = 'activo' and p.user_id is not null and p.user_id <> v_yo
                               and p.posicion <> 'recibidor' and pe.invitado_por = v_yo
                               and not (v_grupo.tipo = 'repetido' and p.posicion like 'constructor%'),
             'puedo_llenar', v_grupo.estado = 'activo' and p.user_id is null and l.patrocinador_id = v_yo)), '[]'::jsonb)
    from public.posiciones p
    left join public.perfiles pe on pe.id = p.user_id
    left join public.casillas_liberadas l on l.posicion_id = p.id
    where p.grupo_id = p_grupo_id
  );
end;
$$;

-- =====================================================================
-- 3. HISTORIAL DE NIVELES COMPLETADOS
-- =====================================================================
create or replace function public.mi_historial_niveles()
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
    select coalesce(jsonb_agg(x.fila order by x.completado_en desc), '[]'::jsonb)
    from (
      select c.completado_en,
             jsonb_build_object(
               'nivel_id', n.id,
               'nivel', n.nombre,
               'nivel_orden', n.orden,
               'completado_en', c.completado_en,
               -- 1.ª vez = normal; después, repetición 1, 2, …
               'repeticion', (row_number() over (partition by c.nivel_id order by c.completado_en)) - 1,
               'grupo_fundador', coalesce(g.tipo = 'repetido', false),
               'tareas_recibidas', (select count(*) from public.tareas_historial h
                                     where h.grupo_id = c.grupo_id and h.recibidor_id = v_yo and c.grupo_id is not null),
               'grupo', coalesce(
                  (select jsonb_agg(jsonb_build_object('posicion', cg.posicion, 'nombre_usuario', cg.nombre_usuario,
                                                       'yo', cg.user_id = v_yo)
                                    order by array_position(array['recibidor', 'constructor_1', 'constructor_2',
                                      'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], cg.posicion))
                   from public.ciclos_grupo cg where cg.grupo_id = c.grupo_id),
                  -- Antes del 29 no se guardaba la foto: recibidor (yo) y los regaladores que aprobé
                  (select jsonb_build_array(jsonb_build_object('posicion', 'recibidor',
                            'nombre_usuario', (select nombre_usuario from public.perfiles where id = v_yo), 'yo', true))
                          || coalesce((select jsonb_agg(jsonb_build_object('posicion', h.posicion, 'nombre_usuario', pe.nombre_usuario, 'yo', false)
                                                        order by h.posicion)
                                       from public.tareas_historial h
                                       left join public.perfiles pe on pe.id = h.regalador_id
                                       where h.grupo_id = c.grupo_id and h.recibidor_id = v_yo and c.grupo_id is not null), '[]'::jsonb))
               ),
               'foto_completa', exists (select 1 from public.ciclos_grupo cg where cg.grupo_id = c.grupo_id)
             ) as fila
      from public.ciclos_completados c
      join public.niveles n on n.id = c.nivel_id
      left join public.grupos g on g.id = c.grupo_id
      where c.user_id = v_yo
    ) x
  );
end;
$$;

-- =====================================================================
-- 4. ASCENSO (redefinida del 27): foto del grupo y no sube con un constructor eliminado sin reemplazo
-- =====================================================================
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

  -- (29) Constructor eliminado por su patrocinador y sin reemplazo: el grupo espera a que lo llene
  if exists (select 1 from public.posiciones p
             join public.casillas_liberadas l on l.posicion_id = p.id
             where p.grupo_id = p_grupo_id and p.posicion like 'constructor%' and p.user_id is null) then
    perform public.notificar(l.patrocinador_id, 'Un grupo espera tu elección',
      format('Las 4 tareas del grupo del nivel %s ya están aprobadas, pero falta el constructor que eliminaste. En Mi grupo toca esa casilla libre y elige a alguien de tu lista de espera: el grupo sube en cuanto lo llenes.',
             v_nivel.nombre))
    from public.posiciones p
    join public.casillas_liberadas l on l.posicion_id = p.id
    where p.grupo_id = p_grupo_id and p.posicion like 'constructor%' and p.user_id is null;
    perform public.notificar(public.recibidor_de_grupo(p_grupo_id), 'Tu grupo no puede subir todavía',
      format('Tus 4 regaladores del nivel %s ya están aprobados, pero falta un constructor que su patrocinador quitó. El grupo sube en cuanto lo reemplace.',
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

  -- (29) Foto del grupo para el Historial (antes de vaciar las casillas)
  insert into public.ciclos_grupo (grupo_id, posicion, user_id, nombre_usuario)
  select p.grupo_id, p.posicion, p.user_id, pe.nombre_usuario
  from public.posiciones p
  left join public.perfiles pe on pe.id = p.user_id
  where p.grupo_id = p_grupo_id
  on conflict (grupo_id, posicion) do update set user_id = excluded.user_id, nombre_usuario = excluded.nombre_usuario;
  delete from public.casillas_liberadas where posicion_id in (select id from public.posiciones where grupo_id = p_grupo_id);

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


-- =====================================================================
-- 5. PERMISOS
-- =====================================================================
revoke execute on function public.ascender_grupo(uuid)                       from public, anon, authenticated;
revoke execute on function public.eliminar_de_casilla(uuid)                  from public, anon;
revoke execute on function public.candidatos_casilla_libre(uuid)             from public, anon;
revoke execute on function public.llenar_casilla_libre(uuid, uuid)           from public, anon;
revoke execute on function public.mapa_acciones(uuid)                        from public, anon;
revoke execute on function public.mi_historial_niveles()                     from public, anon;
grant  execute on function public.eliminar_de_casilla(uuid)                  to authenticated;
grant  execute on function public.candidatos_casilla_libre(uuid)             to authenticated;
grant  execute on function public.llenar_casilla_libre(uuid, uuid)           to authenticated;
grant  execute on function public.mapa_acciones(uuid)                        to authenticated;
grant  execute on function public.mi_historial_niveles()                     to authenticated;

notify pgrst, 'reload schema';
