-- =====================================================================
-- Sistema Siembra tu Futuro — 06_whatsapp_regaladores.sql
-- Ejecutar DESPUÉS de 01 a 05. Se puede volver a ejecutar sin problema.
-- El recibidor puede ver el WhatsApp de los regaladores de SU grupo
-- (para escribirles desde "Pendiente de aprobación de tareas recibidas").
-- =====================================================================

-- whatsapp_de(p_user_id) devuelve el WhatsApp solo si quien pregunta:
--   1) es administrador, o
--   2) es la propia persona, o
--   3) tiene una posición en un grupo donde la persona buscada es el RECIBIDOR, o
--   4) es el RECIBIDOR de un grupo donde la persona buscada ocupa una casilla regalador_N.
-- En los casos 3 y 4 la persona buscada debe haber aceptado que su grupo vea su WhatsApp.
-- Constructores y regaladores NO ven el WhatsApp de otros miembros (salvo el del recibidor),
-- y el recibidor no ve el de personas de otros grupos. La tabla perfiles sigue cerrada.
create or replace function public.whatsapp_de(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select pe.whatsapp
  from public.perfiles pe
  where pe.id = p_user_id
    and (
      public.es_admin()
      or pe.id = (select auth.uid())
      or (
        pe.acepta_whatsapp_visible
        and (
          -- 3) la persona buscada es el recibidor de un grupo donde yo tengo posición
          exists (
            select 1
            from public.posiciones yo
            join public.posiciones rec
              on rec.grupo_id = yo.grupo_id
             and rec.posicion = 'recibidor'
             and rec.user_id = p_user_id
            where yo.user_id = (select auth.uid())
          )
          -- 4) yo soy el recibidor y la persona buscada es regalador de ESE grupo
          or exists (
            select 1
            from public.posiciones yo
            join public.posiciones reg
              on reg.grupo_id = yo.grupo_id
             and reg.posicion in ('regalador_1', 'regalador_2', 'regalador_3', 'regalador_4')
             and reg.user_id = p_user_id
            where yo.user_id = (select auth.uid())
              and yo.posicion = 'recibidor'
          )
        )
      )
    );
$$;

-- Mismos permisos de siempre: solo usuarios con sesión
revoke execute on function public.whatsapp_de(uuid) from public, anon;
grant execute on function public.whatsapp_de(uuid) to authenticated;

notify pgrst, 'reload schema';
