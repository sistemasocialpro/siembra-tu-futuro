// Configuración general del Sistema Siembra tu Futuro.
// La clave publishable es pública: puede ir en el código. NUNCA pongas aquí la clave service_role.

const SUPABASE_URL = 'https://ghhtxdgavyocdisjatjx.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_DvJdQ2Z9f5rtlSE4dnxXWA_q5X-hmxM';

// Los enlaces de soporte (Telegram, Linktree, WhatsApp, correo) ya no van aquí: se editan en
// Administración → Configuración → Enlaces de soporte (tabla enlaces_soporte).

// Enlaces a redes sociales de la portada. Si queda vacío, el botón no se muestra.
const REDES = {
  instagram: '',
  tiktok: ''
};

// ---- Sesión: "Recordarme" ----
// Con "Recordarme" la sesión se guarda en localStorage (sobrevive al cerrar el navegador);
// sin él, en sessionStorage (se borra al cerrar la pestaña).
const CLAVE_RECORDAR = 'stf_recordar';

function leerRecordar() {
  try { return localStorage.getItem(CLAVE_RECORDAR) !== '0'; } catch (e) { return true; }
}

function guardarRecordar(valor) {
  try { localStorage.setItem(CLAVE_RECORDAR, valor ? '1' : '0'); } catch (e) { /* sin almacenamiento */ }
}

function almacenamientoSesion() {
  try {
    const s = leerRecordar() ? window.localStorage : window.sessionStorage;
    const prueba = '__stf_prueba__';
    s.setItem(prueba, '1');
    s.removeItem(prueba);
    return s;
  } catch (e) {
    return undefined; // supabase-js usará memoria
  }
}

// op.leerEnlace = true solo al volver del correo de "¿Olvidaste tu clave?": el cliente lee el
// enlace (#access_token…&type=recovery) y avisa con el evento PASSWORD_RECOVERY.
function crearClienteSupabase(op) {
  return window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: {
      storage: almacenamientoSesion(),
      persistSession: true,
      autoRefreshToken: true,
      flowType: 'implicit',
      detectSessionInUrl: !!(op && op.leerEnlace)
    }
  });
}

// ---- A dónde entra cada cuenta ----
// Participante (tiene perfil) -> panel.html. Administrador sin perfil (cuenta separada que no
// participa, ver supabase/15_admin_separado.sql) -> admin.html. Sin perfil y sin ser admin -> null.
async function paginaDeInicio(sb, userId) {
  const { data: perfil, error } = await sb.from('perfiles').select('id').eq('id', userId).maybeSingle();
  if (perfil) {
    // (33) Entró con una clave temporal del administrador: primero crea su propia clave
    const { data: debe } = await sb.rpc('debo_cambiar_clave');
    if (debe === true) return 'index.html?cambiar_clave=1';
  }
  if (error || perfil) return 'panel.html';
  const { data: esAdmin } = await sb.rpc('es_admin');
  return esAdmin === true ? 'admin.html' : null;
}

// ---- WhatsApp: misma lógica que public.normalizar_whatsapp() (14_whatsapp_formato.sql) ----
// Ecuador acepta 0991234567, 991234567, 593991234567, +593…, 00593… (con o sin espacios).
// Otros países: con + y código de país. Devuelve "+593991234567" o null si no es válido.
// La base de datos vuelve a normalizar al guardar y es quien manda.
function normalizarWhatsApp(texto, pais) {
  let v = String(texto || '').replace(/[\s().-]/g, '');
  if (v === '') return null;
  if (v.startsWith('00')) v = '+' + v.slice(2);
  const p = String(pais || '').trim() || 'Ecuador';
  if (!v.startsWith('+') && (p === 'Ecuador' || p === 'EC')) {
    if (/^0\d{9}$/.test(v)) v = '+593' + v.slice(1);
    else if (/^593\d{9}$/.test(v)) v = '+' + v;
    else if (/^9\d{8}$/.test(v)) v = '+593' + v;
  }
  if (!/^\+[1-9]\d{7,14}$/.test(v)) return null;
  if (v.startsWith('+593') && !/^\+5939\d{8}$/.test(v)) return null;
  return v;
}

// Mensaje de error para el campo de WhatsApp ('' si es válido)
function errorWhatsApp(texto, pais) {
  const limpio = String(texto || '').replace(/[\s().-]/g, '');
  if (!limpio) return 'Escribe tu número de WhatsApp.';
  if (normalizarWhatsApp(texto, pais)) return '';
  const p = String(pais || '').trim() || 'Ecuador';
  const esEcuador = /^(\+|00)?593/.test(limpio) || (!/^(\+|00)/.test(limpio) && (p === 'Ecuador' || p === 'EC'));
  return esEcuador
    ? 'Escribe un celular de Ecuador, por ejemplo 0999999999.'
    : 'Para otros países escribe el número con + y el código de país.';
}

// Los enlaces wa.me usan el número solo con dígitos (593991234567): aquí se quita el "+".
function enlaceWhatsApp(numero, texto) {
  return 'https://wa.me/' + String(numero).replace(/\D/g, '') + '?text=' + encodeURIComponent(texto);
}
