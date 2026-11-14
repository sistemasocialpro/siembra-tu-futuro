-- =====================================================================
-- Sistema Siembra tu Futuro — 13_perfil_soporte.sql
-- Ejecutar DESPUÉS de 01 a 12. Se puede volver a ejecutar sin problema.
-- Perfil (historial de tareas, resumen), Info personal (editar mis datos) y Soporte (enlaces).
-- En el sistema NO existe dinero: todo se mide en tareas, niveles, grupos y personas.
-- =====================================================================

-- =====================================================================
-- 1. HISTORIAL DE TAREAS (al ascender, el grupo original se vacía: el historial no puede
--    salir de posiciones)
-- =====================================================================
create table if not exists public.tareas_historial (
  id           uuid primary key default gen_random_uuid(),
  nivel_id     integer references public.niveles (id),
  grupo_id     uuid references public.grupos (id) on delete set null,
  regalador_id uuid references public.perfiles (id) on delete cascade,
  recibidor_id uuid references public.perfiles (id) on delete cascade,
  posicion     text,
  aprobada_en  timestamptz not null default now()
);
create index if not exists tareas_historial_regalador_idx on public.tareas_historial (regalador_id, aprobada_en desc);
create index if not exists tareas_historial_recibidor_idx on public.tareas_historial (recibidor_id, aprobada_en desc);

-- confirmar_tarea (versión de 11) + fila en el historial. Todo lo demás igual.
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

  -- Historial (antes del ascenso, que vacía el grupo)
  insert into public.tareas_historial (nivel_id, grupo_id, regalador_id, recibidor_id, posicion)
  values (v_pos.nivel_id, v_pos.grupo_id, v_pos.user_id, public.recibidor_de_grupo(v_pos.grupo_id), v_pos.posicion);

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

-- Relleno único del historial con las tareas ya aprobadas (idempotente)
insert into public.tareas_historial (nivel_id, grupo_id, regalador_id, recibidor_id, posicion, aprobada_en)
select p.nivel_id, p.grupo_id, p.user_id, public.recibidor_de_grupo(p.grupo_id), p.posicion,
       coalesce(p.tarea_hecha_en, p.asignado_en, now())
from public.posiciones p
where p.posicion like 'regalador%'
  and p.estado = 'confirmada'
  and p.user_id is not null
  and not exists (
    select 1 from public.tareas_historial h
    where h.regalador_id = p.user_id and h.grupo_id = p.grupo_id
  );

-- Historial con el nombre de la otra persona (perfiles sigue cerrada). 20 por página.
create or replace function public.mi_historial(p_tipo text, p_desde integer default 0, p_cuantos integer default 20)
returns table (nivel_id integer, nivel text, otro_usuario text, posicion text, aprobada_en timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select h.nivel_id, n.nombre, pe.nombre_usuario, h.posicion, h.aprobada_en
  from public.tareas_historial h
  left join public.niveles n on n.id = h.nivel_id
  left join public.perfiles pe
    on pe.id = case when p_tipo = 'recibidas' then h.regalador_id else h.recibidor_id end
  where (p_tipo = 'recibidas' and h.recibidor_id = (select auth.uid()))
     or (p_tipo is distinct from 'recibidas' and h.regalador_id = (select auth.uid()))
  order by h.aprobada_en desc, h.id
  offset greatest(coalesce(p_desde, 0), 0)
  limit least(greatest(coalesce(p_cuantos, 20), 1), 100);
$$;

-- =====================================================================
-- 2. RESUMEN DEL PERFIL
-- =====================================================================
create or replace function public.mi_resumen_perfil()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_perfil public.perfiles;
  v_actual public.niveles;
begin
  select * into v_perfil from public.perfiles where id = v_yo;
  if not found then
    raise exception 'No se encontró tu perfil.';
  end if;

  -- Nivel actual: el de mayor orden donde tengo posición; si no, el primer habilitado sin completar
  select n.* into v_actual
  from public.posiciones p join public.niveles n on n.id = p.nivel_id
  where p.user_id = v_yo
  order by n.orden desc limit 1;

  if v_actual.id is null then
    select n.* into v_actual
    from public.niveles n
    where public.nivel_habilitado(v_yo, n.id)
      and not exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id)
    order by n.orden limit 1;
  end if;

  return jsonb_build_object(
    'nombre_usuario',      v_perfil.nombre_usuario,
    'miembro_desde',       v_perfil.creado_en,
    'tareas_regaladas',    (select count(*) from public.tareas_historial where regalador_id = v_yo),
    'tareas_recibidas',    (select count(*) from public.tareas_historial where recibidor_id = v_yo),
    'niveles_completados', (select count(*) from public.ciclos_completados where user_id = v_yo),
    'total_niveles',       (select count(*) from public.niveles),
    'nivel_actual',        case when v_actual.id is null then null
                                else jsonb_build_object('id', v_actual.id, 'nombre', v_actual.nombre, 'orden', v_actual.orden) end,
    'referidos',           public.contar_referidos(v_yo),
    'en_espera',           exists (select 1 from public.lista_espera where user_id = v_yo),
    'niveles', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nivel_id', n.id,
               'nombre',   n.nombre,
               'orden',    n.orden,
               'posicion', (select p.posicion from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id),
               'estado',   case
                             when exists (select 1 from public.ciclos_completados c where c.user_id = v_yo and c.nivel_id = n.id) then 'completado'
                             when exists (select 1 from public.posiciones p where p.user_id = v_yo and p.nivel_id = n.id) then 'actual'
                             when public.nivel_habilitado(v_yo, n.id) then 'habilitado'
                             else 'bloqueado'
                           end
             ) order by n.orden), '[]'::jsonb)
      from public.niveles n
    )
  );
end;
$$;

-- Resumen de MI grupo en un nivel (sin WhatsApp)
create or replace function public.mi_grupo_resumen(p_nivel_id integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_yo    uuid := (select auth.uid());
  v_grupo uuid;
begin
  select p.grupo_id into v_grupo
  from public.posiciones p
  join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
  where p.user_id = v_yo and p.nivel_id = p_nivel_id;

  if v_grupo is null then
    return null;
  end if;

  return jsonb_build_object(
    'nivel_id',  p_nivel_id,
    'nivel',     (select nombre from public.niveles where id = p_nivel_id),
    'mi_posicion', (select posicion from public.posiciones where grupo_id = v_grupo and user_id = v_yo),
    'recibidor', (select pe.nombre_usuario from public.posiciones p
                    left join public.perfiles pe on pe.id = p.user_id
                   where p.grupo_id = v_grupo and p.posicion = 'recibidor'),
    'casillas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'posicion', p.posicion,
               'nombre_usuario', pe.nombre_usuario,
               'estado', p.estado
             ) order by p.posicion), '[]'::jsonb)
      from public.posiciones p
      left join public.perfiles pe on pe.id = p.user_id
      where p.grupo_id = v_grupo and p.posicion <> 'recibidor'
    ),
    'tareas_aprobadas', (select count(*) from public.posiciones
                          where grupo_id = v_grupo and posicion like 'regalador%'
                            and user_id is not null and estado = 'confirmada')
  );
end;
$$;

-- =====================================================================
-- 3. INFO PERSONAL: editar mis datos sin abrir la tabla
-- =====================================================================
-- País: columna nueva (el formulario lo pide y perfiles no tenía dónde guardarlo).
alter table public.perfiles add column if not exists pais text;
alter table public.perfiles drop constraint if exists perfiles_pais_chk;
alter table public.perfiles add constraint perfiles_pais_chk
  check (pais is null or char_length(pais) between 2 and 60);

create or replace function public.actualizar_mi_perfil(p_nombre text, p_whatsapp text, p_pais text, p_acepta_whatsapp boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo     uuid := (select auth.uid());
  v_nombre text := regexp_replace(trim(coalesce(p_nombre, '')), '\s+', ' ', 'g');
  v_wa     text := regexp_replace(coalesce(p_whatsapp, ''), '[\s().-]', '', 'g');
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
  if v_wa !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'El WhatsApp no es válido. Usa el código de país y el número, solo dígitos (por ejemplo +593 y 991234567).';
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

-- =====================================================================
-- 4. ENLACES DE SOPORTE (reemplazan a la constante SOPORTE_WHATSAPP)
-- =====================================================================
create table if not exists public.enlaces_soporte (
  clave  text primary key check (clave in ('telegram', 'linktree', 'whatsapp', 'correo')),
  valor  text,
  activo boolean not null default false
);

insert into public.enlaces_soporte (clave, valor, activo) values
  ('telegram', null, false), ('linktree', null, false), ('whatsapp', null, false), ('correo', null, false)
on conflict (clave) do nothing;

create or replace function public.admin_guardar_enlace(p_clave text, p_valor text, p_activo boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_valor text := nullif(trim(coalesce(p_valor, '')), '');
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
      v_valor := regexp_replace(v_valor, '[\s+().-]', '', 'g');
      if v_valor !~ '^[1-9][0-9]{7,14}$' then
        raise exception 'El WhatsApp de soporte debe tener solo dígitos, con el código de país (por ejemplo 593991234567).';
      end if;
    end if;
    if p_clave = 'correo' and v_valor !~* '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
      raise exception 'El correo de soporte no es válido.';
    end if;
  end if;

  update public.enlaces_soporte set valor = v_valor, activo = coalesce(p_activo, false) where clave = p_clave;
end;
$$;

-- WhatsApp de soporte para la portada (sin sesión): solo el número si está activo.
create or replace function public.whatsapp_soporte()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select valor from public.enlaces_soporte where clave = 'whatsapp' and activo and valor is not null;
$$;

-- =====================================================================
-- 5. RLS Y GRANTs
-- =====================================================================
alter table public.tareas_historial enable row level security;
alter table public.enlaces_soporte  enable row level security;

drop policy if exists "historial: ver las mías" on public.tareas_historial;
create policy "historial: ver las mías"
  on public.tareas_historial for select to authenticated
  using (regalador_id = (select auth.uid()) or recibidor_id = (select auth.uid()));

drop policy if exists "historial: admin lee" on public.tareas_historial;
create policy "historial: admin lee"
  on public.tareas_historial for select to authenticated
  using (public.es_admin());

drop policy if exists "enlaces_soporte: leer con sesión" on public.enlaces_soporte;
create policy "enlaces_soporte: leer con sesión"
  on public.enlaces_soporte for select to authenticated using (true);

revoke all on table public.tareas_historial, public.enlaces_soporte from anon, authenticated;
grant select on table public.tareas_historial to authenticated;
grant select on table public.enlaces_soporte  to authenticated;

revoke execute on function public.confirmar_tarea(uuid)                              from public, anon;
revoke execute on function public.mi_historial(text, integer, integer)               from public, anon;
revoke execute on function public.mi_resumen_perfil()                                from public, anon;
revoke execute on function public.mi_grupo_resumen(integer)                          from public, anon;
revoke execute on function public.actualizar_mi_perfil(text, text, text, boolean)    from public, anon;
revoke execute on function public.admin_guardar_enlace(text, text, boolean)          from public, anon;
revoke execute on function public.whatsapp_soporte()                                 from public;

grant execute on function public.confirmar_tarea(uuid)                              to authenticated;
grant execute on function public.mi_historial(text, integer, integer)               to authenticated;
grant execute on function public.mi_resumen_perfil()                                to authenticated;
grant execute on function public.mi_grupo_resumen(integer)                          to authenticated;
grant execute on function public.actualizar_mi_perfil(text, text, text, boolean)    to authenticated;
grant execute on function public.admin_guardar_enlace(text, text, boolean)          to authenticated;
grant execute on function public.whatsapp_soporte()                                 to anon, authenticated;

notify pgrst, 'reload schema';
