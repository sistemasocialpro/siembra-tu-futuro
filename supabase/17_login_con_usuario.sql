-- =====================================================================
-- Sistema Siembra tu Futuro — 17_login_con_usuario.sql
-- Ejecutar DESPUÉS de 01 a 15. Se puede volver a ejecutar sin problema.
--
-- Entrar con USUARIO + contraseña (Supabase Auth entra con correo):
--   * correo_para_login(usuario, clave): devuelve el correo de ese usuario SOLO si la
--     contraseña es correcta. Así nadie puede averiguar el correo de otra persona sabiendo
--     solo su nombre de usuario (los usuarios se ven en los grupos y en "Te invitó").
--     La web usa ese correo para signInWithPassword y nunca lo muestra en pantalla.
--   * Freno contra adivinar claves: tras 5 intentos fallidos con un mismo usuario en
--     15 minutos, se bloquea ese usuario 15 minutos (tabla interna intentos_login).
--   * No cambia tablas existentes ni la recuperación de contraseña por correo.
-- =====================================================================

-- ---------- Intentos fallidos (interna, nadie la lee desde la web) ----------
create table if not exists public.intentos_login (
  id         bigint generated always as identity primary key,
  usuario    text not null,
  intento_en timestamptz not null default now()
);
create index if not exists intentos_login_usuario_idx
  on public.intentos_login (usuario, intento_en);

alter table public.intentos_login enable row level security;
revoke all on table public.intentos_login from anon, authenticated;
-- Sin políticas ni GRANT: solo la usa la función de abajo.

-- ---------- Correo para iniciar sesión con usuario ----------
create or replace function public.correo_para_login(p_usuario text, p_clave text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_usuario  text := lower(trim(coalesce(p_usuario, '')));
  v_email    text;
  v_hash     text;
  v_fallidos int;
begin
  if v_usuario = '' or coalesce(p_clave, '') = '' then
    return null;
  end if;

  -- Limpieza de intentos viejos
  delete from public.intentos_login where intento_en < now() - interval '1 day';

  select count(*) into v_fallidos
  from public.intentos_login i
  where i.usuario = v_usuario and i.intento_en > now() - interval '15 minutes';
  if v_fallidos >= 5 then
    raise exception 'Demasiados intentos fallidos con ese usuario. Espera 15 minutos y vuelve a intentarlo.'
      using errcode = 'P0001';
  end if;

  select u.email::text, u.encrypted_password
    into v_email, v_hash
  from public.perfiles pe
  join auth.users u on u.id = pe.id
  where pe.nombre_usuario = v_usuario;

  if v_email is not null and v_hash is not null and v_hash <> ''
     and extensions.crypt(p_clave, v_hash) = v_hash then
    delete from public.intentos_login where usuario = v_usuario;
    return v_email;
  end if;

  -- Usuario inexistente o clave incorrecta: mismo resultado (null) y se cuenta el intento
  insert into public.intentos_login (usuario) values (v_usuario);
  return null;
end;
$$;

revoke execute on function public.correo_para_login(text, text) from public;
grant  execute on function public.correo_para_login(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
