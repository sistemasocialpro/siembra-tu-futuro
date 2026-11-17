// Utilidades compartidas por panel.html y admin.html
// (menú lateral, cerrar sesión, errores, ventanas, niveles y mapa del grupo)

const $ = (id) => document.getElementById(id);

// Crea un elemento. Los textos siempre van como textContent (nunca innerHTML).
function el(tag, attrs, ...hijos) {
  const e = document.createElement(tag);
  if (attrs) {
    Object.entries(attrs).forEach(([k, v]) => {
      if (v === null || v === undefined || v === false) return;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v === true ? '' : v);
    });
  }
  hijos.flat().forEach((h) => {
    if (h === null || h === undefined || h === false) return;
    e.appendChild(typeof h === 'string' ? document.createTextNode(h) : h);
  });
  return e;
}

function vaciar(nodo) { while (nodo.firstChild) nodo.removeChild(nodo.firstChild); }

function formatoFecha(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('es', { day: '2-digit', month: 'short', year: 'numeric' });
}

function formatoNumero(n) {
  return Number(n).toLocaleString('es', { maximumFractionDigits: 4 });
}

// "Hace 5 min", "Hace 3 h", "Ayer", "12 nov 2026"
function tiempoRelativo(iso) {
  const seg = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seg < 60) return 'Hace un momento';
  if (seg < 3600) return 'Hace ' + Math.floor(seg / 60) + ' min';
  if (seg < 86400) return 'Hace ' + Math.floor(seg / 3600) + ' h';
  if (seg < 172800) return 'Ayer';
  return formatoFecha(iso);
}

function normalizar(t) {
  return String(t || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
}

// Mensaje claro en español para errores de Supabase / red
function traducirErrorDatos(error) {
  if (!error) return 'Ocurrió un error inesperado. Inténtalo de nuevo.';
  const msg = String(error.message || '');
  const code = String(error.code || '');
  if (/failed to fetch|networkerror|network request failed|load failed/i.test(msg))
    return 'No hay conexión con el servidor. Revisa tu internet e inténtalo de nuevo.';
  if (code === 'P0001') return msg; // mensajes propios del SQL, ya en español
  if (code === '23505') return 'Ese usuario ya tiene una posición en este nivel.';
  if (code === '42501') return 'No tienes permiso para hacer esto.';
  if (code === 'PGRST202' || code === '42883' || code === '42P01' || code === '42703' || /could not find|does not exist/i.test(msg))
    return 'Falta configurar la base de datos (ejecuta los archivos SQL en Supabase).';
  if (/jwt|token/i.test(msg)) return 'Tu sesión expiró. Vuelve a iniciar sesión.';
  return 'Ocurrió un error: ' + msg;
}

async function copiarTexto(texto) {
  try {
    await navigator.clipboard.writeText(texto);
    return true;
  } catch (e) {
    const ta = document.createElement('textarea');
    ta.value = texto;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (e2) { ok = false; }
    ta.remove();
    return ok;
  }
}

// ---------- Sesión ----------
// Devuelve la sesión o redirige a index.html
async function exigirSesion(sb) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { location.replace('index.html'); return null; }
  sb.auth.onAuthStateChange((evento, s) => {
    // window.saliendoCuenta: al borrar la cuenta se redirige a index.html?cuenta=eliminada
    if ((evento === 'SIGNED_OUT' || !s) && !window.saliendoCuenta) location.replace('index.html');
  });
  return session;
}

// Páginas de participante (panel, perfil, info personal, academia, soporte): el administrador
// sin perfil (cuenta separada que no participa) va directo a admin.html.
async function exigirParticipante(sb) {
  const session = await exigirSesion(sb);
  if (!session) return null;
  const destino = await paginaDeInicio(sb, session.user.id);
  if (destino === 'admin.html') { location.replace('admin.html'); return null; }
  return session;
}

function iniciarCerrarSesion(sb) {
  document.querySelectorAll('[data-salir]').forEach((x) =>
    x.addEventListener('click', async (e) => {
      e.preventDefault();
      try { await sb.auth.signOut({ scope: 'local' }); } catch (err) { /* igual salimos */ }
      location.replace('index.html');
    })
  );
}

// ---------- Menú lateral (desplegable en celular) ----------
function iniciarMenuLateral() {
  const menu = $('menu');
  const btn = $('btn-menu');
  function abrir(si) {
    menu.classList.toggle('abierto', si);
    btn.setAttribute('aria-expanded', si ? 'true' : 'false');
    btn.setAttribute('aria-label', si ? 'Cerrar menú' : 'Abrir menú');
  }
  btn.addEventListener('click', (e) => { e.stopPropagation(); abrir(!menu.classList.contains('abierto')); });
  menu.addEventListener('click', (e) => { if (e.target.closest('a')) abrir(false); });
  document.addEventListener('click', (e) => {
    if (menu.classList.contains('abierto') && !menu.contains(e.target)) abrir(false);
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') abrir(false); });
}

// ---------- Ventanas (dialog) ----------
// confirmar({ titulo, texto (string o nodos), extra (nodo), boton, peligro }) -> Promise<boolean>
function confirmar(op) {
  let dlg = $('dlg-confirmar');
  if (!dlg) {
    dlg = el('dialog', { class: 'modal', id: 'dlg-confirmar', 'aria-labelledby': 'dlg-confirmar-titulo' },
      el('form', { method: 'dialog', class: 'modal-cuerpo' },
        el('h3', { id: 'dlg-confirmar-titulo' }),
        el('div', { id: 'dlg-confirmar-texto', class: 'modal-texto' }),
        el('div', { id: 'dlg-confirmar-extra' }),
        el('div', { class: 'modal-botones' },
          el('button', { type: 'submit', value: 'no', class: 'bo', id: 'dlg-confirmar-no', text: 'Cancelar' }),
          el('button', { type: 'submit', value: 'si', class: 'btn', id: 'dlg-confirmar-ok', text: 'Confirmar' })
        )
      )
    );
    document.body.appendChild(dlg);
  }
  $('dlg-confirmar-titulo').textContent = op.titulo;
  const texto = $('dlg-confirmar-texto');
  vaciar(texto);
  texto.append(...[].concat(op.texto || []));
  const extra = $('dlg-confirmar-extra');
  vaciar(extra);
  if (op.extra) extra.appendChild(op.extra);
  $('dlg-confirmar-no').textContent = op.cancelar || 'Cancelar';
  const ok = $('dlg-confirmar-ok');
  ok.textContent = op.boton || 'Confirmar';
  ok.className = op.peligro ? 'btn btn-peligro' : 'btn';
  dlg.returnValue = '';
  dlg.showModal();
  return new Promise((res) => {
    dlg.addEventListener('close', () => res(dlg.returnValue === 'si'), { once: true });
  });
}

// elegirDeLista({ titulo, sub, items: [{ titulo, sub, valor }], vacio }) -> Promise<valor|null>
function elegirDeLista(op) {
  let dlg = $('dlg-lista');
  if (!dlg) {
    dlg = el('dialog', { class: 'modal', id: 'dlg-lista', 'aria-labelledby': 'dlg-lista-titulo' },
      el('form', { method: 'dialog', class: 'modal-cuerpo' },
        el('h3', { id: 'dlg-lista-titulo' }),
        el('div', { class: 'mut', id: 'dlg-lista-sub' }),
        el('input', { class: 'in', id: 'dlg-lista-buscar', type: 'search', placeholder: 'Buscar…', 'aria-label': 'Buscar', autocomplete: 'off' }),
        el('ul', { class: 'lista-usuarios', id: 'dlg-lista-items' }),
        el('div', { class: 'modal-botones' },
          el('button', { type: 'submit', value: 'no', class: 'bo', text: 'Cancelar' })
        )
      )
    );
    document.body.appendChild(dlg);
  }
  const lista = $('dlg-lista-items');
  const buscar = $('dlg-lista-buscar');
  $('dlg-lista-titulo').textContent = op.titulo;
  $('dlg-lista-sub').textContent = op.sub || '';
  buscar.value = '';
  buscar.hidden = op.items.length < 6;
  let elegido = null;

  function pintar() {
    const q = normalizar(buscar.value.trim());
    const visibles = op.items.filter((it) => !q || normalizar(it.titulo + ' ' + (it.sub || '')).includes(q));
    vaciar(lista);
    if (!op.items.length) {
      lista.appendChild(el('li', { class: 'mut vacio', text: op.vacio || 'No hay opciones disponibles.' }));
      return;
    }
    if (!visibles.length) {
      lista.appendChild(el('li', { class: 'mut vacio', text: 'Nada coincide con la búsqueda.' }));
      return;
    }
    visibles.forEach((it) => {
      lista.appendChild(el('li', null,
        el('button', {
          type: 'button', class: 'item-usuario',
          onclick: () => { elegido = it.valor; dlg.close('elegido'); }
        },
          el('b', { text: it.titulo }),
          it.sub ? el('span', { class: 'mut', text: it.sub }) : null
        )
      ));
    });
  }

  buscar.oninput = pintar;
  buscar.onkeydown = (e) => { if (e.key === 'Enter') e.preventDefault(); };
  pintar();
  dlg.returnValue = '';
  dlg.showModal();
  if (!buscar.hidden) buscar.focus();
  return new Promise((res) => {
    dlg.addEventListener('close', () => res(elegido), { once: true });
  });
}

// ---------- Niveles ----------
// Color por NOMBRE (no por id ni por orden: el orden cambió al agregar Plantar)
const COLORES_NIVEL = {
  Terreno: '#15803d', Preparar: '#facc15', Sembrar: '#0d9488', Plantar: '#4d7c0f', Crecer: '#65a30d',
  Cuidar: '#16a34a', Producir: '#ca8a04', Recoger: '#0f766e', Expandir: '#84cc16', Prosperar: '#eab308',
  Abundancia: '#166534'
};
function colorNivel(nivel) { return (nivel && COLORES_NIVEL[nivel.nombre]) || '#15803d'; }

// Nivel anterior / siguiente según niveles.orden (nunca id ± 1). niveles: lista con { id, orden }
function nivelAnterior(niveles, nivel) {
  return niveles.filter((n) => n.orden < nivel.orden).sort((a, b) => b.orden - a.orden)[0] || null;
}
function nivelSiguiente(niveles, nivel) {
  return niveles.filter((n) => n.orden > nivel.orden).sort((a, b) => a.orden - b.orden)[0] || null;
}

// ---------- Mapa del grupo ----------
const POSICIONES = ['recibidor', 'constructor_1', 'constructor_2', 'regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'];
const REGALADORES = ['regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'];
const NOMBRE_POSICION = {
  recibidor: 'Recibidor',
  constructor_1: 'Constructor 1',
  constructor_2: 'Constructor 2',
  regalador_1: 'Regalador 1',
  regalador_2: 'Regalador 2',
  regalador_3: 'Regalador 3',
  regalador_4: 'Regalador 4'
};

function esRegalador(posicion) { return /^regalador_/.test(posicion); }

function estadoCasilla(p) {
  if (!p.user_id) return 'Posición libre';
  switch (p.estado) {
    case 'reservada': return 'Tarea pendiente';
    case 'tarea_hecha': return 'Hecha · por confirmar';
    case 'confirmada': return 'Tarea confirmada';
    case 'plazo_vencido': return 'Plazo vencido';
    default: return p.posicion === 'recibidor' ? 'Espera las tareas' : 'Activo';
  }
}

// posiciones: [{ posicion, user_id, nombre_usuario, estado, ... }]
// opciones: { miId, acciones(p) -> Element|null }
function crearMapaGrupo(posiciones, opciones) {
  const op = opciones || {};
  const porPos = {};
  posiciones.forEach((p) => { porPos[p.posicion] = p; });

  const mapa = el('div', { class: 'mapa', role: 'list', 'aria-label': 'Mapa del grupo' });
  POSICIONES.forEach((pos) => {
    const p = porPos[pos] || { posicion: pos, user_id: null };
    const esYo = op.miId && p.user_id === op.miId;
    const vencida = p.user_id && p.estado === 'plazo_vencido';
    const casilla = el('div', {
      class: 'casilla' + (p.user_id ? '' : ' libre') + (esYo ? ' tu' : '') + (vencida ? ' vencida' : ''),
      'data-pos': pos,
      role: 'listitem'
    },
      el('div', { class: 'cas-rol', text: NOMBRE_POSICION[pos].toUpperCase() }),
      el('div', { class: 'cas-nombre', text: p.user_id ? (p.nombre_usuario || '—') : 'Esperando...' }),
      el('div', { class: 'cas-estado', text: estadoCasilla(p) }),
      esYo ? el('div', { class: 'cas-tu', text: 'TÚ' }) : null
    );
    if (op.acciones) {
      const acc = op.acciones(p);
      if (acc) casilla.appendChild(acc);
    }
    mapa.appendChild(casilla);
  });
  return mapa;
}
