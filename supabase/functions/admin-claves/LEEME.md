# Edge Function `admin-claves`

Sirve para dos botones de la ficha del usuario en **Administración → Usuarios**:

- **Cambiar clave**: genera una clave temporal (por ejemplo `Siembra-4827`), la muestra una sola vez al administrador y obliga a la persona a crear su propia clave al entrar.
- **Copiar enlace de recuperación**: genera el enlace para que la persona cree su clave nueva (el mismo de "¿Olvidaste tu clave?").

Solo la pueden usar administradores. Usa la clave `service_role`, pero **esa clave nunca está en el código ni en el navegador**: Supabase se la entrega a la función como variable del servidor (`SUPABASE_SERVICE_ROLE_KEY`). No tienes que copiarla ni pegarla en ningún lado.

Antes de desplegarla ejecuta `supabase/33_claves_admin.sql` en el SQL Editor (después del 32).

---

## Opción A: desde el panel de Supabase (sin instalar nada)

1. Entra a https://supabase.com/dashboard y abre tu proyecto.
2. En el menú de la izquierda toca **Edge Functions**.
3. Toca **Deploy a new function** → **Via Editor** (crear en el editor).
4. Como nombre escribe exactamente: `admin-claves`
5. Borra el código de ejemplo y pega TODO el contenido del archivo `supabase/functions/admin-claves/index.ts`.
6. Toca **Deploy function** y espera a que diga que quedó desplegada.
7. En la función, entra a **Details** (o **Settings**) y deja **Enforce JWT verification / Verify JWT** **activado** (viene así por defecto). Así nadie sin sesión puede llamarla.
8. Listo. No hay que agregar secretos: `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` ya están disponibles para la función.

## Opción B: con la consola (Supabase CLI)

1. Instala la CLI: https://supabase.com/docs/guides/cli (en Windows, por ejemplo, con `scoop install supabase`, o usa `npx supabase …`).
2. En la carpeta del proyecto: `supabase login` (abre el navegador para entrar).
3. Despliega (cambia `TU_REF` por la referencia del proyecto, la que aparece en la URL del panel, `https://supabase.com/dashboard/project/TU_REF`):

   ```
   supabase functions deploy admin-claves --project-ref TU_REF
   ```
4. Deja la verificación de JWT como viene (activada). No uses `--no-verify-jwt`.

---

## Revisar la configuración de Auth (una sola vez)

En **Authentication → URL Configuration**:

- **Site URL**: `https://sistemasocialpro.github.io/siembra-tu-futuro/`
- **Redirect URLs**: debe estar `https://sistemasocialpro.github.io/siembra-tu-futuro/` (es la misma que ya usa "¿Olvidaste tu clave?").

El enlace de recuperación vence según **Authentication → Email → Email OTP Expiration** (por defecto 1 hora) y sirve una sola vez.

## Probar

1. Entra como administrador → **Administración → Usuarios** → toca a una persona de prueba.
2. **Cambiar clave** → confirma → aparece la clave temporal con **Copiar** y **Enviar por WhatsApp**.
3. En otra ventana privada entra con el usuario de esa persona y la clave temporal: debe pedirte **Crea tu clave nueva** antes de entrar al panel.
4. **Copiar enlace de recuperación** → abre el enlace en una ventana privada: debe pedir la clave nueva.
5. En **Administración → Registro** aparecen "Clave temporal generada", "Enlace de recuperación generado" y "Clave nueva creada por el socio" (sin la clave).

## Si algo falla

- *"La función admin-claves todavía no está desplegada"*: revisa que el nombre sea exactamente `admin-claves`.
- *"Solo un administrador puede cambiar claves"*: la cuenta con la que entraste no está en `public.administradores`.
- *"No se pudo crear el enlace"*: revisa la Site URL y las Redirect URLs del paso anterior.
- Para ver los errores de la función: **Edge Functions → admin-claves → Logs**.
