-- !! OBSOLETO desde 25_repetir_nivel.sql: NO volver a ejecutar este archivo (crea las vueltas que el 25 quita).
--    Se deja solo como historial. Su contenido vigente (sin vueltas) está en el 25.
-- =====================================================================
-- Sistema Siembra tu Futuro — 19_invitados_por_vuelta.sql
-- Ejecutar DESPUÉS de 18_vueltas.sql. Se puede volver a ejecutar sin problema.
-- Si re-ejecutas 18, vuelve a ejecutar este archivo después.
--
-- Solo redefine participar():
--   1. Un invitado sigue a su patrocinador SOLO en las posiciones de la vuelta en que fue
--      invitado (perfiles.invitado_vuelta). Antes, si el patrocinador ya no estaba en ese nivel
--      en esa vuelta, el invitado caía en su grupo de otra vuelta (por ejemplo, debajo de él en
--      su vuelta 2) y ocupaba los lugares que son para sus 2 personas nuevas de esa vuelta.
--   2. El derrame nunca usa los lugares que cuelgan de una posición del propio patrocinador.
--   Si no hay lugar con el patrocinador en esa vuelta: quien repite el nivel cae por derrame;
--   quien entra por primera vez va a lista de espera (como antes).
--   No cambia tablas ni datos.
-- =====================================================================

create or replace function public.participar(p_nivel_id integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo         uuid := (select auth.uid());
  v_nivel      public.niveles;
  v_perfil     public.perfiles;
  v_pos_inv    public.posiciones;
  v_libre      public.posiciones;
  v_grupo      uuid;
  v_recibidor  uuid;
  v_primero    boolean;
  v_vuelta     integer;
  v_repite     boolean;
  v_nueva      boolean := false;
  v_derrame    boolean := false;
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

  -- ¿Ya completó este nivel en otra vuelta? Entonces "repite" (derrame si no hay lugar con su invitador)
  v_repite := exists (select 1 from public.ciclos_completados where user_id = v_yo and nivel_id = p_nivel_id);

  -- Volver al nivel 1 después de completarlo: empieza una vuelta nueva
  if v_vuelta > v_perfil.vuelta_actual then
    update public.perfiles set vuelta_actual = v_vuelta where id = v_yo;
    v_nueva := true;
  end if;

  -- (Niveles 2 en adelante) Fundador: crea su propio grupo como recibidor (también si repite)
  if not v_primero and v_perfil.es_fundador then
    v_grupo := public.crear_grupo_vacio(p_nivel_id);
    select * into v_libre from public.posiciones where grupo_id = v_grupo and posicion = 'recibidor';
  else
    -- Lugar del invitador en este nivel, SOLO en la vuelta en que me invitó (19): sus vueltas
    -- nuevas son para sus 2 personas nuevas de esa vuelta.
    if v_perfil.invitado_por is not null then
      select po.* into v_pos_inv
      from public.posiciones po
      join public.grupos g on g.id = po.grupo_id and g.estado = 'activo'
      where po.user_id = v_perfil.invitado_por and po.nivel_id = p_nivel_id
        and po.vuelta = coalesce(v_perfil.invitado_vuelta, 1)
      limit 1;
    end if;

    if v_pos_inv.id is not null then
      if v_primero then
        -- Solo regaladores: primero debajo del invitador (si es constructor), luego el primero libre
        select p.* into v_libre
        from public.posiciones p
        where p.grupo_id = v_pos_inv.grupo_id
          and p.user_id is null
          and p.posicion like 'regalador%'
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

    -- Derrame: quien repite el nivel va al primer regalador libre de cualquier grupo activo
    if v_libre.id is null and v_repite then
      select p.* into v_libre
      from public.posiciones p
      join public.grupos g on g.id = p.grupo_id and g.estado = 'activo'
      where p.nivel_id = p_nivel_id
        and p.user_id is null
        and p.posicion like 'regalador%'
        and exists (select 1 from public.posiciones c
                    where c.grupo_id = p.grupo_id and c.posicion = p.cuelga_de and c.user_id is not null)
        and not exists (select 1 from public.posiciones yo where yo.grupo_id = p.grupo_id and yo.user_id = v_yo)
        -- (19) nunca debajo de mi propio patrocinador: esos lugares son para sus invitados de esa vuelta
        and not exists (select 1 from public.posiciones inv
                        where inv.grupo_id = p.grupo_id and inv.posicion = p.cuelga_de
                          and inv.user_id = v_perfil.invitado_por)
      order by g.creado_en,
               array_position(array['regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'], p.posicion)
      limit 1
      for update of p skip locked;
      v_derrame := v_libre.id is not null;
    end if;
  end if;

  if v_nueva then
    perform public.notificar(v_yo, 'Empezaste la vuelta ' || v_vuelta,
      format('Volviste al nivel %s y empezaste tu vuelta %s. Tu enlace de invitación vuelve a tener lugar para 2 personas nuevas, que te seguirán en los niveles de esta vuelta.',
             v_nivel.nombre, v_vuelta));
  end if;

  -- Sin lugar -> lista de espera (de esta vuelta)
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
                            'vuelta', v_vuelta, 'nueva_vuelta', v_nueva, 'derrame', v_derrame);
end;
$$;

revoke execute on function public.participar(integer) from public, anon;
grant  execute on function public.participar(integer) to authenticated;

notify pgrst, 'reload schema';
