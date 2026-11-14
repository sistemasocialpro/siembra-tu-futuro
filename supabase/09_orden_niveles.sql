-- =====================================================================
-- Sistema Siembra tu Futuro — 09_orden_niveles.sql
-- Ejecutar DESPUÉS de 08_nivel_plantar.sql. Se puede volver a ejecutar sin problema.
--
-- Con el nivel Plantar (id 11, orden 4) los ids ya NO siguen el orden de los niveles.
-- Regla: el "nivel siguiente" es el de orden inmediatamente mayor; nunca id + 1.
-- Revisado: participar(), ascender_grupo(), confirmar_tarea() y mi_reloj() (07) ya usan
-- niveles.orden. Aquí se redefine nivel_habilitado() para que tampoco dependa de que los
-- números de orden sean seguidos (busca el nivel anterior por orden, aunque haya saltos).
-- =====================================================================

-- Nivel anterior según el orden (NULL si es el primero)
create or replace function public.nivel_anterior(p_nivel_id integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select ant.id
  from public.niveles n
  join public.niveles ant on ant.orden < n.orden
  where n.id = p_nivel_id
  order by ant.orden desc
  limit 1;
$$;

-- Nivel siguiente según el orden (NULL si es el último)
create or replace function public.nivel_siguiente(p_nivel_id integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select sig.id
  from public.niveles n
  join public.niveles sig on sig.orden > n.orden
  where n.id = p_nivel_id
  order by sig.orden
  limit 1;
$$;

-- Habilitado: el primer nivel (el de menor orden), o el siguiente a uno donde la persona
-- completó su ciclo (ciclos_completados del nivel anterior por orden).
create or replace function public.nivel_habilitado(p_user_id uuid, p_nivel_id integer)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (select 1 from public.niveles where id = p_nivel_id) then false
    when public.nivel_anterior(p_nivel_id) is null then true
    else exists (
      select 1 from public.ciclos_completados c
      where c.user_id = p_user_id and c.nivel_id = public.nivel_anterior(p_nivel_id)
    )
  end;
$$;

revoke execute on function public.nivel_anterior(integer)          from public, anon, authenticated;
revoke execute on function public.nivel_siguiente(integer)         from public, anon, authenticated;
revoke execute on function public.nivel_habilitado(uuid, integer)  from public, anon, authenticated;

-- Comprobación: deben verse 11 niveles en este orden
do $$
begin
  if (select count(*) from public.niveles) <> 11 or not exists (select 1 from public.niveles where nombre = 'Plantar') then
    raise notice 'Atención: no hay 11 niveles con Plantar. Ejecuta antes 08_nivel_plantar.sql.';
  end if;
end $$;

notify pgrst, 'reload schema';

select orden, id, nombre, meta_tareas from public.niveles order by orden;
