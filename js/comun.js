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
const NOMBRE_CORTO_POSICION = {
  recibidor: 'RECIB.',
  constructor_1: 'CONST. 1',
  constructor_2: 'CONST. 2',
  regalador_1: 'REG. 1',
  regalador_2: 'REG. 2',
  regalador_3: 'REG. 3',
  regalador_4: 'REG. 4'
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
// Nombre de usuario que puede pasar de línea después de cada "_" (juan_ / perez_ / lopez),
// en lugar de cortarse a mitad de palabra en las casillas angostas del celular.
function nombreConCortes(texto) {
  const partes = [];
  String(texto).split('_').forEach((trozo, i, todos) => {
    partes.push(i < todos.length - 1 ? trozo + '_' : trozo);
    if (i < todos.length - 1) partes.push(document.createElement('wbr'));
  });
  return partes;
}

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
      // En celular el mapa es angosto: se muestra el nombre corto (RECIB., CONST. 1, REG. 1)
      el('div', { class: 'cas-rol-corto', 'aria-hidden': 'true', text: NOMBRE_CORTO_POSICION[pos] }),
      el('div', { class: 'cas-nombre' }, p.user_id ? nombreConCortes(p.nombre_usuario || '—') : ((op.textoLibre && op.textoLibre(p)) || 'Esperando…')),
      op.debajoNombre ? op.debajoNombre(p) : null,
      el('div', { class: 'cas-estado', text: estadoCasilla(p) }),
      esYo ? el('div', { class: 'cas-tu', text: 'TÚ' }) : null
    );
    if (op.iconos) {
      const ic = op.iconos(p);
      if (ic) casilla.appendChild(ic);
    }
    if (op.acciones) {
      const acc = op.acciones(p);
      if (acc) casilla.appendChild(acc);
    }
    mapa.appendChild(casilla);
  });
  return mapa;
}

// =====================================================================
// Íconos de las casillas y tablero completado (Historial del socio y "Ver tableros" del admin)
// =====================================================================
// Íconos SVG de las casillas (dibujos fijos del código): "visto" y "quitar persona"
function svgIcono(tipo) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  const forma = (nombre, attrs) => {
    const n = document.createElementNS(NS, nombre);
    Object.keys(attrs).forEach((k) => n.setAttribute(k, attrs[k]));
    svg.appendChild(n);
  };
  if (tipo === 'visto') {
    svg.setAttribute('stroke-width', '3');
    forma('path', { d: 'M5 12.5l4.5 4.5L19 7.5' });
  } else {
    // Persona con un signo menos (person-remove)
    svg.setAttribute('stroke-width', '2');
    forma('circle', { cx: '9', cy: '8', r: '4' });
    forma('path', { d: 'M2 20c0-3.6 3.1-6 7-6s7 2.4 7 6' });
    forma('path', { d: 'M16 11h6' });
  }
  return svg;
}

const POS_REGALADORES = ['regalador_1', 'regalador_2', 'regalador_3', 'regalador_4'];
const LOGO_SVG = '<svg width="56" height="56" viewBox="0 0 88 88" aria-hidden="true"><rect width="88" height="88" rx="22" fill="#0f3d21"/><path d="M44 66V40" stroke="#facc15" stroke-width="5" stroke-linecap="round"/><path d="M44 42C44 30 34 24 24 25C24 36 31 43 44 42Z" fill="#facc15"/><path d="M44 48C44 38 53 32 63 33C63 43 56 49 44 48Z" fill="#fde68a"/></svg>';

const tipoTablero = (h) => (h.repeticion > 0 ? 'Repetición ' + h.repeticion : 'Normal');
const tituloNivel = (h) => 'Nivel ' + h.nivel_orden + ' (' + h.nivel + ')';

// El mapa del grupo tal como quedó al completarse: los 7 nombres y las 4 tareas verificadas
function mapaTablero(h, miId) {
  const porPos = {};
  (h.grupo || []).forEach((g) => { porPos[g.posicion] = g; });
  const posiciones = POSICIONES.map((pos) => {
    const g = porPos[pos];
    return {
      posicion: pos,
      user_id: g && g.nombre_usuario ? (g.yo ? miId : 'x-' + pos) : null,
      nombre_usuario: g ? g.nombre_usuario : null,
      estado: g && g.nombre_usuario && esRegalador(pos) ? 'confirmada' : null
    };
  });
  const mapa = crearMapaGrupo(posiciones, {
    miId,
    textoLibre: () => '—',
    iconos: (p) => (p.user_id && esRegalador(p.posicion)
      ? el('div', { class: 'cas-iconos' }, el('span', { class: 'cas-ico cas-verificado', role: 'img', title: 'Tarea verificada', 'aria-label': 'Tarea verificada' }, svgIcono('visto')))
      : null)
  });
  mapa.classList.add('mapa-tablero');
  mapa.querySelectorAll('.casilla').forEach((c) => {
    const pos = c.dataset.pos;
    const est = c.querySelector('.cas-estado');
    if (!est) return;
    if (pos === 'recibidor') est.textContent = 'Recibió ' + h.tareas_recibidas + ' tareas';
    else if (esRegalador(pos)) est.textContent = porPos[pos] && porPos[pos].nombre_usuario ? 'Tarea verificada' : 'Sin datos';
    else est.textContent = porPos[pos] && porPos[pos].nombre_usuario ? '' : 'Sin datos'; // el rol ya se ve arriba
  });
  return mapa;
}

function cabeceraTablero(h) {
  return el('div', { class: 'tablero-cab' },
    el('div', { class: 'nivel-circulo hn-circulo', style: 'background:' + colorNivel({ nombre: h.nivel }), 'aria-hidden': 'true', text: h.nivel.charAt(0) }),
    el('div', { class: 'hn-titulo' },
      el('b', { text: tituloNivel(h) }),
      el('span', { class: 'mut', text: 'Completado el ' + formatoFecha(h.completado_en) })),
    el('span', { class: 'pill ' + (h.repeticion > 0 ? 'pill-amarilla' : 'pill-verde'), text: tipoTablero(h) + (h.grupo_fundador ? ' · grupo fundador' : '') }));
}

function verTableroDialogo(h, miId) {
  const viejo = $('dlg-tablero');
  if (viejo) viejo.remove();
  const dlg = el('dialog', { class: 'modal modal-tablero', id: 'dlg-tablero', 'aria-labelledby': 'dlg-tablero-titulo' },
    el('div', { class: 'modal-cuerpo' },
      el('h3', { id: 'dlg-tablero-titulo', text: 'Tablero · ' + tituloNivel(h) }),
      cabeceraTablero(h),
      mapaTablero(h, miId),
      el('div', { class: 'hn-tareas' }, el('b', { text: String(h.tareas_recibidas) }), ' tareas recibidas'),
      h.foto_completa ? null : el('div', { class: 'mut hn-nota', text: 'Completaste este nivel antes de que se guardara el grupo completo: solo se muestran los nombres que se pudieron recuperar.' }),
      el('div', { class: 'modal-botones' },
        el('button', { type: 'button', class: 'bo', onclick: () => dlg.close(), text: 'Cerrar' }),
        el('button', { type: 'button', class: 'btn', onclick: () => { dlg.close(); descargarPdfTablero(h, miId); }, text: 'Descargar PDF' }))));
  dlg.addEventListener('close', () => dlg.remove());
  document.body.appendChild(dlg);
  dlg.showModal();
}

// "Descargar PDF": hoja con el logo, el nivel, la fecha y el tablero, con la vista de impresión
// del navegador (ahí se elige "Guardar como PDF")
function descargarPdfTablero(h, miId) {
  const viejo = $('zona-impresion');
  if (viejo) viejo.remove();
  const logo = el('span', { class: 'imp-logo' });
  logo.innerHTML = LOGO_SVG; // dibujo fijo del código (no es texto de usuarios)
  const zona = el('div', { id: 'zona-impresion' },
    el('div', { class: 'imp-cab' }, logo,
      el('div', null, el('div', { class: 'imp-marca', text: 'Siembra tu Futuro' }), el('div', { class: 'imp-sub', text: 'Tablero completado' }))),
    el('h1', { class: 'imp-titulo', text: tituloNivel(h) + ' · ' + tipoTablero(h) }),
    el('p', { class: 'imp-fecha', text: 'Completado el ' + formatoFecha(h.completado_en) + (h.grupo_fundador ? ' · grupo fundador' : '') }),
    mapaTablero(h, miId),
    el('p', { class: 'imp-tareas' }, el('b', { text: String(h.tareas_recibidas) }), ' tareas recibidas y verificadas'),
    el('p', { class: 'imp-pie', text: 'Comunidad de ayuda mutua · Documento generado el ' + formatoFecha(new Date().toISOString()) }));
  document.body.appendChild(zona);
  document.body.classList.add('imprimiendo');
  const titulo = document.title;
  document.title = 'Tablero ' + h.nivel + ' ' + tipoTablero(h) + ' ' + String(h.completado_en).slice(0, 10);
  const fin = () => {
    document.body.classList.remove('imprimiendo');
    zona.remove();
    document.title = titulo;
    window.removeEventListener('afterprint', fin);
  };
  window.addEventListener('afterprint', fin);
  setTimeout(() => window.print(), 50);
}

