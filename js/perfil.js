// Perfil (perfil.html): estadísticas, mis niveles, mi grupo e historial de tareas.
// Usa js/comun.js y js/pagina.js. En el sistema no existe dinero: todo son tareas y niveles.
(async function () {
  'use strict';

  const sb = crearClienteSupabase();
  const session = await iniciarPagina(sb);
  if (!session) return;

  const POR_PAGINA = 20;
  const ESTADO_TXT = { completado: 'Completado', actual: 'Participas', habilitado: 'Habilitado', bloqueado: 'Bloqueado' };
  const msg = $('perfil-msg');
  const panel = $('panel-grupo');
  let resumen = null;
  let nivelSel = null;

  // ---------- Resumen ----------
  try {
    const r = await sb.rpc('mi_resumen_perfil');
    if (r.error) throw r.error;
    resumen = r.data;
  } catch (err) {
    mostrarAviso(msg, 'No se pudo cargar tu perfil. ' + traducirErrorDatos(err));
    vaciar($('stats'));
    vaciar(panel);
    panel.appendChild(el('p', { text: 'Sin datos.' }));
    return;
  }

  const actual = resumen.nivel_actual;
  $('perfil-titulo').textContent = 'Perfil · ' + resumen.nombre_usuario;
  $('perfil-sub').textContent = 'Tu árbol de la comunidad · ' + (actual ? 'Nivel ' + actual.nombre : 'Sin nivel todavía');

  // ---------- Estadísticas ----------
  const fila = (etiqueta, valor) => el('div', { class: 'stat-fila' },
    el('span', { class: 'mut', text: etiqueta }), el('b', { text: String(valor) }));
  const stats = $('stats');
  vaciar(stats);
  stats.append(
    fila('Tareas regaladas', resumen.tareas_regaladas),
    fila('Tareas recibidas', resumen.tareas_recibidas),
    fila('Niveles completados', resumen.niveles_completados + ' de ' + resumen.total_niveles),
    fila('Nivel actual', actual ? actual.nombre : '—'),
    fila('Referidos', resumen.referidos + ' de 2'),
    fila('Miembro desde', formatoFecha(resumen.miembro_desde))
  );

  // ---------- Mis niveles (ordenados por niveles.orden, ya vienen así) ----------
  const niveles = resumen.niveles || [];
  const participo = niveles.filter((n) => n.posicion);
  const cajaNiveles = $('niveles-mini');
  const botones = {};
  niveles.forEach((n) => {
    const esActual = actual && n.nivel_id === actual.id;
    const b = el('button', {
      type: 'button',
      class: 'nivel-mini ' + n.estado + (esActual ? ' resaltado' : ''),
      title: n.nombre + ' · ' + ESTADO_TXT[n.estado],
      'aria-label': 'Nivel ' + n.orden + ', ' + n.nombre + ': ' + ESTADO_TXT[n.estado],
      onclick: () => elegirNivel(n)
    },
    el('span', { class: 'nm-letra', 'aria-hidden': 'true', text: n.estado === 'completado' ? '✓' : String(n.orden) }));
    botones[n.nivel_id] = b;
    cajaNiveles.appendChild(el('div', { class: 'nivel-mini-item' }, b, el('span', { class: 'nm-nombre', text: n.nombre })));
  });

  function marcarSeleccion(id) {
    Object.entries(botones).forEach(([k, b]) => b.classList.toggle('sel', String(k) === String(id)));
  }

  function elegirNivel(n) {
    marcarSeleccion(n.nivel_id);
    if (n.posicion) return mostrarGrupo(n.nivel_id);
    vaciar(panel);
    panel.append(el('h3', { text: 'Nivel ' + n.nombre }));
    const textos = {
      completado: 'Completaste este nivel: recibiste tus 4 tareas. ¡Felicitaciones!',
      habilitado: 'Todavía no participas en este nivel. Ve a Niveles y toca "Participar".',
      bloqueado: 'Este nivel está bloqueado. Se habilita cuando completas el nivel anterior.'
    };
    panel.append(el('p', { class: 'po-texto', text: textos[n.estado] || '' }));
    if (n.estado === 'habilitado') panel.append(el('a', { class: 'bt-amarillo', href: 'panel.html#niveles', text: 'Ir a Niveles' }));
  }

  // ---------- Mi grupo (panel oscuro) ----------
  const inicial = (nombre) => (nombre ? nombre.charAt(0).toUpperCase() + (nombre.charAt(1) || '').toUpperCase() : '?');
  function circulo(nombre) {
    return el('span', { class: 'po-circ' + (nombre ? '' : ' vacio'), title: nombre || 'Libre', text: nombre ? inicial(nombre) : '?' });
  }
  function barra(n, total) {
    return el('div', { class: 'po-barra', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': String(total), 'aria-valuenow': String(n) },
      el('div', { class: 'po-relleno', style: 'width:' + Math.round((n / total) * 100) + '%' }));
  }

  async function mostrarGrupo(nivelId) {
    nivelSel = nivelId;
    marcarSeleccion(nivelId);
    vaciar(panel);
    panel.appendChild(el('p', { text: 'Cargando tu grupo…' }));
    const { data, error } = await sb.rpc('mi_grupo_resumen', { p_nivel_id: nivelId });
    if (nivelSel !== nivelId) return;
    vaciar(panel);
    if (error) { panel.appendChild(el('p', { class: 'po-texto', text: 'No se pudo cargar tu grupo. ' + traducirErrorDatos(error) })); return; }
    if (!data) { panel.appendChild(el('p', { class: 'po-texto', text: 'No tienes un grupo activo en este nivel.' })); return; }

    const casilla = (k) => (data.casillas || []).find((c) => c.posicion === k) || {};
    const cons = ['constructor_1', 'constructor_2'].map(casilla);
    const regs = REGALADORES.map(casilla);
    const nCons = cons.filter((c) => c.nombre_usuario).length;
    const nRegs = regs.filter((c) => c.nombre_usuario).length;
    const ocupadas = (data.recibidor ? 1 : 0) + nCons + nRegs;

    const cab = el('div', { class: 'po-cab' }, el('h3', { text: 'Mi grupo en ' + data.nivel }));
    if (participo.length > 1) {
      const sel = el('select', { class: 'in sel po-sel', 'aria-label': 'Elegir nivel' });
      participo.forEach((n) => sel.appendChild(el('option', { value: String(n.nivel_id), text: n.nombre, selected: n.nivel_id === nivelId })));
      sel.addEventListener('change', () => mostrarGrupo(Number(sel.value)));
      cab.appendChild(sel);
    }

    panel.append(
      cab,
      el('div', { class: 'po-centro' },
        el('span', { class: 'po-chip', text: data.recibidor || 'Sin recibidor' }),
        el('div', { class: 'po-sub', text: 'Recibidor: ' + (data.recibidor ? '1/1' : '0/1') + (data.mi_posicion ? ' · Tú eres ' + (NOMBRE_POSICION[data.mi_posicion] || '') : '') })
      ),
      el('div', { class: 'po-titulo', text: 'Constructores: ' + nCons + '/2' }), barra(nCons, 2),
      el('div', { class: 'po-circs' }, cons.map((c) => circulo(c.nombre_usuario))),
      el('div', { class: 'po-titulo', text: 'Regaladores: ' + nRegs + '/4' }), barra(nRegs, 4),
      el('div', { class: 'po-circs' }, regs.map((c) => circulo(c.nombre_usuario))),
      el('div', { class: 'po-titulo', text: 'Tareas aprobadas: ' + data.tareas_aprobadas + '/4' }), barra(data.tareas_aprobadas, 4),
      el('p', { class: 'po-texto', text: ocupadas + ' de 7 posiciones ocupadas · ' + data.tareas_aprobadas + (data.tareas_aprobadas === 1 ? ' tarea aprobada' : ' tareas aprobadas') }),
      el('a', { class: 'po-link', href: 'panel.html#mi-grupo?nivel=' + nivelId, text: 'Ver el mapa en Mi grupo' })
    );
  }

  const inicialGrupo = participo.find((n) => actual && n.nivel_id === actual.id) || participo[participo.length - 1];
  if (inicialGrupo) {
    mostrarGrupo(inicialGrupo.nivel_id);
  } else {
    vaciar(panel);
    panel.append(el('h3', { text: 'Mi grupo' }),
      el('p', { class: 'po-texto', text: resumen.en_espera
        ? 'Estás en la lista de espera. Cuando el administrador te asigne un lugar, aquí verás tu grupo.'
        : 'Todavía no tienes un grupo. Ve a Niveles y toca "Participar".' }),
      el('a', { class: 'bt-amarillo', href: 'panel.html#niveles', text: 'Ir a Niveles' }));
  }

  // ---------- Historial de tareas ----------
  const lista = $('hist-lista');
  const btnMas = $('hist-mas');
  const tabs = { regaladas: $('hist-tab-regaladas'), recibidas: $('hist-tab-recibidas') };
  let tipo = 'regaladas';
  let desde = 0;
  let turno = 0;

  async function cargarHistorial(reiniciar) {
    const t = ++turno;
    if (reiniciar) { desde = 0; vaciar(lista); lista.appendChild(el('p', { class: 'mut', text: 'Cargando…' })); }
    btnMas.disabled = true;
    const { data, error } = await sb.rpc('mi_historial', { p_tipo: tipo, p_desde: desde, p_cuantos: POR_PAGINA + 1 });
    if (t !== turno) return;
    if (reiniciar) vaciar(lista);
    btnMas.disabled = false;
    if (error) {
      lista.appendChild(el('div', { class: 'msg error', text: 'No se pudo cargar el historial. ' + traducirErrorDatos(error) }));
      btnMas.hidden = true;
      return;
    }
    const filas = data.slice(0, POR_PAGINA);
    if (reiniciar && !filas.length) {
      lista.appendChild(el('p', { class: 'mut', text: tipo === 'regaladas'
        ? 'Todavía no tienes tareas regaladas aprobadas.'
        : 'Todavía no has recibido tareas como recibidor.' }));
    }
    filas.forEach((h) => {
      lista.appendChild(el('div', { class: 'hist-fila' },
        el('span', { class: 'pill pill-verde', text: h.nivel || '—' }),
        el('div', { class: 'hist-quien' },
          el('b', { text: h.otro_usuario || '(cuenta eliminada)' }),
          el('span', { class: 'mut', text: (tipo === 'regaladas' ? 'Recibidor' : NOMBRE_POSICION[h.posicion] || 'Regalador') })
        ),
        el('span', { class: 'mut hist-fecha', text: formatoFecha(h.aprobada_en) })
      ));
    });
    desde += filas.length;
    btnMas.hidden = data.length <= POR_PAGINA;
  }

  Object.entries(tabs).forEach(([k, b]) => b.addEventListener('click', () => {
    if (tipo === k) return;
    tipo = k;
    Object.entries(tabs).forEach(([k2, b2]) => b2.setAttribute('aria-selected', k2 === k ? 'true' : 'false'));
    cargarHistorial(true);
  }));
  btnMas.addEventListener('click', () => cargarHistorial(false));
  cargarHistorial(true);
})();
