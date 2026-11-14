-- =====================================================================
-- Sistema Siembra tu Futuro — nivel "Plantar" (50 tareas) entre Sembrar y Crecer.
-- Se puede ejecutar más de una vez. Los ids de los niveles existentes NO cambian
-- (así no se rompen grupos ni posiciones): Plantar es id 11 con orden 4,
-- y los niveles Crecer..Abundancia suben un lugar en "orden".
-- =====================================================================
do $$
begin
  if not exists (select 1 from public.niveles where nombre = 'Plantar') then
    -- orden es único: se mueve en dos pasos para no chocar
    update public.niveles set orden = orden + 100 where orden >= 4;
    update public.niveles set orden = orden - 99  where orden >= 104;
    insert into public.niveles (id, orden, nombre, meta_tareas) values (11, 4, 'Plantar', 50);
  end if;
end $$;

select id, orden, nombre, meta_tareas from public.niveles order by orden;
