-- =====================================================================
-- 28_aviso_al_entrar.sql  (va DESPUÉS de 27_avisos_seguir.sql)
-- 1) El aviso "¡[nombre] volvió a sembrar!" sale cuando la persona ENTRA de verdad al nivel que
--    repite como regalador, sea cual sea el camino: al tocar Repetir, cuando el admin la asigna desde
--    la lista de espera, o cuando se libera un lugar y la colocan. Lo hace un trigger en posiciones
--    (antes lo hacía repetir_nivel, que ahora ya no lo llama, para no avisar dos veces).
-- 2) Ya no existe "Ahora no": la tarjeta queda en Inicio hasta que la persona acepta o hasta que el
--    lugar lo ocupa otra persona. Los avisos que quedaron ocultos con el 27 vuelven a mostrarse.
-- Se puede volver a ejecutar sin problema.
-- =====================================================================

-- =====================================================================
-- 1. AVISO AL ENTRAR (trigger)
-- =====================================================================
-- ¿La persona está repitiendo ese nivel? (ya alcanzó un nivel de orden mayor, o ya lo completó)
create or replace function public.esta_repitiendo(p_user_id uuid, p_nivel_id integer)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.ciclos_completados c where c.user_id = p_user_id and c.nivel_id = p_nivel_id)
      or exists (
        select 1
        from public.niveles n
        join public.niveles yo_n on yo_n.id = p_nivel_id
        where n.orden > yo_n.orden
          and (exists (select 1 from public.posiciones p where p.user_id = p_user_id and p.nivel_id = n.id)
               or exists (select 1 from public.ciclos_completados c where c.user_id = p_user_id and c.nivel_id = n.id))
      );
$$;

create or replace function public.aviso_al_entrar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Solo en grupos normales (en el grupo repetido del fundador su equipo entra automático)
  if exists (select 1 from public.grupos g where g.id = new.grupo_id and g.tipo = 'normal')
     and public.esta_repitiendo(new.user_id, new.nivel_id) then
    perform public.crear_avisos_seguir(new.user_id, new.nivel_id);
  end if;
  return null;
end;
$$;

drop trigger if exists posiciones_aviso_al_entrar on public.posiciones;
create trigger posiciones_aviso_al_entrar
  after update of user_id on public.posiciones
  for each row
  when (new.user_id is not null and old.user_id is distinct from new.user_id and new.posicion like 'regalador%')
  execute function public.aviso_al_entrar();

-- =====================================================================
-- 2. SIN "AHORA NO": los avisos ocultos vuelven a pendientes (se ven otra vez en Inicio)
-- =====================================================================
update public.avisos_seguir set estado = 'pendiente' where estado = 'oculto';

-- =====================================================================
-- 3. repetir_nivel (27) sin la llamada a crear_avisos_seguir (ahora la hace el trigger)
-- =====================================================================
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
    -- (28) El aviso a sus referidos lo crea el trigger posiciones_aviso_al_entrar cuando entra
  end if;
  insert into public.repeticiones (user_id, nivel_id, modo)
  values (v_yo, p_nivel_id, case when v_perfil.es_fundador then 'equipo' else 'regalador' end);
  return v_res;
end;
$$;


-- =====================================================================
-- 4. PERMISOS
-- =====================================================================
revoke execute on function public.esta_repitiendo(uuid, integer)  from public, anon, authenticated;
revoke execute on function public.aviso_al_entrar()               from public, anon, authenticated;
revoke execute on function public.repetir_nivel(integer)          from public, anon;
grant  execute on function public.repetir_nivel(integer)          to authenticated;

notify pgrst, 'reload schema';
