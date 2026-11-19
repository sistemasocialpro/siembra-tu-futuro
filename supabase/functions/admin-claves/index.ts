// Edge Function "admin-claves" (Supabase). Solo para administradores.
//   POST { accion: 'clave_temporal', user_id }                 -> { clave, nombre_usuario, whatsapp }
//   POST { accion: 'enlace_recuperacion', user_id, redirect_to } -> { enlace, nombre_usuario, whatsapp }
//
// La clave service_role NO está en este archivo ni en la web: Supabase la entrega a la función
// como variable de entorno (SUPABASE_SERVICE_ROLE_KEY) y solo se usa aquí, en el servidor.
// Quién pide se comprueba con SU sesión: las funciones SQL del 33 verifican es_admin().
// La clave temporal se devuelve una sola vez y nunca se guarda (ni en la base ni en el registro).
import { createClient } from 'npm:@supabase/supabase-js@2.50.0';

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function respuesta(cuerpo: unknown, estado = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8' },
  });
}

// "Siembra-" + 4 dígitos al azar (con el generador seguro del sistema)
function claveTemporal(): string {
  const n = new Uint32Array(1);
  crypto.getRandomValues(n);
  return 'Siembra-' + String(n[0] % 10000).padStart(4, '0');
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function atender(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return respuesta({ error: 'Método no permitido.' }, 405);

  const url = Deno.env.get('SUPABASE_URL');
  const servicio = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const publica = Deno.env.get('SUPABASE_ANON_KEY') ?? servicio;
  if (!url || !servicio || !publica) return respuesta({ error: 'La función no está configurada en Supabase.' }, 500);

  const autorizacion = req.headers.get('Authorization') ?? '';
  if (!autorizacion.startsWith('Bearer ')) return respuesta({ error: 'Debes iniciar sesión.' }, 401);

  let datos: { accion?: string; user_id?: string; redirect_to?: string };
  try {
    datos = await req.json();
  } catch {
    return respuesta({ error: 'Pedido inválido.' }, 400);
  }
  const { accion, user_id, redirect_to } = datos;
  if (!user_id || !UUID.test(user_id)) return respuesta({ error: 'Elige un usuario.' }, 400);
  if (accion !== 'clave_temporal' && accion !== 'enlace_recuperacion') return respuesta({ error: 'Acción desconocida.' }, 400);

  // Cliente con la sesión del administrador que pide (para las comprobaciones y el registro)
  const comoAdmin = createClient(url, publica, {
    global: { headers: { Authorization: autorizacion } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Cliente con la service_role (solo para cambiar la clave o crear el enlace)
  const admin = createClient(url, servicio, { auth: { persistSession: false, autoRefreshToken: false } });

  // 1) ¿Es administrador? ¿Existe la persona y no es administradora? (lanza error si no)
  const prep = await comoAdmin.rpc('admin_preparar_clave', { p_user_id: user_id });
  if (prep.error) return respuesta({ error: prep.error.message }, 403);
  const persona = prep.data as { nombre_usuario: string; whatsapp: string | null; correo: string | null };

  if (accion === 'clave_temporal') {
    const clave = claveTemporal();
    const cambio = await admin.auth.admin.updateUserById(user_id, { password: clave });
    if (cambio.error) return respuesta({ error: 'No se pudo poner la clave temporal: ' + cambio.error.message }, 500);
    // 2) Obliga a cambiarla al entrar, cierra sesiones, avisa y registra (sin la clave)
    const fin = await comoAdmin.rpc('admin_clave_temporal_lista', { p_user_id: user_id });
    if (fin.error) return respuesta({ error: 'La clave se cambió, pero no se pudo marcar el cambio obligatorio: ' + fin.error.message }, 500);
    return respuesta({ clave, nombre_usuario: persona.nombre_usuario, whatsapp: persona.whatsapp });
  }

  // Enlace de recuperación (el mismo que llega por correo en "¿Olvidaste tu clave?")
  if (!persona.correo) return respuesta({ error: 'Esa persona no tiene correo.' }, 400);
  const enlace = await admin.auth.admin.generateLink({
    type: 'recovery',
    email: persona.correo,
    options: redirect_to ? { redirectTo: redirect_to } : undefined,
  });
  if (enlace.error || !enlace.data?.properties?.action_link) {
    return respuesta({ error: 'No se pudo crear el enlace: ' + (enlace.error?.message ?? 'sin enlace') }, 500);
  }
  const reg = await comoAdmin.rpc('admin_registrar_enlace_recuperacion', { p_user_id: user_id });
  if (reg.error) return respuesta({ error: reg.error.message }, 500);
  return respuesta({ enlace: enlace.data.properties.action_link, nombre_usuario: persona.nombre_usuario, whatsapp: persona.whatsapp });
}

Deno.serve(atender);
