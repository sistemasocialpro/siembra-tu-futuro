// Administración (admin.html). Solo administradores. Usa js/comun.js
(async function () {
  'use strict';

  const sb = crearClienteSupabase();

  // ---------- Protección: sin sesión -> index.html; sin ser admin -> panel.html ----------
  const session = await exigirSesion(sb);
  if (!session) return;
  const { data: esAdmin, error: errAdmin } = await sb.rpc('es_admin');
  if (errAdmin || esAdmin !== true) { location.replace('panel.html'); return; }

  // Cuenta de administrador separada (sin perfil): no participa, así que el menú solo
  // muestra Administración y Cerrar sesión.
  const { data: miPerfil } = await sb.from('perfiles').select('nombre_usuario').eq('id', session.user.id).maybeSingle();
  if (!miPerfil) document.querySelectorAll('#menu .solo-participante').forEach((a) => { a.hidden = true; });
  document.body.classList.remove('cargando');

  iniciarCerrarSesion(sb);
  iniciarMenuLateral();

  // ---------- Estado ----------
  let perfiles = [];
  let perfilPorId = {};
  let correoPorId = {};
  let niveles = [];
  let ocupado = false;

  // ---------- Avisos ----------
  let tAviso;
  function aviso(texto, tipo) {
    const m = $('admin-msg');
    m.textContent = texto;
    m.className = 'msg ' + (tipo || 'error');
    m.hidden = false;
    clearTimeout(tAviso);
    if (tipo === 'ok') tAviso = setTimeout(() => { m.hidden = true; }, 5000);
    m.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }
  function ocultarAviso() { $('admin-msg').hidden = true; }

  // Ejecuta una acción en Supabase con aviso de éxito o error
  async function ejecutar(fn, textoOk) {
    if (ocupado) return false;
    ocupado = true;
    document.body.classList.add('trabajando');
    try {
      const r = await fn();
      if (r.error) throw r.error;
      aviso(typeof textoOk === 'function' ? textoOk(r.data) : textoOk, 'ok');
      return true;
    } catch (err) {
      aviso(traducirErrorDatos(err));
      return false;
    } finally {
      ocupado = false;
      document.body.classList.remove('trabajando');
    }
  }

  // ---------- Pestañas ----------
  const TABS = ['usuarios', 'arbol', 'grupos', 'espera', 'config', 'registro'];
  const CARGAR = { usuarios: cargarUsuarios, arbol: cargarArbol, grupos: cargarGrupos, espera: cargarEspera, config: cargarConfig, registro: () => cargarRegistro(false) };
  // sinCargar: al abrir una ficha desde el árbol o el registro solo se cambia de pestaña
  function mostrarTab(nombre, sinCargar) {
    TABS.forEach((k) => {
      $('tab-' + k).setAttribute('aria-selected', k === nombre ? 'true' : 'false');
      $('pan-' + k).hidden = k !== nombre;
    });
    ocultarAviso();
    if (nombre === 'usuarios' && !sinCargar) cerrarFicha();
    if (!sinCargar) CARGAR[nombre]();
  }
  TABS.forEach((k) => $('tab-' + k).addEventListener('click', () => mostrarTab(k)));

  // ---------- Datos comunes ----------
  async function cargarPerfiles() {
    const COLS = 'id, nombre_usuario, nombre_completo, whatsapp, codigo_invitacion, invitado_por, es_fundador, creado_en';
    let { data, error } = await sb.from('perfiles').select(COLS + ', numero').order('creado_en', { ascending: false });
    if (error) ({ data, error } = await sb.from('perfiles').select(COLS).order('creado_en', { ascending: false }));
    if (error) throw error;
    perfiles = data;
    perfilPorId = {};
    perfiles.forEach((p) => { perfilPorId[p.id] = p; });
  }

  async function cargarNiveles() {
    if (niveles.length) return;
    const { data, error } = await sb.from('niveles').select('id, orden, nombre').order('orden');
    if (error) throw error;
    niveles = data;
    const filtro = $('filtro-nivel');
    vaciar(filtro);
    niveles.forEach((n) => filtro.appendChild(el('option', { value: String(n.id), text: n.orden + '. ' + n.nombre })));
    const terreno = niveles[0]; // primer nivel por orden
    if (terreno) filtro.value = String(terreno.id);
  }

  function nombreNivel(id) {
    const n = niveles.find((x) => String(x.id) === String(id));
    return n ? n.nombre : '—';
  }
  function nombreDe(userId) { return (perfilPorId[userId] || {}).nombre_usuario; }

  async function actualizarBadgeEspera() {
    const { count, error } = await sb.from('lista_espera').select('user_id', { count: 'exact', head: true });
    if (error) return;
    const b = $('badge-espera');
    b.textContent = String(count || 0);
    b.hidden = !count;
  }

  // =====================================================================
  // USUARIOS
  // =====================================================================
  // Correos de los participantes (admin_correos, 15). Si falta el SQL, la columna queda en "—".
  async function cargarCorreos() {
    const { data, error } = await sb.rpc('admin_correos');
    correoPorId = {};
    if (error) return;
    (data || []).forEach((c) => { correoPorId[c.user_id] = c.email; });
  }

  // ---------- (32) Resumen de la plataforma, tabla paginada y filtros ----------
  const POR_PAGINA = 25;
  const ESTADO_LISTA = { activo: ['Activo', 'pill-verde'], plazo_vencido: ['Plazo vencido', 'pill-roja'], espera: ['En espera', 'pill-amarilla'] };
  let uPagina = 0;
  let uTotal = 0;
  let uTurno = 0;
  let uCargada = false;

  async function cargarResumen() {
    const { data, error } = await sb.rpc('admin_resumen_plataforma');
    const poner = (id, v) => { $(id).textContent = v == null ? '—' : formatoNumero(v); };
    if (error || !data) { ['st-usuarios', 'st-tareas', 'st-tableros', 'st-espera'].forEach((id) => poner(id, null)); return; }
    poner('st-usuarios', data.usuarios);
    poner('st-tareas', data.tareas_recibidas);
    poner('st-tableros', data.tableros);
    poner('st-espera', data.en_espera);
    $('st-espera-det').textContent = formatoNumero(data.espera_nivel) + ' de un nivel · ' + formatoNumero(data.espera_patrocinador) + ' de su patrocinador';
  }

  async function cargarUsuarios() {
    uCargada = true;
    cargarResumen();
    try {
      await cargarNiveles();
      const sel = $('filtro-nivel-usuarios');
      if (sel.options.length <= 1) niveles.forEach((n) => sel.appendChild(el('option', { value: String(n.id), text: n.orden + '. ' + n.nombre })));
    } catch (e) { /* el filtro por nivel queda solo con "Todos" */ }
    cargarLista();
  }

  async function cargarLista() {
    const turno = ++uTurno;
    const tb = $('tabla-usuarios');
    const { data, error } = await sb.rpc('admin_usuarios_lista', {
      p_buscar: $('buscar-usuarios').value.trim() || null,
      p_nivel: $('filtro-nivel-usuarios').value ? Number($('filtro-nivel-usuarios').value) : null,
      p_orden: $('orden-usuarios').value,
      p_desde: uPagina * POR_PAGINA,
      p_cuantos: POR_PAGINA
    });
    if (turno !== uTurno) return;
    vaciar(tb);
    if (error) {
      tb.appendChild(el('tr', null, el('td', { colspan: '8', class: 'msg error', text: 'No se pudieron cargar los usuarios. ' + traducirErrorDatos(error) })));
      return;
    }
    uTotal = data.total;
    if (!data.filas.length) {
      tb.appendChild(el('tr', null, el('td', { colspan: '8', class: 'mut', text: uTotal ? 'No hay más usuarios.' : 'Ningún usuario coincide con la búsqueda.' })));
    }
    data.filas.forEach((u) => {
      const est = ESTADO_LISTA[u.estado] || ESTADO_LISTA.activo;
      const tr = el('tr', { class: 'fila-usuario' + (u.id === fichaId ? ' sel' : ''), tabindex: '0', 'data-id': u.id,
        'aria-label': 'Ver ficha de ' + u.nombre_usuario, onclick: () => abrirFicha(u.id),
        onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); abrirFicha(u.id); } } },
        el('td', null, el('div', { class: 'u-num', text: u.numero || '—' }), el('div', { class: 'mono u-codigo', text: u.codigo || '' })),
        el('td', null, el('b', { class: 'u-usuario' }, nombreConCortes(u.nombre_usuario)), u.es_fundador ? el('span', { class: 'u-fundador', title: 'Fundador', text: '★' }) : null),
        el('td', { class: 'u-nombre', text: u.nombre_completo || '—' }),
        el('td', null, u.nivel_orden ? el('span', { class: 'u-nivel' },
          el('i', { class: 'u-punto', style: 'background:' + colorNivel({ nombre: u.nivel_nombre }), 'aria-hidden': 'true' }), u.nivel_orden + '. ' + u.nivel_nombre) : el('span', { class: 'mut', text: '—' })),
        el('td', { class: 'num', 'data-et': 'Tableros', text: formatoNumero(u.tableros) }),
        el('td', { class: 'num num-verde', 'data-et': 'Recibidas', text: formatoNumero(u.tareas_recibidas) }),
        el('td', { class: 'num', 'data-et': 'Hechas', text: formatoNumero(u.tareas_hechas) }),
        el('td', null, el('span', { class: 'pill ' + est[1], text: est[0] })));
      tb.appendChild(tr);
    });
    const paginas = Math.max(1, Math.ceil(uTotal / POR_PAGINA));
    $('cuenta-usuarios').textContent = formatoNumero(uTotal) + (uTotal === 1 ? ' usuario' : ' usuarios');
    $('pag-info').textContent = 'Página ' + (uPagina + 1) + ' de ' + paginas;
    $('pag-ant').disabled = uPagina === 0;
    $('pag-sig').disabled = uPagina + 1 >= paginas;
  }

  let tBuscarU;
  $('buscar-usuarios').addEventListener('input', () => { clearTimeout(tBuscarU); tBuscarU = setTimeout(() => { uPagina = 0; cargarLista(); }, 250); });
  $('filtro-nivel-usuarios').addEventListener('change', () => { uPagina = 0; cargarLista(); });
  $('orden-usuarios').addEventListener('change', () => { uPagina = 0; cargarLista(); });
  $('pag-ant').addEventListener('click', () => { if (uPagina > 0) { uPagina--; cargarLista(); } });
  $('pag-sig').addEventListener('click', () => { uPagina++; cargarLista(); });

  // En los campos de una ventana, Enter = botón de confirmar (no "Cancelar", que va primero)
  function enterConfirma(e) {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    $('dlg-confirmar-ok').click();
  }

  // Contraseña nueva para un participante (admin_cambiar_clave, 15)
  async function cambiarClave(p) {
    if (ocupado) return;
    const in1 = el('input', { class: 'in', id: 'adm-clave-1', type: 'password', autocomplete: 'new-password', maxlength: '72', onkeydown: enterConfirma });
    const in2 = el('input', { class: 'in', id: 'adm-clave-2', type: 'password', autocomplete: 'new-password', maxlength: '72', onkeydown: enterConfirma });
    const err = el('span', { class: 'err', 'aria-live': 'polite' });
    const extra = el('div', null,
      el('label', { class: 'lb', for: 'adm-clave-1' }, 'Contraseña nueva (mín. 6)', in1),
      el('label', { class: 'lb', for: 'adm-clave-2' }, 'Repite la contraseña', in2),
      err
    );
    let clave = '';
    for (;;) {
      const si = await confirmar({
        titulo: 'Cambiar contraseña',
        texto: ['Escribe la contraseña nueva de ', el('b', { text: p.nombre_usuario }),
          '. Se cerrarán sus sesiones abiertas y tendrá que entrar con la clave nueva. Envíasela por un medio seguro.'],
        extra,
        boton: 'Guardar contraseña'
      });
      if (!si) return;
      clave = in1.value;
      if (clave.length < 6) err.textContent = 'La contraseña debe tener al menos 6 caracteres.';
      else if (clave !== in2.value) err.textContent = 'Las contraseñas no coinciden.';
      else break;
    }
    await ejecutar(
      () => sb.rpc('admin_cambiar_clave', { p_user_id: p.id, p_clave: clave }),
      'La contraseña de ' + p.nombre_usuario + ' fue cambiada.'
    );
  }

  // Eliminar la cuenta de un participante (admin_eliminar_cuenta, 15): libera sus casillas,
  // avisa a su patrocinador y a su recibidor, y borra la cuenta.
  async function eliminarCuenta(p) {
    if (ocupado) return;
    const conf = el('input', { class: 'in', id: 'adm-eliminar-conf', type: 'text', autocomplete: 'off', autocapitalize: 'characters', onkeydown: enterConfirma });
    const err = el('span', { class: 'err', 'aria-live': 'polite' });
    const extra = el('div', null,
      el('label', { class: 'lb', for: 'adm-eliminar-conf' }, 'Para confirmar escribe ELIMINAR', conf),
      err
    );
    for (;;) {
      const si = await confirmar({
        titulo: 'Eliminar cuenta',
        texto: ['¿Eliminar la cuenta de ', el('b', { text: p.nombre_usuario }),
          '? Se liberan sus casillas en todos los niveles, se avisa a su patrocinador y a su recibidor, y la cuenta se borra para siempre. Si es recibidor de un grupo con personas, primero reemplázalo en Grupos.'],
        extra,
        boton: 'Eliminar cuenta',
        peligro: true
      });
      if (!si) return;
      if (conf.value.trim().toUpperCase() === 'ELIMINAR') break;
      err.textContent = 'Escribe ELIMINAR para confirmar.';
    }
    const ok = await ejecutar(
      () => sb.rpc('admin_eliminar_cuenta', { p_user_id: p.id }),
      'La cuenta de ' + p.nombre_usuario + ' fue eliminada.'
    );
    if (ok) { cerrarFicha(); cargarResumen(); cargarLista(); actualizarBadgeEspera(); }
  }

  // Fundador: en todos los niveles menos el primero crea su propio grupo como recibidor al tocar Participar
  async function cambiarFundador(p, valor) {
    if (ocupado) return;
    const si = await confirmar({
      titulo: valor ? 'Marcar como fundador' : 'Quitar fundador',
      texto: valor
        ? ['¿Marcar a ', el('b', { text: p.nombre_usuario }), ' como fundador? En todos los niveles menos el primero, al tocar Participar se le creará un grupo nuevo y será su recibidor (cuando tenga habilitado el nivel).']
        : ['¿Quitar a ', el('b', { text: p.nombre_usuario }), ' como fundador? En todos los niveles menos el primero entrará al grupo de quien lo invitó, como los demás.'],
      boton: valor ? 'Marcar como fundador' : 'Quitar fundador',
      peligro: !valor
    });
    if (!si) return;
    const ok = await ejecutar(
      () => sb.rpc('admin_marcar_fundador', { p_user_id: p.id, p_es_fundador: valor }),
      p.nombre_usuario + (valor ? ' ahora es fundador.' : ' ya no es fundador.')
    );
    if (ok) { cargarLista(); if (fichaId === p.id) abrirFicha(p.id); }
  }

  // =====================================================================
  // (30) FICHA DEL USUARIO
  // =====================================================================
  const ESTADO_REFERIDO = { activo: 'Referido activo', reserva: 'En lista de espera', eliminado: 'Quitado por su patrocinador', derrame: 'Por derrame' };
  const ESTADO_CASILLA = { reservada: 'Tarea pendiente', tarea_hecha: 'Tarea hecha · por aprobar', confirmada: 'Tarea aprobada', plazo_vencido: 'Plazo vencido' };
  let fichaId = null;

  function fechaHoraLarga(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    return d.toLocaleDateString('es-EC', { day: '2-digit', month: 'short', year: 'numeric' }) + ' ' +
      d.toLocaleTimeString('es-EC', { hour: '2-digit', minute: '2-digit' });
  }

  // En computadora la ficha va a la derecha; en celular se abre en pantalla completa
  const fichaPantallaCompleta = () => window.matchMedia('(max-width: 1099px)').matches;

  function marcarFila() {
    document.querySelectorAll('#tabla-usuarios .fila-usuario').forEach((tr) => tr.classList.toggle('sel', tr.dataset.id === fichaId));
  }

  function fichaVacia() {
    const caja = $('ficha');
    vaciar(caja);
    caja.appendChild(el('div', { class: 'ficha-vacia' },
      el('div', { class: 'ficha-vacia-ico', 'aria-hidden': 'true', text: '👤' }),
      el('b', { text: 'Elige un usuario' }),
      el('span', { class: 'mut', text: 'Toca una fila de la tabla para ver su ficha.' })));
  }

  function cerrarFicha() {
    fichaId = null;
    $('ficha').classList.remove('abierta');
    document.body.classList.remove('ficha-abierta');
    fichaVacia();
    marcarFila();
  }

  async function abrirFicha(id) {
    if ($('pan-usuarios').hidden) mostrarTab('usuarios', true);
    if (!uCargada) cargarUsuarios();
    fichaId = id;
    marcarFila();
    const caja = $('ficha');
    if (fichaPantallaCompleta()) {
      caja.classList.add('abierta');
      document.body.classList.add('ficha-abierta');
    }
    vaciar(caja);
    caja.appendChild(el('div', { class: 'mut ficha-cargando', text: 'Cargando ficha…' }));
    caja.scrollTop = 0;
    const [rf, rx] = await Promise.all([
      sb.rpc('admin_ficha_usuario', { p_user_id: id }),
      sb.rpc('admin_ficha_extra', { p_user_id: id })
    ]);
    if (fichaId !== id) return;
    vaciar(caja);
    if (rf.error) {
      caja.appendChild(el('button', { type: 'button', class: 'bo btn-chico', onclick: cerrarFicha, text: '← Volver a la lista' }));
      caja.appendChild(el('div', { class: 'msg error', text: 'No se pudo cargar la ficha. ' + traducirErrorDatos(rf.error) }));
      return;
    }
    pintarFicha(rf.data, rx.error ? { niveles: [], referidos: [] } : rx.data);
  }

  function dato(etiqueta, valor) {
    return el('div', { class: 'ficha-dato' }, el('span', { class: 'mut', text: etiqueta }),
      valor instanceof Node ? valor : el('b', { text: valor == null || valor === '' ? '—' : String(valor) }));
  }

  function pintarFicha(f, x) {
    const d = f.datos;
    const p = { id: d.id, nombre_usuario: d.nombre_usuario, es_fundador: d.es_fundador };
    const caja = $('ficha');
    const sum = (k) => f.tareas.reduce((a, t) => a + (t[k] || 0), 0);
    const recibidas = sum('recibidas_normal') + sum('recibidas_repeticion');
    const hechas = sum('hechas_normal') + sum('hechas_repeticion');
    const tableros = x.niveles.reduce((a, n) => a + n.normales + n.repeticiones, 0);

    // Cabecera
    caja.appendChild(el('div', { class: 'ficha-cab' },
      el('button', { type: 'button', class: 'ficha-cerrar', onclick: cerrarFicha, 'aria-label': 'Cerrar ficha', title: 'Cerrar', text: '✕' }),
      el('div', { class: 'ficha-avatar', 'aria-hidden': 'true', text: d.nombre_usuario.charAt(0).toUpperCase() }),
      el('div', { class: 'ficha-cab-txt' },
        el('h3', null, nombreConCortes(d.nombre_usuario)),
        el('div', { class: 'ficha-num', text: 'N.º ' + (d.numero || '—') + ' · Código ' + (d.codigo_invitacion || '—') })),
      el('div', { class: 'ficha-pills' },
        d.es_fundador ? el('span', { class: 'pill pill-amarilla', text: 'Fundador' }) : null,
        el('span', { class: 'pill pill-verde', text: ESTADO_REFERIDO[d.referido_estado] || d.referido_estado }))));

    // Tres totales
    caja.appendChild(el('div', { class: 'ficha-totales3' },
      el('div', { class: 'ft' }, el('b', { class: 'num-verde', text: formatoNumero(recibidas) }), el('span', { text: 'Tareas recibidas' })),
      el('div', { class: 'ft' }, el('b', { text: formatoNumero(hechas) }), el('span', { text: 'Tareas hechas' })),
      el('div', { class: 'ft' }, el('b', { text: formatoNumero(tableros) }), el('span', { text: 'Tableros' }))));

    // Botones principales
    caja.appendChild(el('div', { class: 'ficha-acciones' },
      el('button', { type: 'button', class: 'btn btn-chico', onclick: () => verTablerosDe(d), text: 'Ver tableros' }),
      el('button', { type: 'button', class: 'bo btn-chico', onclick: () => verEnArbol(d), text: 'Ver en el árbol' }),
      el('button', { type: 'button', class: 'bo btn-chico', onclick: () => editarDatos(d), text: 'Editar datos' }),
      el('button', { type: 'button', class: 'bt-salir btn-chico', onclick: () => eliminarCuenta(p), text: 'Eliminar' })));

    // Datos
    caja.appendChild(el('section', { class: 'ficha-sec' }, el('h4', { text: 'Datos' }),
      el('div', { class: 'ficha-datos' },
        dato('Nombre', d.nombre_completo),
        dato('Correo', d.correo),
        dato('WhatsApp', d.whatsapp ? el('a', { class: 'link', href: enlaceWhatsApp(d.whatsapp, 'Hola ' + d.nombre_usuario + ', te escribo de Siembra tu Futuro.'), target: '_blank', rel: 'noopener', text: d.whatsapp }) : null),
        dato('País', d.pais),
        dato('Registrado', formatoFecha(d.creado_en)),
        dato('Último acceso', d.ultimo_acceso ? fechaHoraLarga(d.ultimo_acceso) : 'Nunca'))));

    // Patrocinador y referidos
    const refs = el('div', { class: 'ficha-refs' });
    if (!x.referidos.length) refs.appendChild(el('span', { class: 'mut', text: 'Sin referidos.' }));
    x.referidos.forEach((r) => refs.appendChild(el('button', { type: 'button', class: 'ref-chip' + (r.referido_estado === 'activo' ? '' : ' otro'),
      title: ESTADO_REFERIDO[r.referido_estado] || '', onclick: () => abrirFicha(r.id), text: (r.numero ? r.numero + ' · ' : '') + r.nombre_usuario })));
    caja.appendChild(el('section', { class: 'ficha-sec' }, el('h4', { text: 'Patrocinador y referidos' }),
      el('div', { class: 'ficha-datos' },
        dato('Patrocinador', d.patrocinador_id
          ? el('button', { type: 'button', class: 'link-ficha', onclick: () => abrirFicha(d.patrocinador_id), text: (d.patrocinador_numero ? d.patrocinador_numero + ' · ' : '') + d.patrocinador })
          : 'Sin patrocinador'),
        dato('Referidos', f.referidos.activos + ' activos · ' + f.referidos.espera + ' en espera · ' + f.referidos.total + ' en total')),
      refs));

    // Por nivel: tableros normales, repeticiones y tareas recibidas (con barra)
    const sec = el('section', { class: 'ficha-sec' }, el('h4', { text: 'Por nivel' }));
    if (!x.niveles.length) {
      sec.appendChild(el('p', { class: 'mut', text: 'Todavía no completó tableros ni recibió tareas.' }));
    } else {
      const max = Math.max(1, ...x.niveles.map((n) => n.tareas_recibidas));
      const tb = el('tbody');
      x.niveles.forEach((n) => tb.appendChild(el('tr', null,
        el('td', null, el('b', { text: n.nivel_orden + '. ' + n.nivel })),
        el('td', { class: 'num', text: String(n.normales) }),
        el('td', { class: 'num', text: String(n.repeticiones) }),
        el('td', null, el('div', { class: 'barra-celda' },
          el('div', { class: 'barra', role: 'img', 'aria-label': n.tareas_recibidas + ' tareas recibidas' },
            el('span', { style: 'width:' + Math.round((n.tareas_recibidas / max) * 100) + '%' })),
          el('b', { class: 'num-verde', text: String(n.tareas_recibidas) }))))));
      sec.appendChild(el('div', { class: 'tabla-wrap' }, el('table', { class: 'tabla tabla-niveles-ficha' },
        el('thead', null, el('tr', null, el('th', { scope: 'col', text: 'Nivel' }), el('th', { scope: 'col', class: 'num', text: 'Normales' }),
          el('th', { scope: 'col', class: 'num' }, el('abbr', { title: 'Repeticiones', text: 'Repet.' })), el('th', { scope: 'col', text: 'Tareas recibidas' }))),
        tb)));
    }
    caja.appendChild(sec);

    // Posiciones (con Mover)
    const pos = el('section', { class: 'ficha-sec' }, el('h4', { text: 'Posiciones' }));
    if (!f.posiciones.length) pos.appendChild(el('p', { class: 'mut', text: 'No tiene posiciones.' + (f.espera.length ? ' En lista de espera de: ' + f.espera.join(', ') + '.' : '') }));
    f.posiciones.forEach((y) => {
      pos.appendChild(el('div', { class: 'ficha-pos' },
        el('div', null,
          el('b', { text: 'Nivel ' + y.nivel_orden + ' (' + y.nivel + ') · ' + NOMBRE_POSICION[y.posicion] }),
          el('span', { class: 'mut', text: (y.tipo_grupo === 'repetido' ? 'Grupo repetido' : 'Grupo') + ' de ' + (y.recibidor || 'recibidor libre') +
            (ESTADO_CASILLA[y.estado] ? ' · ' + ESTADO_CASILLA[y.estado] : '') })),
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => moverPosicion(d, y), text: 'Mover' })));
    });
    caja.appendChild(pos);

    // Más acciones
    caja.appendChild(el('section', { class: 'ficha-sec' }, el('h4', { text: 'Más acciones' }),
      el('div', { class: 'ficha-botones' },
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => cambiarPatrocinador(d), text: 'Cambiar patrocinador' }),
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => claveTemporal(d), text: 'Cambiar clave' }),
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => enlaceRecuperacion(d), text: 'Copiar enlace de recuperación' }),
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => cambiarFundador(p, !d.es_fundador), text: d.es_fundador ? 'Quitar fundador' : 'Marcar como fundador' }))));

    // Últimos cambios
    const reg = el('section', { class: 'ficha-sec' }, el('h4', { text: 'Últimos cambios del administrador' }));
    if (!f.ultimos_cambios.length) reg.appendChild(el('p', { class: 'mut', text: 'Sin cambios registrados.' }));
    else reg.appendChild(listaRegistro(f.ultimos_cambios, false));
    caja.appendChild(reg);
  }

  // =====================================================================
  // (33) Claves: Edge Function "admin-claves" (la service_role queda en Supabase, nunca aquí)
  // =====================================================================
  const URL_SITIO = new URL('./', location.href).href;

  async function llamarClaves(cuerpo) {
    const { data, error } = await sb.functions.invoke('admin-claves', { body: cuerpo });
    if (!error) return data;
    let texto = error.message || '';
    try { const j = await error.context.json(); if (j && j.error) texto = j.error; } catch (e) { /* sin cuerpo */ }
    if (/Failed to send|NOT_FOUND|404|fetch/i.test(texto) || error.name === 'FunctionsFetchError' || error.name === 'FunctionsRelayError') {
      texto = 'La función "admin-claves" todavía no está desplegada en Supabase. Sigue los pasos de supabase/functions/admin-claves/LEEME.md.';
    }
    throw new Error(texto);
  }

  // Ventana con un valor para copiar o mandar por WhatsApp (la clave se muestra una sola vez)
  function mostrarParaEnviar({ titulo, intro, valor, etiqueta, nota, whatsapp, mensaje, grande }) {
    const viejo = $('dlg-enviar');
    if (viejo) viejo.remove();
    const campo = grande
      ? el('div', { class: 'clave-grande', id: 'dlg-enviar-valor', text: valor })
      : el('input', { class: 'in mono', id: 'dlg-enviar-valor', readonly: true, value: valor, 'aria-label': etiqueta });
    const estado = el('span', { class: 'mut', 'aria-live': 'polite' });
    const dlg = el('dialog', { class: 'modal', id: 'dlg-enviar', 'aria-labelledby': 'dlg-enviar-t' },
      el('div', { class: 'modal-cuerpo' },
        el('h3', { id: 'dlg-enviar-t', text: titulo }),
        el('p', { class: 'modal-p', text: intro }),
        campo,
        el('div', { class: 'enviar-botones' },
          el('button', { type: 'button', class: 'btn', onclick: async () => { estado.textContent = (await copiarTexto(valor)) ? '¡Copiado!' : 'No se pudo copiar: selecciónalo y cópialo a mano.'; }, text: 'Copiar' }),
          whatsapp
            ? el('a', { class: 'bo', href: enlaceWhatsApp(whatsapp, mensaje), target: '_blank', rel: 'noopener', text: 'Enviar por WhatsApp' })
            : el('span', { class: 'mut', text: 'Sin WhatsApp registrado' })),
        estado,
        nota ? el('div', { class: 'modal-nota', text: nota }) : null,
        el('div', { class: 'modal-botones' }, el('button', { type: 'button', class: 'bo', onclick: () => dlg.close(), text: 'Cerrar' }))));
    dlg.addEventListener('close', () => dlg.remove());
    document.body.appendChild(dlg);
    dlg.showModal();
    if (!grande) campo.select();
  }

  async function claveTemporal(d) {
    if (ocupado) return;
    const si = await confirmar({
      titulo: 'Cambiar clave de ' + d.nombre_usuario,
      texto: ['Se generará una ', el('b', { text: 'clave temporal' }), ' (por ejemplo Siembra-4827). Su clave actual dejará de funcionar, se cerrarán sus sesiones y, al entrar, tendrá que crear su propia clave nueva.'],
      boton: 'Generar clave temporal'
    });
    if (!si) return;
    ocupado = true;
    document.body.classList.add('trabajando');
    try {
      const r = await llamarClaves({ accion: 'clave_temporal', user_id: d.id });
      mostrarParaEnviar({
        titulo: 'Clave temporal de ' + r.nombre_usuario,
        intro: 'Esta clave se muestra una sola vez. Cópiala o envíala ahora por WhatsApp.',
        valor: r.clave, etiqueta: 'Clave temporal', grande: true,
        nota: 'Al entrar con esta clave se le pedirá crear su clave nueva. La clave no se guarda en el Registro.',
        whatsapp: r.whatsapp,
        mensaje: 'Hola ' + r.nombre_usuario + ', tu clave temporal de Siembra tu Futuro es: ' + r.clave + '\nEntra en ' + URL_SITIO + ' con tu usuario y esta clave. Te pediremos crear tu clave nueva.'
      });
      abrirFicha(d.id);
    } catch (err) {
      aviso(err.message || traducirErrorDatos(err));
    } finally {
      ocupado = false;
      document.body.classList.remove('trabajando');
    }
  }

  async function enlaceRecuperacion(d) {
    if (ocupado) return;
    ocupado = true;
    document.body.classList.add('trabajando');
    try {
      const r = await llamarClaves({ accion: 'enlace_recuperacion', user_id: d.id, redirect_to: URL_SITIO });
      mostrarParaEnviar({
        titulo: 'Enlace de recuperación de ' + r.nombre_usuario,
        intro: 'Con este enlace la persona crea su clave nueva. Sirve una sola vez y vence pronto.',
        valor: r.enlace, etiqueta: 'Enlace de recuperación',
        nota: 'El enlace no se guarda en el Registro (solo que se generó).',
        whatsapp: r.whatsapp,
        mensaje: 'Hola ' + r.nombre_usuario + ', para crear tu clave nueva de Siembra tu Futuro abre este enlace (sirve una sola vez y vence pronto):\n' + r.enlace
      });
      abrirFicha(d.id);
    } catch (err) {
      aviso(err.message || traducirErrorDatos(err));
    } finally {
      ocupado = false;
      document.body.classList.remove('trabajando');
    }
  }

  // "Editar datos": formulario en una ventana; antes de guardar se confirma cada cambio
  async function editarDatos(d) {
    if (ocupado) return;
    const campos = {
      nombre: el('input', { class: 'in', id: 'ed-nombre', value: d.nombre_completo || '', maxlength: '80', autocomplete: 'off' }),
      usuario: el('input', { class: 'in', id: 'ed-usuario', value: d.nombre_usuario || '', maxlength: '20', autocomplete: 'off', autocapitalize: 'none' }),
      correo: el('input', { class: 'in', id: 'ed-correo', type: 'email', value: d.correo || '', maxlength: '120', autocomplete: 'off' }),
      whatsapp: el('input', { class: 'in', id: 'ed-whatsapp', type: 'tel', value: d.whatsapp || '', maxlength: '20', autocomplete: 'off' })
    };
    const err = el('span', { class: 'err', 'aria-live': 'polite' });
    const extra = el('div', { class: 'ficha-form' },
      el('label', { class: 'lb', for: 'ed-nombre' }, 'Nombre completo', campos.nombre),
      el('label', { class: 'lb', for: 'ed-usuario' }, 'Usuario', campos.usuario),
      el('label', { class: 'lb', for: 'ed-correo' }, 'Correo', campos.correo),
      el('label', { class: 'lb', for: 'ed-whatsapp' }, 'WhatsApp', campos.whatsapp),
      err);
    const etiquetas = { nombre: 'Nombre completo', usuario: 'Usuario', correo: 'Correo', whatsapp: 'WhatsApp' };
    const antes = { nombre: d.nombre_completo || '', usuario: d.nombre_usuario || '', correo: (d.correo || '').toLowerCase(), whatsapp: d.whatsapp || '' };
    let nuevo;
    let cambios;
    for (;;) {
      const si = await confirmar({ titulo: 'Editar datos de ' + d.nombre_usuario, texto: 'Corrige los datos y toca Continuar.', extra, boton: 'Continuar' });
      if (!si) return;
      nuevo = { nombre: campos.nombre.value.trim(), usuario: campos.usuario.value.trim().toLowerCase(), correo: campos.correo.value.trim().toLowerCase(), whatsapp: campos.whatsapp.value.trim() };
      cambios = Object.keys(nuevo).filter((k) => nuevo[k] !== antes[k]);
      const ew = nuevo.whatsapp && typeof errorWhatsApp === 'function' ? errorWhatsApp(nuevo.whatsapp) : '';
      if (!cambios.length) err.textContent = 'No cambiaste ningún dato.';
      else if (!/^[a-z0-9_]{3,20}$/.test(nuevo.usuario)) err.textContent = 'El usuario debe tener de 3 a 20 caracteres: minúsculas, números o _.';
      else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(nuevo.correo)) err.textContent = 'El correo no es válido.';
      else if (ew) err.textContent = ew;
      else break;
    }
    const si = await confirmar({
      titulo: 'Guardar cambios de ' + d.nombre_usuario,
      texto: [el('ul', { class: 'equipo-lista' }, ...cambios.map((k) => el('li', null,
        el('b', { text: etiquetas[k] + ': ' }), (antes[k] || '—') + ' → ' + (nuevo[k] || '—'))))].concat(
        cambios.includes('correo') ? [el('div', { class: 'modal-nota', text: 'Con el correo nuevo entrará a la plataforma. Avísale.' })] : []),
      boton: 'Guardar cambios'
    });
    if (!si) return;
    const ok = await ejecutar(
      () => sb.rpc('admin_editar_usuario', { p_user_id: d.id, p_nombre_completo: nuevo.nombre, p_nombre_usuario: nuevo.usuario, p_correo: nuevo.correo, p_whatsapp: nuevo.whatsapp }),
      'Datos de ' + nuevo.usuario + ' guardados.');
    if (ok) { abrirFicha(d.id); cargarLista(); }
  }

  // "Ver tableros": el Historial de esa persona (cada tablero con su mapa y su PDF)
  async function verTablerosDe(d) {
    const { data, error } = await sb.rpc('admin_historial_usuario', { p_user_id: d.id });
    if (error) return aviso(traducirErrorDatos(error));
    const lista = (data || []).slice().sort((a, b) => String(b.completado_en).localeCompare(String(a.completado_en)));
    const normales = lista.filter((h) => h.repeticion === 0).length;
    const cuerpo = el('div', { class: 'tab-lista' });
    if (!lista.length) cuerpo.appendChild(el('p', { class: 'mut', text: d.nombre_usuario + ' todavía no completó ningún tablero.' }));
    lista.forEach((h) => cuerpo.appendChild(el('div', { class: 'tab-item' },
      el('div', { class: 'tab-info' },
        el('b', { text: tituloNivel(h) }),
        el('span', { class: 'pill ' + (h.repeticion > 0 ? 'pill-amarilla' : 'pill-verde'), text: tipoTablero(h) }),
        el('span', { class: 'mut', text: formatoFecha(h.completado_en) + ' · ' + h.tareas_recibidas + ' tareas' })),
      el('div', { class: 'tab-botones' },
        el('button', { type: 'button', class: 'btn btn-chico', onclick: () => verTableroDialogo(h, null), text: 'Ver tablero' }),
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => { dlg.close(); descargarPdfTablero(h, null); }, text: 'Descargar PDF' })))));
    const viejo = $('dlg-tableros-de');
    if (viejo) viejo.remove();
    const dlg = el('dialog', { class: 'modal modal-tablero', id: 'dlg-tableros-de', 'aria-labelledby': 'dlg-tableros-de-t' },
      el('div', { class: 'modal-cuerpo' },
        el('h3', { id: 'dlg-tableros-de-t', text: 'Tableros de ' + d.nombre_usuario }),
        el('div', { class: 'mut', text: lista.length + (lista.length === 1 ? ' tablero completado' : ' tableros completados') + ': ' + normales + (normales === 1 ? ' normal · ' : ' normales · ') + (lista.length - normales) + (lista.length - normales === 1 ? ' repetición' : ' repeticiones') }),
        cuerpo,
        el('div', { class: 'modal-botones' }, el('button', { type: 'button', class: 'bo', onclick: () => dlg.close(), text: 'Cerrar' }))));
    dlg.addEventListener('close', () => dlg.remove());
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  // "Ver en el árbol": abre la pestaña Árbol con esa persona marcada
  let arbolResaltar = null;
  function verEnArbol(d) {
    arbolResaltar = d.id;
    $('ficha').classList.remove('abierta');
    document.body.classList.remove('ficha-abierta');
    $('buscar-arbol').value = d.nombre_usuario;
    mostrarTab('arbol');
  }

  async function cambiarPatrocinador(d) {
    if (!perfiles.length) await cargarPerfiles();
    const elegido = await elegirDeLista({
      titulo: 'Nuevo patrocinador de ' + d.nombre_usuario,
      sub: 'Su patrocinador actual es ' + (d.patrocinador || 'nadie') + '. Si el nuevo ya tiene 2 referidos activos, quedará en su lista de espera.',
      items: perfiles.filter((x) => x.id !== d.id && x.id !== d.patrocinador_id).map((x) => ({
        titulo: (x.numero ? numeroSocio(x.numero) + ' · ' : '') + x.nombre_usuario, sub: x.nombre_completo || '', valor: x })),
      vacio: 'No hay otros socios.'
    });
    if (!elegido) return;
    const si = await confirmar({
      titulo: 'Cambiar patrocinador',
      texto: ['¿Poner a ', el('b', { text: d.nombre_usuario }), ' debajo de ', el('b', { text: elegido.nombre_usuario }),
        ' (antes: ' + (d.patrocinador || 'sin patrocinador') + ')? Sus posiciones no cambian. Si era referido activo de su patrocinador anterior, a ese patrocinador se le libera un lugar.'],
      boton: 'Cambiar patrocinador'
    });
    if (!si) return;
    const ok = await ejecutar(() => sb.rpc('admin_cambiar_patrocinador', { p_user_id: d.id, p_nuevo: elegido.id }),
      'Ahora ' + d.nombre_usuario + ' es referido de ' + elegido.nombre_usuario + '.');
    if (ok) { abrirFicha(d.id); cargarLista(); cargarPerfiles().catch(() => {}); }
  }

  async function moverPosicion(d, x) {
    await cargarNiveles();
    const nivel = await elegirDeLista({
      titulo: 'Mover a ' + d.nombre_usuario,
      sub: 'Ahora está en ' + NOMBRE_POSICION[x.posicion] + ' del nivel ' + x.nivel + '. Elige el nivel de destino.',
      items: niveles.map((n) => ({ titulo: n.orden + '. ' + n.nombre + (n.id === x.nivel_id ? ' (el mismo nivel)' : ''), valor: n })),
      vacio: 'No hay niveles.'
    });
    if (!nivel) return;
    const { data, error } = await sb.rpc('admin_casillas_libres', { p_nivel_id: nivel.id });
    if (error) return aviso(traducirErrorDatos(error));
    const casilla = await elegirDeLista({
      titulo: 'Casilla libre en ' + nivel.nombre,
      sub: 'Solo se muestran casillas libres de grupos activos con alguien arriba.',
      items: (data || []).filter((c) => c.posicion_id !== x.posicion_id).map((c) => ({
        titulo: NOMBRE_POSICION[c.posicion] + ' · grupo de ' + (c.recibidor || 'recibidor libre'),
        sub: c.debajo_de ? 'Debajo de ' + c.debajo_de : '', valor: c })),
      vacio: 'No hay casillas libres en este nivel. Crea un grupo en la pestaña Grupos.'
    });
    if (!casilla) return;
    const si = await confirmar({
      titulo: 'Mover posición',
      texto: ['¿Mover a ', el('b', { text: d.nombre_usuario }), ' de ' + NOMBRE_POSICION[x.posicion] + ' (nivel ' + x.nivel + ') a ' +
        NOMBRE_POSICION[casilla.posicion] + ' del grupo de ' + (casilla.recibidor || 'recibidor libre') + ' (nivel ' + nivel.nombre + ')? Recibirá una notificación.'],
      boton: 'Mover'
    });
    if (!si) return;
    const ok = await ejecutar(() => sb.rpc('admin_mover_posicion', { p_desde: x.posicion_id, p_hacia: casilla.posicion_id }),
      d.nombre_usuario + ' fue movido a ' + NOMBRE_POSICION[casilla.posicion] + '.');
    if (ok) abrirFicha(d.id);
  }

  // =====================================================================
  // (30) ÁRBOL
  // =====================================================================
  let arbolDatos = [];
  let hijosDe = {};
  function numeroSocio(n) { return n == null ? '' : String(n).padStart(3, '0'); }

  function etiquetaNodo(u) {
    const hijos = (hijosDe[u.id] || []).length;
    return el('span', { class: 'arbol-et' + (u.id === arbolResaltar ? ' resaltado' : '') },
      el('span', { class: 'arbol-num', text: u.numero || '—' }),
      el('button', { type: 'button', class: 'arbol-nombre', onclick: (e) => { e.preventDefault(); abrirFicha(u.id); }, text: u.nombre_usuario }),
      u.nombre_completo ? el('span', { class: 'mut arbol-completo', text: u.nombre_completo }) : null,
      u.es_fundador ? el('span', { class: 'pill pill-amarilla', text: 'Fundador' }) : null,
      u.referido_estado && u.referido_estado !== 'activo' ? el('span', { class: 'pill pill-gris', text: ESTADO_REFERIDO[u.referido_estado] || u.referido_estado }) : null,
      u.nivel ? el('span', { class: 'pill pill-verde', text: u.nivel }) : null,
      hijos ? el('span', { class: 'mut arbol-hijos', text: hijos + (hijos === 1 ? ' referido' : ' referidos') }) : null);
  }

  // Cada rama se arma recién cuando se abre (el árbol puede tener miles de personas)
  function nodoArbol(u, visibles, abierto) {
    const hijos = (hijosDe[u.id] || []).filter((h) => !visibles || visibles.has(h.id));
    if (!hijos.length) return el('div', { class: 'arbol-hoja' }, etiquetaNodo(u));
    const det = el('details', { class: 'arbol-rama' }, el('summary', null, etiquetaNodo(u)));
    const cont = el('div', { class: 'arbol-hijos-caja' });
    det.appendChild(cont);
    let armado = false;
    const armar = () => {
      if (armado) return;
      armado = true;
      hijos.forEach((h) => cont.appendChild(nodoArbol(h, visibles, abierto)));
    };
    det.addEventListener('toggle', () => { if (det.open) armar(); });
    if (abierto) { det.open = true; armar(); }
    return det;
  }

  function pintarArbol() {
    const caja = $('arbol');
    vaciar(caja);
    const q = normalizar($('buscar-arbol').value.trim());
    const porId = {};
    arbolDatos.forEach((u) => { porId[u.id] = u; });
    const raices = arbolDatos.filter((u) => !u.patrocinador_id || !porId[u.patrocinador_id]);
    let visibles = null;
    if (q) {
      visibles = new Set();
      arbolDatos.forEach((u) => {
        if ([u.numero, u.nombre_usuario, u.nombre_completo].some((v) => normalizar(v).includes(q))) {
          for (let x = u; x && !visibles.has(x.id); x = porId[x.patrocinador_id]) visibles.add(x.id);
        }
      });
    }
    const mostrar = raices.filter((r) => !visibles || visibles.has(r.id));
    $('cuenta-arbol').textContent = q
      ? (visibles.size ? 'Se muestran las ramas con coincidencias.' : 'Nadie coincide con la búsqueda.')
      : arbolDatos.length + ' socios · ' + raices.length + (raices.length === 1 ? ' raíz' : ' raíces');
    mostrar.forEach((r) => caja.appendChild(nodoArbol(r, visibles, !!q)));
  }

  async function cargarArbol() {
    const caja = $('arbol');
    vaciar(caja);
    caja.appendChild(el('p', { class: 'mut', text: 'Cargando árbol…' }));
    const { data, error } = await sb.rpc('admin_arbol');
    if (error) {
      vaciar(caja);
      caja.appendChild(el('div', { class: 'msg error', text: 'No se pudo cargar el árbol. ' + traducirErrorDatos(error) }));
      return;
    }
    arbolDatos = data || [];
    hijosDe = {};
    arbolDatos.forEach((u) => { if (u.patrocinador_id) (hijosDe[u.patrocinador_id] = hijosDe[u.patrocinador_id] || []).push(u); });
    pintarArbol();
  }
  let tArbol;
  $('buscar-arbol').addEventListener('input', () => { arbolResaltar = null; clearTimeout(tArbol); tArbol = setTimeout(pintarArbol, 200); });
  $('btn-arbol-abrir').addEventListener('click', () => {
    // Abre las ramas ya armadas y la primera capa de las demás
    $('arbol').querySelectorAll('details').forEach((d) => { d.open = true; });
  });
  $('btn-arbol-cerrar').addEventListener('click', () => { $('arbol').querySelectorAll('details').forEach((d) => { d.open = false; }); });

  // =====================================================================
  // (30) REGISTRO DE CAMBIOS
  // =====================================================================
  function listaRegistro(filas, conUsuario) {
    const ul = el('ul', { class: 'registro-lista' });
    filas.forEach((r) => {
      ul.appendChild(el('li', { class: 'registro-item' },
        el('div', { class: 'registro-cab' },
          el('span', { class: 'pill pill-verde', text: r.accion }),
          conUsuario && r.usuario_nombre
            ? (r.usuario_id && r.accion !== 'Cuenta eliminada' ? el('button', { type: 'button', class: 'link registro-usuario', onclick: () => abrirFicha(r.usuario_id), text: r.usuario_nombre })
                            : el('b', { text: r.usuario_nombre }))
            : null,
          el('span', { class: 'mut registro-fecha', text: fechaHoraLarga(r.creado_en) + ' · por ' + (r.admin_nombre || 'administrador') })),
        r.detalle ? el('div', { class: 'registro-detalle', text: r.detalle }) : null,
        (r.valor_anterior != null || r.valor_nuevo != null)
          ? el('div', { class: 'registro-valores' },
              el('span', { class: 'registro-antes', text: 'Antes: ' + (r.valor_anterior == null ? '—' : r.valor_anterior) }),
              el('span', { class: 'registro-flecha', 'aria-hidden': 'true', text: '→' }),
              el('span', { class: 'registro-ahora', text: 'Ahora: ' + (r.valor_nuevo == null ? '—' : r.valor_nuevo) }))
          : null));
    });
    return ul;
  }

  let regDesde = 0;
  let regTurno = 0;
  async function cargarRegistro(mas) {
    const turno = ++regTurno;
    if (!mas) regDesde = 0;
    const q = $('buscar-registro').value.trim();
    const { data, error } = await sb.rpc('admin_ver_registro', { p_buscar: q || null, p_cuantos: 50, p_desde: regDesde });
    if (turno !== regTurno) return;
    const caja = $('registro');
    if (!mas) vaciar(caja);
    if (error) {
      caja.appendChild(el('div', { class: 'msg error', text: 'No se pudo cargar el registro. ' + traducirErrorDatos(error) }));
      $('btn-registro-mas').hidden = true;
      return;
    }
    if (!data.filas.length && !mas) caja.appendChild(el('p', { class: 'mut', text: q ? 'Nada coincide con la búsqueda.' : 'Todavía no hay cambios registrados.' }));
    else caja.appendChild(listaRegistro(data.filas, true));
    regDesde += data.filas.length;
    $('cuenta-registro').textContent = data.total + (data.total === 1 ? ' cambio' : ' cambios');
    $('btn-registro-mas').hidden = regDesde >= data.total;
  }
  let tReg;
  $('buscar-registro').addEventListener('input', () => { clearTimeout(tReg); tReg = setTimeout(() => cargarRegistro(false), 250); });
  $('btn-registro-mas').addEventListener('click', () => cargarRegistro(true));

  // =====================================================================
  // GRUPOS
  // =====================================================================
  const filtro = $('filtro-nivel');
  filtro.addEventListener('change', cargarGrupos);

  const COLUMNAS_POS = 'id, grupo_id, posicion, cuelga_de, user_id, estado, origen, reservada_en, tarea_hecha_en, ascendido_en, asignado_en';

  let turnoGrupos = 0;
  async function cargarGrupos() {
    const turno = ++turnoGrupos;
    const cont = $('lista-grupos');
    try {
      await cargarNiveles();
      const nivelId = Number(filtro.value);
      const [rg, rp] = await Promise.all([
        sb.from('grupos').select('id, estado, creado_en').eq('nivel_id', nivelId).order('creado_en', { ascending: false }),
        sb.from('posiciones').select(COLUMNAS_POS).eq('nivel_id', nivelId),
        cargarPerfiles()
      ]);
      if (rg.error) throw rg.error;
      if (rp.error) throw rp.error;
      if (turno !== turnoGrupos) return;
      pintarGrupos(nivelId, rg.data, rp.data);
    } catch (err) {
      if (turno !== turnoGrupos) return;
      vaciar(cont);
      cont.appendChild(el('div', { class: 'msg error', text: 'No se pudieron cargar los grupos. ' + traducirErrorDatos(err) }));
    }
  }

  function pintarGrupos(nivelId, grupos, posiciones) {
    const cont = $('lista-grupos');
    vaciar(cont);

    if (!grupos.length) {
      cont.appendChild(el('section', { class: 'card aviso-vacio' },
        el('h3', { text: 'No hay grupos en el nivel ' + nombreNivel(nivelId) }),
        el('p', { class: 'mut', text: 'Usa "Crear grupo fundador" para armar el primero.' })
      ));
      return;
    }

    grupos.forEach((g, i) => {
      const numero = grupos.length - i;
      const pos = posiciones
        .filter((p) => p.grupo_id === g.id)
        .map((p) => Object.assign({}, p, { nombre_usuario: nombreDe(p.user_id) }));
      const porPos = {};
      pos.forEach((p) => { porPos[p.posicion] = p; });
      const vacio = pos.every((p) => !p.user_id);

      // Siguiente casilla obligatoria: Recibidor -> Constructor 1 -> Constructor 2
      const siguiente = ['recibidor', 'constructor_1', 'constructor_2']
        .find((k) => !(porPos[k] && porPos[k].user_id)) || null;

      const ctx = { grupo: g, numero, nivelId, siguiente };
      const estado = g.estado === 'completado' ? 'completado' : 'activo';

      // Grupo completado: sus 7 casillas quedaron libres al dividirse en 2 grupos nuevos
      if (estado === 'completado') {
        cont.appendChild(el('section', { class: 'card grupo-admin grupo-completado' },
          el('div', { class: 'grupo-cabecera-admin' },
            el('div', null,
              el('div', { class: 'grupo-titulo', text: 'Grupo #' + numero + ' · Nivel ' + nombreNivel(nivelId) }),
              el('div', { class: 'mut', text: 'Creado el ' + formatoFecha(g.creado_en) + ' · El recibidor recibió sus 4 tareas y el grupo se dividió en 2 grupos nuevos.' })
            ),
            el('div', { class: 'grupo-cabecera-der' },
              el('span', { class: 'estado-chip completado', text: 'Estado: completado' }))
          )
        ));
        return;
      }

      cont.appendChild(el('section', { class: 'card grupo-admin' },
        el('div', { class: 'grupo-cabecera-admin' },
          el('div', null,
            el('div', { class: 'grupo-titulo', text: 'Grupo #' + numero + ' · Nivel ' + nombreNivel(nivelId) }),
            el('div', { class: 'mut', text: 'Creado el ' + formatoFecha(g.creado_en) + ' · ' + pos.filter((p) => p.user_id).length + '/7 casillas ocupadas' })
          ),
          el('div', { class: 'grupo-cabecera-der' },
            el('span', { class: 'estado-chip ' + estado, text: 'Estado: ' + estado }),
            vacio ? el('button', { type: 'button', class: 'bt-salir bt-chico', onclick: () => eliminarGrupo(ctx), text: 'Eliminar grupo' }) : null
          )
        ),
        crearMapaGrupo(pos, { acciones: (p) => accionesCasilla(p, ctx) })
      ));
    });
  }

  function accionesCasilla(p, ctx) {
    const caja = el('div', { class: 'cas-acciones' });
    if (p.user_id) {
      if (p.origen === 'automatico' && esRegalador(p.posicion) && p.reservada_en) {
        caja.appendChild(el('div', { class: 'cas-pista', text: '⏱ reloj de la tarea' }));
      } else if (p.ascendido_en) {
        caja.appendChild(el('div', { class: 'cas-pista', text: '⏱ reloj para invitar' }));
      }
      caja.append(
        el('button', { type: 'button', class: 'cb', onclick: () => reemplazar(p, ctx), text: 'Reemplazar' }),
        el('button', { type: 'button', class: 'cb cb-quitar', onclick: () => quitar(p, ctx), text: 'Quitar' })
      );
      return caja;
    }
    if (!p.id) return null;
    const permitido = ctx.siguiente === null || ctx.siguiente === p.posicion;
    caja.appendChild(el('button', {
      type: 'button', class: 'cb cb-asignar', disabled: !permitido,
      title: permitido ? null : 'Primero asigna ' + NOMBRE_POSICION[ctx.siguiente],
      onclick: () => asignar(p, ctx), text: 'Asignar'
    }));
    if (!permitido) caja.appendChild(el('div', { class: 'cas-pista', text: 'Primero: ' + NOMBRE_POSICION[ctx.siguiente] }));
    return caja;
  }

  // Usuarios registrados sin posición en el nivel (datos frescos)
  async function candidatos(nivelId) {
    await cargarPerfiles();
    const { data, error } = await sb.from('posiciones').select('user_id').eq('nivel_id', nivelId).not('user_id', 'is', null);
    if (error) throw error;
    const ocupados = new Set(data.map((x) => x.user_id));
    return perfiles
      .filter((p) => !ocupados.has(p.id))
      .sort((a, b) => a.nombre_usuario.localeCompare(b.nombre_usuario))
      .map((p) => ({ titulo: p.nombre_usuario, sub: p.nombre_completo || 'Sin nombre completo', valor: p }));
  }

  async function asignar(p, ctx) {
    if (ocupado) return;
    let items;
    try { items = await candidatos(ctx.nivelId); } catch (err) { return aviso(traducirErrorDatos(err)); }
    const usuario = await elegirDeLista({
      titulo: 'Asignar ' + NOMBRE_POSICION[p.posicion],
      sub: 'Grupo #' + ctx.numero + ' · Nivel ' + nombreNivel(ctx.nivelId) + '. Solo aparecen usuarios sin posición en este nivel.',
      items,
      vacio: 'No hay usuarios registrados sin posición en este nivel.'
    });
    if (!usuario) return;
    const si = await confirmar({
      titulo: 'Confirmar asignación',
      texto: ['¿Asignar a ', el('b', { text: usuario.nombre_usuario }), ' como ', el('b', { text: NOMBRE_POSICION[p.posicion] }),
        ' en el Grupo #' + ctx.numero + ' (' + nombreNivel(ctx.nivelId) + ')? Quedará sin relojes.'],
      boton: 'Asignar'
    });
    if (!si) return;
    const ok = await ejecutar(
      () => sb.rpc('admin_asignar_posicion', { p_posicion_id: p.id, p_user_id: usuario.id }),
      usuario.nombre_usuario + ' asignado como ' + NOMBRE_POSICION[p.posicion] + '.'
    );
    if (ok) { cargarGrupos(); actualizarBadgeEspera(); }
  }

  async function reemplazar(p, ctx) {
    if (ocupado) return;
    let items;
    try { items = await candidatos(ctx.nivelId); } catch (err) { return aviso(traducirErrorDatos(err)); }
    const actual = p.nombre_usuario || 'la persona actual';
    const usuario = await elegirDeLista({
      titulo: 'Reemplazar a ' + actual,
      sub: NOMBRE_POSICION[p.posicion] + ' · Grupo #' + ctx.numero + '. Solo aparecen usuarios sin posición en este nivel.',
      items,
      vacio: 'No hay usuarios registrados sin posición en este nivel.'
    });
    if (!usuario) return;
    const si = await confirmar({
      titulo: 'Confirmar reemplazo',
      texto: ['¿Reemplazar a ', el('b', { text: actual }), ' por ', el('b', { text: usuario.nombre_usuario }),
        ' en ' + NOMBRE_POSICION[p.posicion] + ' (Grupo #' + ctx.numero + ')? ', actual + ' quedará sin posición en este nivel.'],
      boton: 'Reemplazar'
    });
    if (!si) return;
    const ok = await ejecutar(
      () => sb.rpc('admin_asignar_posicion', { p_posicion_id: p.id, p_user_id: usuario.id }),
      actual + ' fue reemplazado por ' + usuario.nombre_usuario + '.'
    );
    if (ok) { cargarGrupos(); actualizarBadgeEspera(); }
  }

  async function quitar(p, ctx) {
    if (ocupado) return;
    const actual = p.nombre_usuario || 'esta persona';
    const si = await confirmar({
      titulo: 'Quitar de la casilla',
      texto: ['¿Quitar a ', el('b', { text: actual }), ' de ' + NOMBRE_POSICION[p.posicion] + ' (Grupo #' + ctx.numero + ')? La casilla quedará libre.'],
      boton: 'Quitar',
      peligro: true
    });
    if (!si) return;
    const ok = await ejecutar(
      () => sb.rpc('admin_quitar_posicion', { p_posicion_id: p.id }),
      actual + ' fue quitado de ' + NOMBRE_POSICION[p.posicion] + '.'
    );
    if (ok) cargarGrupos();
  }

  async function eliminarGrupo(ctx) {
    if (ocupado) return;
    const si = await confirmar({
      titulo: 'Eliminar grupo',
      texto: '¿Eliminar el Grupo #' + ctx.numero + ' del nivel ' + nombreNivel(ctx.nivelId) + '? Está vacío; esta acción no se puede deshacer.',
      boton: 'Eliminar',
      peligro: true
    });
    if (!si) return;
    const ok = await ejecutar(() => sb.rpc('admin_eliminar_grupo', { p_grupo_id: ctx.grupo.id }), 'Grupo eliminado.');
    if (ok) cargarGrupos();
  }

  $('btn-crear-grupo').addEventListener('click', async () => {
    if (ocupado) return;
    try { await cargarNiveles(); } catch (err) { return aviso(traducirErrorDatos(err)); }

    const sel = el('select', { class: 'in sel', id: 'crear-nivel' });
    niveles.forEach((n) => sel.appendChild(el('option', { value: String(n.id), text: n.orden + '. ' + n.nombre })));
    const terreno = niveles[0]; // primer nivel por orden
    if (terreno) sel.value = String(terreno.id);

    const si = await confirmar({
      titulo: 'Crear grupo fundador',
      texto: 'Se creará un grupo nuevo con sus 7 casillas vacías. Después asigna Recibidor, Constructor 1 y Constructor 2.',
      extra: el('label', { class: 'lb', for: 'crear-nivel' }, 'Nivel', sel),
      boton: 'Crear grupo'
    });
    if (!si) return;
    const nivelId = Number(sel.value);
    const ok = await ejecutar(
      () => sb.rpc('admin_crear_grupo', { p_nivel_id: nivelId }),
      'Grupo fundador creado en el nivel ' + nombreNivel(nivelId) + '.'
    );
    if (ok) {
      filtro.value = String(nivelId);
      cargarGrupos();
    }
  });

  // =====================================================================
  // LISTA DE ESPERA
  // =====================================================================
  let turnoEspera = 0;
  async function cargarEspera() {
    const turno = ++turnoEspera;
    const tb = $('tabla-espera');
    try {
      await cargarNiveles();
      const [r] = await Promise.all([
        sb.from('lista_espera').select('user_id, nivel_id, creado_en').order('creado_en'),
        cargarPerfiles()
      ]);
      if (r.error) throw r.error;
      if (turno !== turnoEspera) return;

      // Por nivel (según niveles.orden) y, dentro del nivel, por antigüedad
      const ordenDe = (id) => { const n = niveles.find((x) => x.id === id); return n ? n.orden : 999; };
      r.data.sort((a, b) => (ordenDe(a.nivel_id) - ordenDe(b.nivel_id)) || (Date.parse(a.creado_en) - Date.parse(b.creado_en)));

      vaciar(tb);
      $('cuenta-espera').textContent = r.data.length === 1 ? '1 persona' : r.data.length + ' personas';
      const b = $('badge-espera');
      b.textContent = String(r.data.length);
      b.hidden = !r.data.length;

      if (!r.data.length) {
        tb.appendChild(el('tr', null, el('td', { colspan: '6', class: 'mut', text: 'No hay nadie en lista de espera.' })));
        return;
      }
      r.data.forEach((f) => {
        const p = perfilPorId[f.user_id] || {};
        tb.appendChild(el('tr', null,
          el('td', null, el('b', { text: p.nombre_usuario || '—' })),
          el('td', { text: p.nombre_completo || '—' }),
          el('td', { text: nombreNivel(f.nivel_id) }),
          el('td', { text: nombreDe(p.invitado_por) || '—' }),
          el('td', { text: tiempoRelativo(f.creado_en) }),
          el('td', null, el('button', { type: 'button', class: 'btn btn-chico', onclick: () => asignarDesdeEspera(f, p), text: 'Asignar' }))
        ));
      });
    } catch (err) {
      if (turno !== turnoEspera) return;
      vaciar(tb);
      tb.appendChild(el('tr', null, el('td', { colspan: '6', class: 'msg error', text: 'No se pudo cargar la lista de espera. ' + traducirErrorDatos(err) })));
    }
  }

  async function asignarDesdeEspera(fila, perfil) {
    if (ocupado) return;
    const nombre = perfil.nombre_usuario || 'esta persona';
    let items;
    const numero = {};
    try {
      const [rg, rp] = await Promise.all([
        sb.from('grupos').select('id, estado, creado_en').eq('nivel_id', fila.nivel_id).order('creado_en'),
        sb.from('posiciones').select(COLUMNAS_POS).eq('nivel_id', fila.nivel_id)
      ]);
      if (rg.error) throw rg.error;
      if (rp.error) throw rp.error;
      rg.data.forEach((g, i) => { numero[g.id] = i + 1; });
      const porGrupoPos = {};
      rp.data.forEach((p) => { porGrupoPos[p.grupo_id + ':' + p.posicion] = p; });

      const activos = new Set(rg.data.filter((g) => g.estado === 'activo').map((g) => g.id));
      items = rp.data
        .filter((p) => !p.user_id && activos.has(p.grupo_id))
        .sort((a, b) => (numero[a.grupo_id] - numero[b.grupo_id]) || (POSICIONES.indexOf(a.posicion) - POSICIONES.indexOf(b.posicion)))
        .map((p) => {
          const padre = p.cuelga_de ? porGrupoPos[p.grupo_id + ':' + p.cuelga_de] : null;
          return {
            titulo: 'Grupo #' + numero[p.grupo_id] + ' · ' + NOMBRE_POSICION[p.posicion],
            sub: padre
              ? 'Cuelga de ' + NOMBRE_POSICION[p.cuelga_de] + ' (' + (padre.user_id ? (nombreDe(padre.user_id) || '—') : 'libre') + ')'
              : 'Centro del grupo',
            valor: p
          };
        });
    } catch (err) {
      return aviso(traducirErrorDatos(err));
    }

    const pos = await elegirDeLista({
      titulo: 'Asignar a ' + nombre,
      sub: 'Elige una casilla libre del nivel ' + nombreNivel(fila.nivel_id) + '.',
      items,
      vacio: 'No hay casillas libres en el nivel ' + nombreNivel(fila.nivel_id) + '. Crea un grupo fundador o libera una casilla.'
    });
    if (!pos) return;

    const chk = el('input', { type: 'checkbox', id: 'chk-relojes', checked: true });
    const si = await confirmar({
      titulo: 'Confirmar asignación',
      texto: ['¿Asignar a ', el('b', { text: nombre }), ' como ', el('b', { text: NOMBRE_POSICION[pos.posicion] }),
        ' en el Grupo #' + numero[pos.grupo_id] + ' (' + nombreNivel(fila.nivel_id) + ')?'],
      extra: el('label', { class: 'check', for: 'chk-relojes' }, chk,
        el('span', { text: 'Con relojes, igual que si hubiera entrado al tocar Participar (regalador: plazo para la tarea; constructor: plazo para invitar a 2 personas; el recibidor nunca tiene relojes).' })),
      boton: 'Asignar'
    });
    if (!si) return;
    const ok = await ejecutar(
      () => sb.rpc('admin_asignar_desde_espera', { p_user_id: fila.user_id, p_posicion_id: pos.id, p_con_relojes: chk.checked }),
      nombre + ' asignado como ' + NOMBRE_POSICION[pos.posicion] + '.'
    );
    if (ok) cargarEspera();
  }

  // =====================================================================
  // CONFIGURACIÓN
  // =====================================================================
  const CLAVES = ['horas_tarea', 'horas_aviso', 'dias_invitar'];

  async function cargarConfig() {
    const { data, error } = await sb.from('configuracion').select('clave, valor');
    if (error) return aviso('No se pudo cargar la configuración. ' + traducirErrorDatos(error));
    data.forEach((c) => {
      const inp = $('cfg-' + c.clave);
      if (inp) inp.value = String(Number(c.valor));
    });
    const exige = data.find((c) => c.clave === 'registro_exige_link');
    const chk = $('chk-exige-link');
    chk.disabled = !exige; // sin el SQL 12 la opción no existe
    chk.checked = !exige || Number(exige.valor) !== 0;
    cargarDiasNivel();
    cargarEnlaces();
  }

  // ---------- Enlaces de soporte (tabla enlaces_soporte) ----------
  const CLAVES_ENLACE = ['telegram', 'linktree', 'whatsapp', 'correo'];
  let enlacesOriginal = {};

  async function cargarEnlaces() {
    const { data, error } = await sb.from('enlaces_soporte').select('clave, valor, activo');
    if (error) {
      $('enlaces-msg').textContent = 'No se pudieron cargar los enlaces de soporte. ' + traducirErrorDatos(error);
      $('enlaces-msg').hidden = false;
      return;
    }
    enlacesOriginal = {};
    data.forEach((e) => {
      enlacesOriginal[e.clave] = { valor: e.valor || '', activo: !!e.activo };
      if ($('enl-' + e.clave)) {
        $('enl-' + e.clave).value = e.valor || '';
        $('enl-act-' + e.clave).checked = !!e.activo;
      }
    });
  }

  function validarEnlace(clave, valor, activo) {
    if (!valor) return activo ? 'Para activar un enlace primero escribe su valor.' : '';
    if ((clave === 'telegram' || clave === 'linktree') && !/^https:\/\/\S+\.\S+$/i.test(valor)) return 'El enlace debe empezar con https://';
    if (clave === 'whatsapp' && !normalizarWhatsApp(valor, 'Ecuador')) return 'El WhatsApp de soporte no es válido. Para Ecuador escribe, por ejemplo, 0999999999. Para otros países usa + y el código de país.';
    if (clave === 'correo' && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(valor)) return 'El correo no es válido.';
    return '';
  }

  $('form-enlaces').addEventListener('submit', async (e) => {
    e.preventDefault();
    const msg = $('enlaces-msg');
    msg.hidden = true;
    const cambios = [];
    for (const k of CLAVES_ENLACE) {
      let valor = $('enl-' + k).value.trim();
      const activo = $('enl-act-' + k).checked;
      const err = validarEnlace(k, valor, activo);
      // WhatsApp de soporte: acepta 0999…, 593…, +593…; se guarda solo con dígitos (593991234567), como lo usa wa.me
      if (!err && k === 'whatsapp' && valor) valor = normalizarWhatsApp(valor, 'Ecuador').slice(1);
      if (err) {
        msg.textContent = err;
        msg.hidden = false;
        $('enl-' + k).focus();
        return;
      }
      const o = enlacesOriginal[k] || { valor: '', activo: false };
      if (o.valor !== valor || o.activo !== activo) cambios.push({ k, valor, activo });
    }
    if (!cambios.length) {
      msg.textContent = 'No hay cambios para guardar.';
      msg.hidden = false;
      return;
    }
    const ok = await ejecutar(async () => {
      for (const c of cambios) {
        const r = await sb.rpc('admin_guardar_enlace', { p_clave: c.k, p_valor: c.valor || null, p_activo: c.activo });
        if (r.error) return r;
      }
      return { data: null, error: null };
    }, 'Enlaces de soporte guardados.');
    if (ok) cargarEnlaces();
  });

  // ---------- Días para invitar por nivel (11 niveles, ordenados por niveles.orden) ----------
  async function cargarDiasNivel() {
    const tb = $('tabla-dias');
    try {
      await cargarNiveles();
      const { data, error } = await sb.from('dias_invitar_nivel').select('nivel_id, dias');
      if (error) throw error;
      const porNivel = {};
      data.forEach((d) => { porNivel[d.nivel_id] = d.dias; });
      vaciar(tb);
      niveles.forEach((n) => {
        tb.appendChild(el('tr', null,
          el('td', { text: String(n.orden) }),
          el('td', null, el('b', { text: n.nombre })),
          el('td', null, el('input', {
            class: 'in in-dias', type: 'number', inputmode: 'decimal', step: 'any', min: '0',
            id: 'dias-nivel-' + n.id, 'data-nivel': String(n.id), 'data-original': porNivel[n.id] != null ? String(Number(porNivel[n.id])) : '',
            value: porNivel[n.id] != null ? String(Number(porNivel[n.id])) : '',
            placeholder: 'General', 'aria-label': 'Días para invitar en ' + n.nombre
          }))
        ));
      });
    } catch (err) {
      vaciar(tb);
      tb.appendChild(el('tr', null, el('td', { colspan: '3', class: 'msg error', text: 'No se pudieron cargar los días por nivel. ' + traducirErrorDatos(err) })));
    }
  }

  $('form-dias-nivel').addEventListener('submit', async (e) => {
    e.preventDefault();
    const msg = $('dias-msg');
    msg.hidden = true;
    const cambios = [];
    for (const inp of document.querySelectorAll('#tabla-dias .in-dias')) {
      const crudo = String(inp.value).trim().replace(',', '.');
      if (crudo === inp.dataset.original) continue;
      const n = crudo === '' ? null : Number(crudo);
      if (n !== null && (!isFinite(n) || n <= 0)) {
        msg.textContent = 'Los días deben ser un número mayor que 0 (o vacío para usar el valor general).';
        msg.hidden = false;
        inp.focus();
        return;
      }
      cambios.push({ nivel: Number(inp.dataset.nivel), dias: n });
    }
    if (!cambios.length) {
      msg.textContent = 'No hay cambios para guardar.';
      msg.hidden = false;
      return;
    }
    const ok = await ejecutar(async () => {
      for (const c of cambios) {
        const r = await sb.rpc('admin_guardar_dias_nivel', { p_nivel_id: c.nivel, p_dias: c.dias });
        if (r.error) return r;
      }
      return { data: null, error: null };
    }, 'Días por nivel guardados. Se aplican de inmediato a los relojes de los constructores.');
    if (ok) cargarDiasNivel();
  });

  // ---------- Interruptor "Exigir link de referido para registrarse" ----------
  $('chk-exige-link').addEventListener('change', async () => {
    const chk = $('chk-exige-link');
    const valor = chk.checked;
    const si = await confirmar({
      titulo: valor ? 'Exigir link para registrarse' : 'Permitir registro sin link',
      texto: valor
        ? 'Solo podrá registrarse quien entre con el link de invitación de alguien de la comunidad.'
        : 'Cualquiera podrá registrarse sin link (sin patrocinador). Úsalo solo para crear a los fundadores y vuelve a activarlo al terminar.',
      boton: valor ? 'Exigir link' : 'Permitir sin link',
      peligro: !valor
    });
    if (!si) { chk.checked = !valor; return; }
    const ok = await ejecutar(
      () => sb.rpc('admin_guardar_registro_exige_link', { p_exige: valor }),
      valor ? 'Ahora se exige link de referido para registrarse.' : 'Registro sin link PERMITIDO. Recuerda volver a activarlo.'
    );
    if (!ok) chk.checked = !valor;
  });

  $('form-config').addEventListener('submit', async (e) => {
    e.preventDefault();
    const msg = $('cfg-msg');
    msg.hidden = true;
    const v = {};
    for (const k of CLAVES) {
      const n = Number(String($('cfg-' + k).value).replace(',', '.'));
      if (!isFinite(n) || n <= 0) {
        msg.textContent = 'Todos los valores deben ser números mayores que 0.';
        msg.hidden = false;
        $('cfg-' + k).focus();
        return;
      }
      v[k] = n;
    }
    if (v.horas_aviso >= v.horas_tarea) {
      msg.textContent = 'Las horas del aviso deben ser menores que las horas para hacer la tarea.';
      msg.hidden = false;
      $('cfg-horas_aviso').focus();
      return;
    }
    const si = await confirmar({
      titulo: 'Guardar configuración',
      texto: 'Tarea: ' + formatoNumero(v.horas_tarea) + ' h · Aviso: ' + formatoNumero(v.horas_aviso) + ' h · Invitar: ' + formatoNumero(v.dias_invitar) +
        ' días. Los cambios se aplican de inmediato a todos los relojes.',
      boton: 'Guardar'
    });
    if (!si) return;
    const ok = await ejecutar(
      () => sb.rpc('admin_guardar_configuracion', { p_horas_tarea: v.horas_tarea, p_horas_aviso: v.horas_aviso, p_dias_invitar: v.dias_invitar }),
      'Configuración guardada.'
    );
    if (ok) cargarConfig();
  });

  $('btn-revisar').addEventListener('click', async () => {
    const si = await confirmar({
      titulo: 'Revisar plazos ahora',
      texto: 'Se aplicarán las reglas de plazos (retirar por tiempo, avisos y plazos vencidos) igual que lo hace pg_cron cada 5 minutos.',
      boton: 'Revisar ahora'
    });
    if (!si) return;
    await ejecutar(
      () => sb.rpc('admin_revisar_plazos'),
      (d) => 'Revisión hecha: ' + (d.retirados || 0) + ' retirado(s) por tiempo, ' + (d.avisos || 0) + ' aviso(s) enviado(s), ' + (d.plazos_vencidos || 0) + ' plazo(s) vencido(s).'
    );
    actualizarBadgeEspera();
  });

  // ---------- Inicio ----------
  mostrarTab('usuarios');
  actualizarBadgeEspera();
})();
