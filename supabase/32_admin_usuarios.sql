-- =====================================================================
-- 32_admin_usuarios.sql  (va DESPUÉS de 31_registro_socio.sql)
-- Pestaña Usuarios del panel de soporte (Administración):
--   1) admin_resumen_plataforma(): usuarios registrados, tareas recibidas (total), tableros completados
--      y personas en lista de espera (de un nivel o de su patrocinador).
--   2) admin_usuarios_lista(): tabla paginada (para miles de usuarios) con número, código, usuario,
--      nombre, nivel actual, tableros, tareas recibidas, tareas hechas y estado; buscador, filtro por
--      nivel actual y orden (tareas recibidas, tareas hechas, nivel, fecha de registro, número).
--   3) admin_ficha_extra(): por nivel, tableros normales, repeticiones y tareas recibidas; y la lista
--      de referidos de la persona.
--   4) admin_historial_usuario(): los tableros de una persona ("Ver tableros"), igual que
--      mi_historial_niveles() pero para el administrador.
-- Solo lectura. Se puede volver a ejecutar sin problema.
-- =====================================================================

create or replace function public.admin_resumen_plataforma()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver el resumen.';
  end if;
  return jsonb_build_object(
    'usuarios', (select count(*) from public.perfiles),
    'tareas_recibidas', (select count(*) from public.tareas_historial),
    'tableros', (select count(*) from public.ciclos_completados),
    'en_espera', (select count(*) from public.perfiles pe
                  where pe.referido_estado = 'reserva'
                     or exists (select 1 from public.lista_espera e where e.user_id = pe.id)),
    'espera_nivel', (select count(distinct user_id) from public.lista_espera),
    'espera_patrocinador', (select count(*) from public.perfiles where referido_estado = 'reserva')
  );
end;
$$;

create or replace function public.admin_usuarios_lista(p_buscar text default null, p_nivel integer default null,
                                                      p_orden text default 'registro', p_desde integer default 0,
                                                      p_cuantos integer default 25)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q      text := nullif(lower(trim(coalesce(p_buscar, ''))), '');
  -- Solo dígitos y sin el 0 inicial: 0987654321 encuentra +593987654321
  v_dig    text := nullif(regexp_replace(regexp_replace(coalesce(p_buscar, ''), '\D', '', 'g'), '^0+', ''), '');
  v_desde  integer := greatest(coalesce(p_desde, 0), 0);
  v_cuant  integer := least(greatest(coalesce(p_cuantos, 25), 1), 100);
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver los usuarios.';
  end if;
  return (
    with base as (
      select pe.id, pe.numero, pe.codigo_invitacion, pe.nombre_usuario, pe.nombre_completo, pe.whatsapp,
             pe.creado_en, pe.es_fundador, u.email::text as correo,
             na.id as nivel_id, na.orden as nivel_orden, na.nombre as nivel_nombre,
             coalesce(cc.n, 0)::int as tableros,
             coalesce(tr.n, 0)::int as tareas_recibidas,
             coalesce(th.n, 0)::int as tareas_hechas,
             case
               when exists (select 1 from public.posiciones p where p.user_id = pe.id and p.estado = 'plazo_vencido') then 'plazo_vencido'
               when pe.referido_estado = 'reserva' or exists (select 1 from public.lista_espera e where e.user_id = pe.id) then 'espera'
               else 'activo'
             end as estado
      from public.perfiles pe
      left join auth.users u on u.id = pe.id
      left join lateral (
        select n.id, n.orden, n.nombre from public.posiciones p join public.niveles n on n.id = p.nivel_id
        where p.user_id = pe.id order by n.orden desc limit 1
      ) na on true
      left join (select user_id, count(*) n from public.ciclos_completados group by user_id) cc on cc.user_id = pe.id
      left join (select recibidor_id, count(*) n from public.tareas_historial group by recibidor_id) tr on tr.recibidor_id = pe.id
      left join (select regalador_id, count(*) n from public.tareas_historial group by regalador_id) th on th.regalador_id = pe.id
    ), filtrados as (
      select b.* from base b
      where (v_q is null
             or lower(concat_ws(' ', public.numero_socio(b.numero), b.codigo_invitacion, b.nombre_usuario, b.nombre_completo, b.correo, b.whatsapp)) like '%' || v_q || '%'
             or (v_dig is not null and char_length(v_dig) >= 6 and regexp_replace(coalesce(b.whatsapp, ''), '\D', '', 'g') like '%' || v_dig || '%'))
        and (p_nivel is null or b.nivel_id = p_nivel)
    ), ordenados as (
      select f.*, row_number() over (order by
               case when p_orden = 'recibidas' then f.tareas_recibidas end desc nulls last,
               case when p_orden = 'hechas' then f.tareas_hechas end desc nulls last,
               case when p_orden = 'nivel' then f.nivel_orden end desc nulls last,
               case when p_orden = 'numero' then f.numero end asc nulls last,
               f.creado_en desc, f.numero desc) as rn
      from filtrados f
    )
    select jsonb_build_object(
      'total', (select count(*) from filtrados),
      'filas', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', o.id, 'numero', public.numero_socio(o.numero), 'codigo', o.codigo_invitacion,
                 'nombre_usuario', o.nombre_usuario, 'nombre_completo', o.nombre_completo, 'correo', o.correo,
                 'whatsapp', o.whatsapp, 'creado_en', o.creado_en, 'es_fundador', o.es_fundador,
                 'nivel_id', o.nivel_id, 'nivel_orden', o.nivel_orden, 'nivel_nombre', o.nivel_nombre,
                 'tableros', o.tableros, 'tareas_recibidas', o.tareas_recibidas, 'tareas_hechas', o.tareas_hechas,
                 'estado', o.estado) order by o.rn)
        from ordenados o where o.rn > v_desde and o.rn <= v_desde + v_cuant), '[]'::jsonb)
    )
  );
end;
$$;

create or replace function public.admin_ficha_extra(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver la ficha.';
  end if;
  return jsonb_build_object(
    -- La 1.ª vez que completa un nivel es "normal"; las siguientes, repeticiones
    'niveles', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nivel_id', n.id, 'nivel', n.nombre, 'nivel_orden', n.orden,
               'normales', least(x.tableros, 1), 'repeticiones', greatest(x.tableros - 1, 0),
               'tareas_recibidas', x.recibidas) order by n.orden), '[]'::jsonb)
      from public.niveles n
      cross join lateral (
        select (select count(*) from public.ciclos_completados c where c.user_id = p_user_id and c.nivel_id = n.id)::int as tableros,
               (select count(*) from public.tareas_historial h where h.recibidor_id = p_user_id and h.nivel_id = n.id)::int as recibidas
      ) x
      where x.tableros > 0 or x.recibidas > 0
    ),
    'referidos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', pe.id, 'numero', public.numero_socio(pe.numero), 'nombre_usuario', pe.nombre_usuario,
               'referido_estado', pe.referido_estado) order by pe.creado_en, pe.id), '[]'::jsonb)
      from public.perfiles pe where pe.invitado_por = p_user_id
    )
  );
end;
$$;

-- "Ver tableros": lo mismo que mi_historial_niveles() (29), para cualquier persona
create or replace function public.admin_historial_usuario(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo uuid := p_user_id;
begin
  if not public.es_admin() then
    raise exception 'Solo un administrador puede ver el historial de otra persona.';
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
-- PERMISOS
-- =====================================================================
revoke execute on function public.admin_resumen_plataforma()                                   from public, anon;
revoke execute on function public.admin_usuarios_lista(text, integer, text, integer, integer)  from public, anon;
revoke execute on function public.admin_ficha_extra(uuid)                                      from public, anon;
revoke execute on function public.admin_historial_usuario(uuid)                                from public, anon;
grant  execute on function public.admin_resumen_plataforma()                                   to authenticated;
grant  execute on function public.admin_usuarios_lista(text, integer, text, integer, integer)  to authenticated;
grant  execute on function public.admin_ficha_extra(uuid)                                      to authenticated;
grant  execute on function public.admin_historial_usuario(uuid)                                to authenticated;

notify pgrst, 'reload schema';
