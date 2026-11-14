-- =====================================================================
-- Sistema Siembra tu Futuro — 06_whatsapp_corregido.sql
-- Ejecutar DESPUÉS de 05_participar_plazos.sql. Se puede volver a ejecutar sin problema.
-- Reemplaza whatsapp_de():
--   * El WhatsApp del RECIBIDOR lo ven siempre los miembros de su grupo.
--   * El recibidor ve el WhatsApp de los regaladores de SU grupo (si aceptaron compartirlo).
--   * Constructores y regaladores NO ven el WhatsApp de otros compañeros.
--   * El administrador y la propia persona siempre lo ven.
-- La tabla perfiles sigue cerrada.
-- =====================================================================
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
      -- el WhatsApp del RECIBIDOR se ve siempre para los miembros de su grupo
      or exists (
        select 1
        from public.posiciones yo
        join public.posiciones rec
          on rec.grupo_id = yo.grupo_id
         and rec.posicion = 'recibidor'
         and rec.user_id = p_user_id
        where yo.user_id = (select auth.uid())
      )
      -- el recibidor ve el de los regaladores de SU grupo (si aceptaron compartirlo)
      or (
        pe.acepta_whatsapp_visible
        and exists (
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
    );
$$;

revoke execute on function public.whatsapp_de(uuid) from public, anon;
grant execute on function public.whatsapp_de(uuid) to authenticated;

notify pgrst, 'reload schema';
