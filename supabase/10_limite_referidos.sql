-- =====================================================================
-- Sistema Siembra tu Futuro — 10_limite_referidos.sql
-- Ejecutar DESPUÉS de 01 a 09. Se puede volver a ejecutar sin problema.
--
-- Regla: cada patrocinador (perfiles.invitado_por) puede tener como máximo 2 referidos
-- ACTIVOS a la vez. "Activo" = su perfil existe: cuando un referido borra su cuenta o el
-- administrador lo elimina, su fila de perfiles desaparece (on delete cascade desde
-- auth.users) y el cupo se libera solo. No se agregan columnas nuevas.
--
-- Cierre real en la base: trigger BEFORE INSERT / UPDATE OF invitado_por en perfiles.
-- (El registro crea el perfil desde el trigger de auth.users; si este trigger lo rechaza,
-- toda la creación de la cuenta se deshace.)
-- =====================================================================

-- Cantidad de referidos activos de una persona (interna)
create or replace function public.contar_referidos(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.perfiles where invitado_por = p_user_id;
$$;

-- ¿Se puede registrar alguien con este código? Solo true/false, sin datos de nadie.
create or replace function public.referido_disponible(p_codigo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select public.contar_referidos(p.id) < 2
    from public.perfiles p
    where p.codigo_invitacion = upper(trim(coalesce(p_codigo, '')))
  ), false);
$$;

-- Mis referidos activos (para "Referidos: X de 2" en el panel)
create or replace function public.mis_referidos()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select public.contar_referidos((select auth.uid()));
$$;

-- Trigger: rechaza el 3.er referido activo. Bloquea la fila del patrocinador (FOR UPDATE)
-- antes de contar, así dos registros simultáneos con el mismo link se ordenan uno tras otro
-- y el segundo ya ve al primero.
-- Se aplica igual si alguien (el administrador desde el SQL Editor u otra función) cambia
-- el patrocinador de una persona. Cuentas sin patrocinador (fundadores, administradores)
-- no se bloquean.
create or replace function public.limitar_referidos()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.invitado_por is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.invitado_por is not distinct from old.invitado_por then
    return new;
  end if;

  perform 1 from public.perfiles where id = new.invitado_por for update;

  if (select count(*) from public.perfiles
       where invitado_por = new.invitado_por and id <> new.id) >= 2 then
    raise exception 'Tu patrocinador ya tiene sus 2 referidos y no puede recibir más por ahora. Por favor contáctate con la persona que te invitó.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists perfiles_limitar_referidos on public.perfiles;
create trigger perfiles_limitar_referidos
  before insert or update of invitado_por on public.perfiles
  for each row execute function public.limitar_referidos();

-- Permisos
revoke execute on function public.contar_referidos(uuid)    from public, anon, authenticated;
revoke execute on function public.limitar_referidos()       from public, anon, authenticated;
revoke execute on function public.referido_disponible(text) from public;
revoke execute on function public.mis_referidos()           from public, anon;

grant execute on function public.referido_disponible(text) to anon, authenticated;
grant execute on function public.mis_referidos()           to authenticated;

notify pgrst, 'reload schema';

-- Patrocinadores que YA tenían más de 2 referidos antes de esta regla (no se borra a nadie;
-- solo no podrán recibir más hasta bajar de 2):
-- select p.nombre_usuario, count(*) from public.perfiles h join public.perfiles p on p.id = h.invitado_por
-- group by p.nombre_usuario having count(*) > 2;
