// Panel protegido (panel.html). Usa js/comun.js y js/reloj.js
(async function () {
  'use strict';

  const sb = crearClienteSupabase();

  // ---------- Protección: sin sesión -> index.html ----------
  const session = await exigirParticipante(sb);
  if (!session) return;
  const miId = session.user.id;
  document.body.classList.remove('cargando');

  iniciarCerrarSesion(sb);
  iniciarMenuLateral();

  // Enlace "Administración" solo para administradores
  sb.rpc('es_admin').then(({ data }) => { if (data === true) $('link-admin').hidden = false; });

  // ---------- Aviso general (arriba del contenido) ----------
  let tAviso;
  function aviso(texto, tipo) {
    const m = $('aviso-global');
    m.textContent = texto;
    m.className = 'msg ' + (tipo || 'error');
    m.hidden = false;
    clearTimeout(tAviso);
    if (tipo === 'ok' || tipo === 'info') tAviso = setTimeout(() => { m.hidden = true; }, 7000);
    m.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function cajaError(texto) { return el('div', { class: 'msg error', role: 'alert', text: texto }); }

  // ---------- Relojes activos (se detienen al volver a dibujar) ----------
  const relojes = {};
  function ponerReloj(clave, reloj) {
    if (relojes[clave]) relojes[clave].detener();
    relojes[clave] = reloj || null;
  }

  // ---------- Datos comunes ----------
  let nivelesCache = null;
  async function leerNiveles() {
    if (nivelesCache) return nivelesCache;
    const { data, error } = await sb.from('niveles').select('id, orden, nombre, meta_tareas').order('orden');
    if (error) throw error;
    nivelesCache = data;
    return data;
  }
  function nivelPorId(niveles, id) {
    return niveles.find((n) => n.id === id) || { id, nombre: '—', orden: 0 };
  }
  // ---------- Mis datos por nivel (una posición activa por nivel; SQL 25: ya no hay vueltas) ----------
  async function leerMisDatos() {
    const [p, e, c] = await Promise.all([
      sb.from('posiciones').select('id, grupo_id, nivel_id, posicion, estado, origen').eq('user_id', miId),
      sb.from('lista_espera').select('nivel_id, creado_en').eq('user_id', miId),
      // Historial de niveles completados (un nivel puede aparecer varias veces si se repitió)
      sb.from('ciclos_completados').select('nivel_id, completado_en').eq('user_id', miId)
    ]);
    if (p.error) throw p.error;
    if (e.error) throw e.error;
    if (c.error) throw c.error;
    return { posiciones: p.data, espera: e.data, ciclos: c.data };
  }

  // "Nivel 2 (Preparar)"
  function etiquetaNivel(nivel) {
    return 'Nivel ' + nivel.orden + ' (' + nivel.nombre + ')';
  }
  function enlaceGrupo(nivelId) {
    return '#mi-grupo?nivel=' + nivelId;
  }

  // ---------- Perfil y enlace de invitación ----------
  let enlaceInvitacion = null;
  let miUsuario = null;
  const perfilListo = cargarPerfil();

  async function copiarMiEnlace() {
    await perfilListo;
    return enlaceInvitacion ? copiarTexto(enlaceInvitacion) : false;
  }

  // ---------- Secciones (#hash, con parámetros opcionales: #mi-grupo?nivel=2) ----------
  const SECCIONES = {
    'inicio': 'Inicio',
    'niveles': 'Niveles',
    'mi-grupo': 'Mi grupo',
    'chat': 'Chat',
    'notificaciones': 'Notificaciones'
  };
  // Estas secciones ahora son páginas propias (enlaces viejos #perfil, #soporte… se redirigen)
  const PAGINAS = {
    'info-personal': 'info-personal.html',
    'academia': 'academia.html',
    'perfil': 'perfil.html',
    'soporte': 'soporte.html'
  };
  const REALES = ['inicio', 'niveles', 'mi-grupo', 'notificaciones'];
  const menu = $('menu');

  function leerHash() {
    const crudo = decodeURIComponent(location.hash.slice(1));
    const [id, query] = crudo.split('?');
    return { id: SECCIONES[id] ? id : 'inicio', crudo: id, params: new URLSearchParams(query || '') };
  }

  function cargarSeccion(id, params) {
    if (id === 'inicio') cargarInicio();
    if (id === 'niveles') cargarNiveles();
    if (id === 'mi-grupo') cargarMiGrupo(params.get('nivel'));
    if (id === 'notificaciones') cargarNotificaciones();
  }

  function mostrarSeccion() {
    const { id, crudo, params } = leerHash();
    if (PAGINAS[crudo]) { location.replace(PAGINAS[crudo]); return; }
    const titulo = SECCIONES[id];
    $('titulo').textContent = titulo;
    document.title = 'Sistema Siembra tu Futuro — ' + titulo;
    menu.querySelectorAll('a[data-seccion]').forEach((a) => {
      const on = a.dataset.seccion === id;
      a.classList.toggle('on', on);
      if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    });
    REALES.forEach((s) => { $('sec-' + s).hidden = s !== id; });
    $('sec-pronto').hidden = REALES.includes(id);
    $('pronto-titulo').textContent = titulo;
    window.scrollTo(0, 0);
    if (id !== 'inicio') ponerReloj('inicio', null);
    if (id !== 'mi-grupo') ponerReloj('grupo', null);
    cargarSeccion(id, params);
  }
  window.addEventListener('hashchange', () => { $('aviso-global').hidden = true; mostrarSeccion(); });

  // Vuelve a cargar la sección actual (después de una acción o cada minuto)
  function refrescar() {
    const { id, params } = leerHash();
    cargarSeccion(id, params);
    actualizarBadge();
  }

  // ---------- Acciones ----------
  async function marcarTarea(datos) {
    const si = await confirmar({
      titulo: 'Marcar mi tarea como hecha',
      texto: '¿Ya hiciste tu tarea en redes y le avisaste al recibidor? Al marcarla como hecha se detiene el reloj de la tarea y esperas la aprobación del recibidor.',
      boton: 'Sí, ya la hice'
    });
    if (!si) return false;
    const { error } = await sb.rpc('marcar_tarea_hecha', { p_posicion_id: (datos && (datos.posicion_id || datos.id)) || null });
    if (error) throw error;
    aviso('¡Marcaste tu tarea como hecha! El recibidor la revisará y la aprobará.', 'ok');
    refrescar();
    return true;
  }

  async function aprobar(p) {
    const si = await confirmar({
      titulo: 'Aprobar tarea',
      texto: ['¿Confirmas que recibiste la tarea de ', el('b', { text: p.nombre_usuario || 'esta persona' }), ' (' + NOMBRE_POSICION[p.posicion] + ')?'],
      boton: 'Aprobar tarea'
    });
    if (!si) return;
    const { data, error } = await sb.rpc('confirmar_tarea', { p_posicion_id: p.posicion_id });
    if (error) return aviso(traducirErrorDatos(error));
    if (data && data.ascenso) {
      // Se completaron las 4 tareas: el grupo se dividió y mi casilla quedó libre
      aviso('¡Recibiste las 4 tareas y completaste el nivel ' + data.nivel + '! ' +
        (data.ultimo_nivel ? 'Era el último nivel. ¡Felicitaciones!' : 'Ya puedes participar en el siguiente nivel desde Niveles.') +
        ' Tus constructores pasaron al centro de 2 grupos nuevos.', 'ok');
    } else {
      aviso('Tarea de ' + (p.nombre_usuario || 'la persona') + ' aprobada.', 'ok');
    }
    refrescar();
  }

  async function retirarYReemplazar(p, nivelNombre) {
    const { data: candidatos, error } = await sb.rpc('candidatos_reemplazo', { p_posicion_id: p.posicion_id });
    if (error) return aviso(traducirErrorDatos(error));
    const elegido = await elegirDeLista({
      titulo: 'Retirar y reemplazar a ' + (p.nombre_usuario || 'esta persona'),
      sub: NOMBRE_POSICION[p.posicion] + ' · Nivel ' + nivelNombre + '. Elige a una persona que invitaste y que esté en lista de espera.',
      items: (candidatos || []).map((c) => ({
        titulo: c.nombre_usuario,
        sub: 'En lista de espera desde ' + formatoFecha(c.en_espera_desde),
        valor: c
      })),
      vacio: 'No tienes invitados en lista de espera para este nivel. Invita a alguien nuevo y pídele que toque Participar: si no hay lugar, quedará en lista de espera y podrás elegirlo aquí.'
    });
    if (!elegido) return;
    const si = await confirmar({
      titulo: 'Confirmar reemplazo',
      texto: ['¿Retirar a ', el('b', { text: p.nombre_usuario || 'esta persona' }), ' de ' + NOMBRE_POSICION[p.posicion] + ' y poner en su lugar a ',
        el('b', { text: elegido.nombre_usuario }), '? A ambos les llegará una notificación.'],
      boton: 'Retirar y reemplazar',
      peligro: true
    });
    if (!si) return;
    const r = await sb.rpc('retirar_y_reemplazar', { p_posicion_id: p.posicion_id, p_nuevo_user_id: elegido.user_id });
    if (r.error) return aviso(traducirErrorDatos(r.error));
    aviso(elegido.nombre_usuario + ' ocupa ahora el lugar de ' + (p.nombre_usuario || 'la persona retirada') + '.', 'ok');
    refrescar();
  }

  async function participar(nivel) {
    const primero = !nivelAnterior(nivelesCache || [nivel], nivel); // primer nivel por orden
    const si = await confirmar({
      titulo: 'Confirmar participación',
      texto: primero
        ? [
            el('p', { class: 'modal-p' }, '¿Seguro que quieres participar en este nivel? Ocuparás una posición de ', el('b', { text: 'regalador' }), ' y asumirás el compromiso de regalar tus tareas.'),
            el('div', { class: 'modal-nota', text: 'Regalar es hacer tus tareas en redes sociales. No se pide ni se recibe dinero. Esta acción se puede deshacer, pero te lo avisamos para que estés seguro.' })
          ]
        : [
            el('p', { class: 'modal-p' }, '¿Seguro que quieres participar en el nivel ', el('b', { text: nivel.nombre }), '? Entrarás al grupo de quien te invitó en este nivel, en el lugar que te corresponda.'),
            el('div', { class: 'modal-nota', text: 'Si entras como regalador tendrás que hacer tu tarea; si entras como constructor tendrás que invitar a 2 personas. No se pide ni se recibe dinero.' })
          ],
      boton: 'Sí, participar'
    });
    if (!si) return;
    const { data, error } = await sb.rpc('participar', { p_nivel_id: nivel.id });
    if (error) return aviso(traducirErrorDatos(error));
    if (data && data.resultado === 'colocado') {
      const pos = data.posicion || '';
      const siguiente = pos === 'recibidor'
        ? 'Como fundador creaste un grupo nuevo y eres su recibidor.'
        : pos.startsWith('constructor')
          ? 'Tu reloj para invitar a 2 personas ya empezó.'
          : 'Tu reloj ya empezó: haz tu tarea y márcala como hecha.';
      const derrame = data.derrame ? ' Como quien te invitó no tiene lugar en este nivel, entraste en el primer lugar libre.' : '';
      aviso('¡Listo! Ocupas el lugar de ' + (NOMBRE_POSICION[pos] || 'regalador') + ' en el nivel ' + data.nivel + '. ' + siguiente + derrame, 'ok');
      location.hash = enlaceGrupo(data.nivel_id);
    } else {
      aviso('No hay un lugar libre para ti en este momento. Quedaste en la lista de espera del nivel ' + ((data && data.nivel) || nivel.nombre) + '; el administrador te asignará un lugar.', 'info');
      refrescar();
    }
    actualizarBadge();
  }

  // ---------- Repetir un nivel con mi equipo (SQL 25) ----------
  // Se arma un grupo nuevo en ese nivel: yo al centro, mis 2 referidos como constructores y los
  // 2 referidos de cada uno como regaladores (los mismos 7 de siempre).
  async function repetirConEquipo(nivel) {
    const { data: equipo, error: errE } = await sb.rpc('mi_equipo', { p_nivel_id: nivel.id });
    if (errE) return aviso(traducirErrorDatos(errE));
    const lista = el('ul', { class: 'equipo-lista' },
      el('li', null, el('b', { text: 'Tú' }), el('span', { class: 'mut', text: ' · Recibidor (centro)' })));
    (equipo || []).forEach((s) => {
      const libre = !s.user_id ? 'falta: queda libre' : s.ocupado ? 'ya está en este nivel: queda libre' : null;
      lista.appendChild(el('li', { class: libre ? 'equipo-libre' : null },
        el('b', { text: s.nombre_usuario || 'Lugar libre' }),
        el('span', { class: 'mut', text: ' · ' + NOMBRE_POSICION[s.posicion] + (libre ? ' (' + libre + ')' : '') })));
    });
    const libres = (equipo || []).filter((s) => !s.user_id || s.ocupado).length;
    const si = await confirmar({
      titulo: 'Repetir el nivel ' + nivel.nombre + ' con tu equipo',
      texto: [
        el('p', { class: 'modal-p' }, 'Se arma otra vez tu grupo en el nivel ', el('b', { text: nivel.nombre }), ' y todos entran automáticamente:'),
        lista,
        el('div', { class: 'modal-nota', text: 'Cada regalador recibe un mensaje y empieza su plazo para hacer la tarea.' +
          (libres ? ' Los lugares libres los puede tomar la lista de espera de su patrocinador; si nadie los toma, quedan para el derrame.' : '') +
          ' No se pide ni se recibe dinero.' })
      ],
      boton: 'Sí, repetir con mi equipo'
    });
    if (!si) return;
    const { data, error } = await sb.rpc('repetir_nivel', { p_nivel_id: nivel.id });
    if (error) return aviso(traducirErrorDatos(error));
    const vac = (data.vacios || []).length;
    aviso('¡Listo! Repetiste el nivel ' + data.nivel + ': tú estás al centro y entraron ' + (data.colocados || []).length + ' de tu equipo' +
      (vac ? '. Quedaron ' + vac + ' lugares libres.' : '.'), 'ok');
    location.hash = enlaceGrupo(data.nivel_id);
    actualizarBadge();
  }

  // ---------- Reserva de referidos (SQL 23) ----------
  // mi_reserva(): si estoy en la lista de espera de mi patrocinador ("Eres el N en espera")
  // o si me quitó de sus referidos. Sin el SQL 23 devuelve null y no se muestra nada.
  async function leerMiReserva() {
    const { data, error } = await sb.rpc('mi_reserva');
    return error ? null : data;
  }

  function enEsperaOEliminado(mr) {
    return !!mr && (mr.estado === 'reserva' || mr.estado === 'eliminado');
  }

  function tarjetaReserva(mr) {
    const enEspera = mr.estado === 'reserva';
    return el('section', { class: 'card reserva-card' },
      el('span', { class: 'pill pill-amarilla', text: enEspera ? 'Pendiente de posición' : 'Sin lugar con tu patrocinador' }),
      el('h3', { text: enEspera ? 'Eres el ' + mr.numero + ' en espera' : 'Ya no eres referido activo' }),
      el('p', { class: 'mut', text: enEspera
        ? 'Estás en la lista de espera de ' + mr.patrocinador + '. Cuando se libere uno de sus 2 lugares, ' + mr.patrocinador + ' elige quién lo toma; si no elige en ' + (mr.plazo_elegir || '24 h') + ', entra automáticamente el 1.º en espera. Tu patrocinador también puede ubicarte en derrame o debajo de alguien de su red. Al entrar empieza tu plazo de ' + mr.plazo_tarea + ' para hacer tu tarea.'
        : mr.patrocinador + ' te quitó de sus 2 referidos. Puedes seguir participando: entra en el primer lugar libre.' }),
      enEspera ? el('p', { class: 'mut', text: 'Si no quieres esperar, entra ahora en el primer lugar libre del primer nivel:' }) : null,
      el('div', { class: 'botones' },
        el('button', { type: 'button', class: 'btn', onclick: entrarPorDerrame, text: 'Entrar por derrame' }))
    );
  }

  async function entrarPorDerrame() {
    const niveles = await leerNiveles();
    const primero = niveles[0];
    const si = await confirmar({
      titulo: 'Entrar por derrame',
      texto: [
        el('p', { class: 'modal-p' }, 'Entrarás como ', el('b', { text: 'regalador' }), ' en el primer lugar libre del nivel ', el('b', { text: primero.nombre }), ' y dejarás la lista de espera de tu patrocinador.'),
        el('div', { class: 'modal-nota', text: 'Tu plazo para hacer la tarea empieza en cuanto entres. No se pide ni se recibe dinero.' })
      ],
      boton: 'Sí, entrar por derrame'
    });
    if (!si) return;
    const { data, error } = await sb.rpc('participar', { p_nivel_id: primero.id });
    if (error) return aviso(traducirErrorDatos(error));
    if (data && data.resultado === 'colocado') {
      aviso('¡Listo! Entraste como ' + (NOMBRE_POSICION[data.posicion] || 'regalador') + ' en el nivel ' + data.nivel + '. Tu reloj ya empezó: haz tu tarea y márcala como hecha.', 'ok');
      location.hash = enlaceGrupo(data.nivel_id);
    } else {
      aviso('No hay ningún lugar libre en este momento. Quedaste en la lista de espera del nivel ' + ((data && data.nivel) || primero.nombre) + '.', 'info');
      refrescar();
    }
    actualizarBadge();
  }

  async function eliminarReferido(a) {
    const si = await confirmar({
      titulo: 'Eliminar referido',
      texto: [
        el('p', { class: 'modal-p' }, '¿Quieres quitar a ', el('b', { text: a.nombre_usuario }), ' de tus referidos?'),
        el('div', { class: 'modal-nota', text: 'Se libera su lugar y eliges quién de tu lista de espera lo toma (si no eliges en 24 horas, entra el 1.º en espera). ' + a.nombre_usuario + ' podrá seguir participando por derrame.' })
      ],
      boton: 'Sí, eliminar'
    });
    if (!si) return;
    const { error } = await sb.rpc('eliminar_referido', { p_user_id: a.user_id });
    if (error) return aviso(traducirErrorDatos(error));
    aviso(a.nombre_usuario + ' ya no es tu referido. Si tienes gente en espera, elige quién toma su lugar.', 'ok');
    refrescar();
    actualizarReferidos();
  }

  // Tarjeta "Mis referidos": los 2 activos (con Eliminar), los lugares libres y la lista de espera en orden
  function tarjetaReferidos(v) {
    const lista = el('ul', { class: 'ref-lista' });
    v.activos.forEach((a) => {
      const pos = a.posicion ? (NOMBRE_POSICION[a.posicion.posicion] || a.posicion.posicion) + ' · ' + a.posicion.nivel : 'Sin posición todavía';
      lista.appendChild(el('li', { class: 'ref-item' },
        el('div', { class: 'ref-quien' },
          el('b', { text: a.nombre_usuario }),
          el('span', { class: 'mut', text: pos })),
        // Solo se puede eliminar a quien todavía es regalador o no tiene posición
        a.posicion && !String(a.posicion.posicion).startsWith('regalador')
          ? el('span', { class: 'pill pill-gris', text: 'Ya avanzó' })
          : el('button', { type: 'button', class: 'bt-salir btn-chico', onclick: () => eliminarReferido(a), text: 'Eliminar' })
      ));
    });
    // (24) Lugares libres: si hay gente en espera, eliges quién lo toma (si no, entra el 1.º)
    const lugares = v.lugares || [];
    for (let i = v.activos.length, j = 0; i < 2; i++, j++) {
      const lugar = v.espera.length ? lugares[j] : null;
      lista.appendChild(el('li', { class: 'ref-item ref-libre' + (lugar ? ' ref-elegir' : '') },
        el('span', { class: 'mut', text: lugar
          ? 'Lugar libre: elige quién de tu lista de espera lo toma (hasta el ' + fechaHora(lugar.vence_en) + '). Si no eliges, entra automáticamente el 1.º en espera.'
          : 'Lugar libre: invita a alguien con tu enlace' })));
    }
    const espera = el('ol', { class: 'ref-espera' });
    v.espera.forEach((e) => espera.appendChild(el('li', null,
      el('div', null,
        el('b', { text: e.nombre_usuario }),
        el('span', { class: 'mut', text: ' · registrado el ' + formatoFecha(e.registrado) })),
      el('div', { class: 'ref-botones' },
        lugares.length
          ? el('button', { type: 'button', class: 'btn btn-chico', onclick: () => elegirParaLugar(e, lugares[0]), text: 'Elegir para este lugar' })
          : null,
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => ubicarEnDerrame(e), text: 'Ubicar en derrame' }),
        el('button', { type: 'button', class: 'bo btn-chico', onclick: () => ubicarDebajoDe(e), text: 'Ubicar debajo de…' })
      ))));
    return el('section', { class: 'card ref-card' },
      el('h3', { text: 'Mis referidos' }),
      lista,
      el('h4', { class: 'ref-sub', text: 'En espera' + (v.espera.length ? ' (' + v.espera.length + ')' : '') }),
      v.espera.length ? espera : el('p', { class: 'mut', text: 'Nadie en espera.' }),
      el('p', { class: 'ayuda ref-nota', text: 'Si eliminas a un referido, eliges quién de tu lista de espera toma su lugar; si no eliges en 24 horas, entra automáticamente el 1ro en espera. Nunca se saca a nadie: solo se usan lugares libres.' })
    );
  }

  function fechaHora(iso) {
    return new Date(iso).toLocaleString('es', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  }

  async function elegirParaLugar(e, lugar) {
    const si = await confirmar({
      titulo: 'Elegir para este lugar',
      texto: [el('p', { class: 'modal-p' }, el('b', { text: e.nombre_usuario }), ' tomará tu lugar libre y empezará su plazo para hacer la tarea.')],
      boton: 'Sí, elegir'
    });
    if (!si) return;
    const { error } = await sb.rpc('elegir_para_lugar', { p_lugar_id: lugar.id, p_user_id: e.user_id });
    if (error) return aviso(traducirErrorDatos(error));
    aviso(e.nombre_usuario + ' tomó tu lugar libre.', 'ok');
    refrescar();
    actualizarReferidos();
  }

  async function ubicarEnDerrame(e) {
    const si = await confirmar({
      titulo: 'Ubicar en derrame',
      texto: [
        el('p', { class: 'modal-p' }, el('b', { text: e.nombre_usuario }), ' entrará en el primer lugar libre del primer nivel y saldrá de tu lista de espera.'),
        el('div', { class: 'modal-nota', text: 'Ya no te seguirá a ti. Su plazo para hacer la tarea empieza en cuanto entre.' })
      ],
      boton: 'Sí, ubicar en derrame'
    });
    if (!si) return;
    const { data, error } = await sb.rpc('ubicar_en_derrame', { p_user_id: e.user_id });
    if (error) return aviso(traducirErrorDatos(error));
    aviso(data && data.resultado === 'colocado'
      ? e.nombre_usuario + ' entró en el nivel ' + data.nivel + ' como ' + (NOMBRE_POSICION[data.posicion] || 'regalador') + '.'
      : 'No hay lugares libres en este momento: ' + e.nombre_usuario + ' quedó en la lista de espera del nivel.', data && data.resultado === 'colocado' ? 'ok' : 'info');
    refrescar();
    actualizarReferidos();
  }

  async function ubicarDebajoDe(e) {
    const { data: candidatos, error: errC } = await sb.rpc('candidatos_ubicar');
    if (errC) return aviso(traducirErrorDatos(errC));
    const elegido = await elegirDeLista({
      titulo: 'Ubicar a ' + e.nombre_usuario + ' debajo de…',
      sub: 'Solo personas de tu red (tus referidos y los de ellos) con un lugar de referido libre. ' + e.nombre_usuario + ' pasará a ser su referido y lo seguirá.',
      items: (candidatos || []).map((c) => ({
        titulo: c.nombre_usuario,
        sub: (c.nivel_red === 1 ? 'Tu referido' : 'Referido de ' + c.via) + ' · ' + c.libres + (c.libres === 1 ? ' lugar libre' : ' lugares libres'),
        valor: c
      })),
      vacio: 'Nadie de tu red tiene un lugar de referido libre en este momento.'
    });
    if (!elegido) return;
    const si = await confirmar({
      titulo: 'Ubicar debajo de ' + elegido.nombre_usuario,
      texto: [el('p', { class: 'modal-p' }, el('b', { text: e.nombre_usuario }), ' pasará a ser referido de ', el('b', { text: elegido.nombre_usuario }), ' y lo seguirá.')],
      boton: 'Sí, ubicar'
    });
    if (!si) return;
    const { error } = await sb.rpc('ubicar_debajo_de', { p_user_id: e.user_id, p_destino: elegido.user_id });
    if (error) return aviso(traducirErrorDatos(error));
    aviso(e.nombre_usuario + ' ahora es referido de ' + elegido.nombre_usuario + '.', 'ok');
    refrescar();
    actualizarReferidos();
  }

  async function cargarReferidosYReserva() {
    const [rDet, mr] = await Promise.all([sb.rpc('mis_referidos_detalle'), leerMiReserva()]);
    const cr = $('inicio-reserva');
    vaciar(cr);
    if (enEsperaOEliminado(mr)) cr.appendChild(tarjetaReserva(mr));
    const cf = $('inicio-referidos');
    vaciar(cf);
    if (rDet.error || !rDet.data || !Array.isArray(rDet.data.activos)) return; // sin el SQL 25
    cf.appendChild(tarjetaReferidos(rDet.data));
  }

  // ---------- Tarjeta del recibidor: aprobación de tareas ----------
  function estadoAprobacion(p) {
    if (!p.user_id) return ['Posición libre', 'pill-gris'];
    if (p.estado === 'tarea_hecha') return ['Tarea hecha · pendiente de aprobar', 'pill-amarilla'];
    if (p.estado === 'confirmada') return ['Aprobada', 'pill-verde'];
    if (p.estado === 'plazo_vencido') return ['Plazo vencido', 'pill-roja'];
    return ['Sin tarea', 'pill-gris'];
  }

  // WhatsApp de los regaladores ocupados de un grupo (solo lo entrega whatsapp_de() al recibidor de ESE grupo)
  async function whatsappsRegaladores(posiciones) {
    const regs = posiciones.filter((p) => REGALADORES.includes(p.posicion) && p.user_id);
    const pares = await Promise.all(regs.map(async (p) => {
      const { data } = await sb.rpc('whatsapp_de', { p_user_id: p.user_id });
      return [p.user_id, data || null];
    }));
    return Object.fromEntries(pares);
  }

  function botonWhatsAppRegalador(p, whatsapps) {
    const numero = whatsapps && whatsapps[p.user_id];
    if (!numero) {
      return el('button', { type: 'button', class: 'bt-amarillo btn-chico', disabled: true, text: 'Sin WhatsApp' });
    }
    const mensaje = 'Hola, soy ' + (miUsuario || 'el recibidor') + ' de Siembra tu Futuro, el recibidor de tu grupo. ' +
      'Ayúdame con tus datos (el enlace de tu red social) para completar tu tarea.';
    return el('a', {
      class: 'bt-amarillo btn-chico', target: '_blank', rel: 'noopener',
      href: enlaceWhatsApp(numero, mensaje),
      'aria-label': 'Escribir por WhatsApp a ' + (p.nombre_usuario || 'este regalador'),
      text: 'Escribir por WhatsApp'
    });
  }

  // whatsapps: { user_id: numero|null } de los regaladores (ver whatsappsRegaladores)
  function tarjetaAprobacion(posiciones, nivel, op, whatsapps) {
    const regs = REGALADORES.map((k) => posiciones.find((p) => p.posicion === k) || { posicion: k });
    const aprobadas = regs.filter((p) => p.user_id && p.estado === 'confirmada').length;
    const pendientes = regs.filter((p) => p.user_id && p.estado === 'tarea_hecha').length;

    const lista = el('ul', { class: 'aprob-lista' });
    regs.forEach((p) => {
      const [txt, cls] = estadoAprobacion(p);
      lista.appendChild(el('li', { class: 'aprob-item' },
        el('div', { class: 'aprob-quien' },
          el('span', { class: 'aprob-rol', text: NOMBRE_POSICION[p.posicion] }),
          el('b', { text: p.user_id ? (p.nombre_usuario || '—') : 'Esperando...' })
        ),
        el('span', { class: 'pill ' + cls, text: txt }),
        // Casilla libre: sin botones. Ocupada: WhatsApp a la izquierda de "Aprobar tarea".
        p.user_id
          ? el('div', { class: 'aprob-botones' },
              botonWhatsAppRegalador(p, whatsapps),
              p.estado === 'tarea_hecha'
                ? el('button', { type: 'button', class: 'btn btn-chico', onclick: () => aprobar(p), text: 'Aprobar tarea' })
                : null)
          : null
      ));
    });

    return el('section', { class: 'card aprobacion' + (pendientes ? ' con-alerta' : '') },
      el('div', { class: 'aprob-cab' },
        el('div', null,
          el('h3', { text: 'Pendiente de aprobación de tareas recibidas' }),
          el('div', { class: 'mut', text: 'Nivel ' + nivel.nombre + ' · Tus 4 regaladores' })
        ),
        el('span', { class: 'contador', text: aprobadas + '/4 aprobadas' })
      ),
      pendientes
        ? el('div', { class: 'alerta-roja', role: 'alert', text: pendientes === 1 ? 'Tienes 1 tarea por aprobar.' : 'Tienes ' + pendientes + ' tareas por aprobar.' })
        : null,
      lista,
      op && op.enlaceGrupo ? el('a', { class: 'link', href: enlaceGrupo(nivel.id), text: 'Ver el mapa de mi grupo' }) : null
    );
  }

  const opcionesReloj = () => ({ onMarcar: marcarTarea, onCopiarEnlace: copiarMiEnlace, onVencer: refrescar });

  // =====================================================================
  // INICIO: reloj y tarjeta del recibidor
  // =====================================================================
  let turnoInicio = 0;
  async function cargarInicio() {
    const turno = ++turnoInicio;
    try {
      const [rReloj, datos, niveles] = await Promise.all([sb.rpc('mi_reloj'), leerMisDatos(), leerNiveles()]);
      if (rReloj.error) throw rReloj.error;
      const mias = datos.posiciones;

      const recibidor = mias.filter((p) => p.posicion === 'recibidor');
      const grupos = await Promise.all(recibidor.map(async (p) => {
        const { data, error } = await sb.rpc('posiciones_de_grupo', { p_grupo_id: p.grupo_id });
        if (error) throw error;
        return { nivel: nivelPorId(niveles, p.nivel_id), posiciones: data, whatsapps: await whatsappsRegaladores(data) };
      }));
      if (recibidor.length) await perfilListo; // mi usuario va en el mensaje de WhatsApp
      if (turno !== turnoInicio) return;

      const cr = $('inicio-reloj');
      vaciar(cr);
      if (rReloj.data) {
        const r = crearReloj(rReloj.data, opcionesReloj());
        ponerReloj('inicio', r);
        cr.appendChild(r.nodo);
      } else {
        ponerReloj('inicio', null); // sin reloj activo: no se muestra la tarjeta
      }

      const ca = $('inicio-recibidor');
      vaciar(ca);
      grupos.forEach((g) => ca.appendChild(tarjetaAprobacion(g.posiciones, g.nivel, { enlaceGrupo: true }, g.whatsapps)));

      // Mis niveles activos (una posición por nivel): "Nivel 2 (Preparar)"
      const cn = $('inicio-niveles');
      vaciar(cn);
      if (mias.length > 1 || (mias.length && datos.espera.length)) {
        const filas = mias.map((p) => ({ nivel: nivelPorId(niveles, p.nivel_id), p }))
          .concat(datos.espera.map((e) => ({ nivel: nivelPorId(niveles, e.nivel_id), espera: true })))
          .sort((a, b) => a.nivel.orden - b.nivel.orden);
        const lista = el('ul', { class: 'mis-niveles' });
        filas.forEach((f) => {
          lista.appendChild(el('li', { class: 'mis-niveles-item' },
            el('span', { class: 'nivel-punto', style: 'background:' + colorNivel(f.nivel), 'aria-hidden': 'true' }),
            el('div', { class: 'mis-niveles-texto' },
              el('b', { text: etiquetaNivel(f.nivel) }),
              el('span', { class: 'mut', text: f.espera ? 'En lista de espera' : NOMBRE_POSICION[f.p.posicion] })
            ),
            f.espera ? null : el('a', { class: 'bo btn-chico', href: enlaceGrupo(f.p.nivel_id), text: 'Ver grupo' })
          ));
        });
        cn.appendChild(el('section', { class: 'card' },
          el('h3', { text: 'Mis niveles' }),
          el('div', { class: 'mut', text: 'Tienes una posición activa por nivel. Desde Niveles puedes repetir niveles inferiores con tu equipo.' }),
          lista));
      }
      // Reserva de referidos: "Eres el N en espera" y "Mis referidos"
      cargarReferidosYReserva().catch(() => {});
    } catch (err) {
      if (turno !== turnoInicio) return;
      const cr = $('inicio-reloj');
      vaciar(cr);
      cr.appendChild(cajaError('No se pudo cargar tu reloj. ' + traducirErrorDatos(err)));
    }
  }

  // =====================================================================
  // NIVELES
  // =====================================================================
  function avisoSinGrupo(espera, niveles, ciclos) {
    if (ciclos && ciclos.length && !espera.length) {
      const ultimo = ciclos.map((c) => nivelPorId(niveles, c.nivel_id)).sort((a, b) => b.orden - a.orden)[0];
      const sig = nivelSiguiente(niveles, ultimo);
      return el('section', { class: 'card aviso-vacio' },
        el('h3', { text: '¡Completaste el nivel ' + ultimo.nombre + '!' }),
        el('p', { class: 'mut', text: sig
          ? 'Ya puedes participar en el nivel ' + sig.nombre + '. Ve a Niveles y toca "Participar".'
          : 'Era el último nivel. ¡Felicitaciones!' })
      );
    }
    if (espera.length) {
      const n = nivelPorId(niveles, espera[0].nivel_id);
      return el('section', { class: 'card aviso-vacio' },
        el('h3', { text: 'Estás en la lista de espera' }),
        el('p', { class: 'mut', text: 'Nivel ' + n.nombre + ', desde el ' + formatoFecha(espera[0].creado_en) + '. Cuando se libere un lugar, el administrador te asignará uno y te llegará una notificación.' })
      );
    }
    return el('section', { class: 'card aviso-vacio' },
      el('h3', { text: 'Todavía no tienes un grupo asignado' }),
      el('p', { class: 'mut', text: 'Toca "Participar" en el nivel habilitado para unirte al grupo de quien te invitó.' })
    );
  }

  let turnoNiveles = 0;
  async function cargarNiveles() {
    const turno = ++turnoNiveles;
    const lista = $('niveles-lista');
    const cajaAviso = $('niveles-aviso');
    try {
      const [niveles, datos, mr, rRep] = await Promise.all([leerNiveles(), leerMisDatos(), leerMiReserva(), sb.rpc('niveles_para_repetir')]);
      if (turno !== turnoNiveles) return;
      // (25) Niveles inferiores al más alto que alcancé, sin posición mía: "Repetir con mi equipo"
      const repetibles = new Set((rRep.data && rRep.data.niveles) || []);
      const esperaRepetir = rRep.data && rRep.data.espera_hasta;
      const mias = datos.posiciones;
      const espera = datos.espera;
      const ciclos = datos.ciclos;
      const porDerrame = enEsperaOEliminado(mr); // (23) en espera: el primer nivel se entra por derrame

      vaciar(cajaAviso);
      if (porDerrame) {
        cajaAviso.hidden = false;
        cajaAviso.appendChild(tarjetaReserva(mr));
      } else {
        cajaAviso.hidden = mias.length > 0;
        if (!mias.length) cajaAviso.appendChild(avisoSinGrupo(espera, niveles, ciclos));
      }

      const completados = new Set(ciclos.map((c) => c.nivel_id));
      // Habilitado: el primer nivel o el siguiente a uno completado (igual que nivel_habilitado())
      const habilitado = (n) => {
        const ant = nivelAnterior(niveles, n);
        return !ant || completados.has(ant.id);
      };

      vaciar(lista);
      niveles.forEach((n) => {
        const botones = [];
        const aqui = mias.find((p) => p.nivel_id === n.id);
        const esperaAqui = espera.some((e) => e.nivel_id === n.id);
        const vecesHecho = ciclos.filter((c) => c.nivel_id === n.id).length;

        if (aqui) {
          botones.push(el('a', { class: 'btn btn-nivel', href: enlaceGrupo(n.id), text: 'Ver mi grupo' }));
        } else if (esperaAqui) {
          botones.push(el('button', { type: 'button', class: 'btn-bloqueado', disabled: true, text: '⏳ En lista de espera' }));
        } else if (repetibles.has(n.id)) {
          botones.push(esperaRepetir
            ? el('button', { type: 'button', class: 'btn-bloqueado', disabled: true, text: '⏳ Repetir desde el ' + fechaHora(esperaRepetir) })
            : el('button', { type: 'button', class: 'btn btn-nivel', onclick: () => repetirConEquipo(n), text: 'Repetir con mi equipo' }));
        } else if (!completados.has(n.id) && habilitado(n)) {
          botones.push(porDerrame && !nivelAnterior(niveles, n)
            ? el('button', { type: 'button', class: 'btn btn-nivel', onclick: entrarPorDerrame, text: 'Entrar por derrame' })
            : el('button', { type: 'button', class: 'btn btn-nivel', onclick: () => participar(n), text: 'Participar' }));
        }

        const activo = botones.length > 0 || vecesHecho > 0;
        const textoHecho = '✅ Completado' + (vecesHecho > 1 ? ' (' + vecesHecho + ' veces)' : '');
        const soloHecho = !botones.length && vecesHecho > 0;
        if (!botones.length) {
          botones.push(el('button', { type: 'button', class: 'btn-bloqueado', disabled: true,
            text: soloHecho ? textoHecho : '🔒 Bloqueado' }));
        }
        lista.appendChild(el('div', { class: 'card nivel' + (activo ? ' activo' : ' bloqueado') },
          el('div', { class: 'nivel-circulo', style: 'background:' + colorNivel(n), 'aria-hidden': 'true', text: n.nombre.charAt(0) }),
          el('div', { class: 'nivel-nombre', text: n.nombre }),
          el('div', { class: 'mut', text: 'Meta: ' + formatoNumero(n.meta_tareas) + ' tareas' }),
          vecesHecho && !soloHecho ? el('div', { class: 'nivel-hecho', text: textoHecho }) : null,
          el('div', { class: 'nivel-botones' }, ...botones)
        ));
      });
    } catch (err) {
      if (turno !== turnoNiveles) return;
      vaciar(lista);
      lista.appendChild(cajaError('No se pudieron cargar los niveles. ' + traducirErrorDatos(err)));
    }
  }

  // =====================================================================
  // MI GRUPO
  // =====================================================================
  function avisoRegalador(recibidor, whatsapp) {
    const caja = el('div', { class: 'aviso-wa' });
    if (!recibidor || !recibidor.user_id) {
      caja.append('Tu grupo todavía no tiene recibidor. Cuando se asigne, aquí verás su contacto para coordinar tu tarea.');
      return caja;
    }
    caja.append(
      'Como ', el('b', { text: 'regalador' }), ', contacta al recibidor (', el('b', { text: recibidor.nombre_usuario }), ')',
      whatsapp ? ' al ' : ' ',
      whatsapp ? el('b', { text: whatsapp }) : '',
      whatsapp ? ' ' : '',
      'lo antes posible para coordinar tu tarea. El recibidor te confirmará cuando reciba tu tarea. Sin comunicación en 4 horas podrías ser eliminado del nivel.'
    );
    if (!whatsapp) {
      caja.appendChild(el('div', { class: 'mut', style: 'margin-top:8px', text: 'El número del recibidor no está disponible. Pide ayuda en Soporte.' }));
    }
    return caja;
  }

  // Posiciones puestas por el administrador (sin relojes)
  function tarjetaTareaSinReloj(yo) {
    if (yo.estado === 'reservada') {
      const msg = el('div', { class: 'msg error', role: 'alert', hidden: true });
      const btn = el('button', { type: 'button', class: 'btn', text: 'Marcar mi tarea como hecha' });
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        msg.hidden = true;
        try {
          if ((await marcarTarea({ posicion_id: yo.posicion_id })) === false) btn.disabled = false;
        } catch (err) {
          msg.textContent = traducirErrorDatos(err);
          msg.hidden = false;
          btn.disabled = false;
        }
      });
      return el('section', { class: 'card tarea-simple' },
        el('h3', { text: 'Tu tarea' }),
        el('p', { class: 'mut', text: 'Haz tu tarea en redes, avísale al recibidor por WhatsApp y márcala como hecha.' }),
        el('div', { class: 'botones' }, btn), msg
      );
    }
    if (yo.estado === 'tarea_hecha') {
      return el('section', { class: 'card tarea-simple' }, el('h3', { text: 'Tu tarea' }),
        el('p', { class: 'mut', text: 'Marcaste tu tarea como hecha. Falta que el recibidor la apruebe.' }));
    }
    if (yo.estado === 'confirmada') {
      return el('section', { class: 'card tarea-simple' }, el('h3', { text: 'Tu tarea' }),
        el('p', { class: 'mut', text: 'El recibidor aprobó tu tarea. ¡Gracias por ayudar!' }));
    }
    return null;
  }

  let turnoGrupo = 0;
  async function cargarMiGrupo(nivelPedido) {
    const turno = ++turnoGrupo;
    const cont = $('grupo-contenido');
    try {
      const [niveles, datos] = await Promise.all([leerNiveles(), leerMisDatos()]);
      if (turno !== turnoGrupo) return;
      const mias = datos.posiciones.slice();

      if (!mias.length) {
        ponerReloj('grupo', null);
        vaciar(cont);
        cont.appendChild(avisoSinGrupo(datos.espera, niveles, datos.ciclos));
        return;
      }

      mias.sort((a, b) => nivelPorId(niveles, a.nivel_id).orden - nivelPorId(niveles, b.nivel_id).orden);
      // Grupo a mostrar: el del nivel pedido o, si no, el del nivel más alto
      const mia = mias.find((p) => String(p.nivel_id) === String(nivelPedido)) || mias[mias.length - 1];
      const nivel = nivelPorId(niveles, mia.nivel_id);

      const [rGrupo, rPos, rReloj] = await Promise.all([
        sb.from('grupos').select('id, estado, tipo').eq('id', mia.grupo_id).maybeSingle(),
        sb.rpc('posiciones_de_grupo', { p_grupo_id: mia.grupo_id }),
        mia.posicion === 'recibidor' ? Promise.resolve({ data: null }) : sb.rpc('mi_reloj', { p_nivel_id: mia.nivel_id })
      ]);
      if (rGrupo.error) throw rGrupo.error;
      if (rPos.error) throw rPos.error;
      if (rReloj.error) throw rReloj.error;
      const posiciones = rPos.data;
      const yo = posiciones.find((p) => p.user_id === miId) || { posicion: mia.posicion, estado: mia.estado };

      // WhatsApp del recibidor (si no soy el recibidor) o de mis regaladores (si soy el recibidor)
      const recibidor = posiciones.find((p) => p.posicion === 'recibidor');
      let whatsappRecibidor = null;
      let whatsappsRegs = null;
      if (mia.posicion === 'recibidor') {
        [whatsappsRegs] = await Promise.all([whatsappsRegaladores(posiciones), perfilListo]);
      } else if (recibidor && recibidor.user_id) {
        const { data } = await sb.rpc('whatsapp_de', { p_user_id: recibidor.user_id });
        whatsappRecibidor = data || null;
      }
      if (turno !== turnoGrupo) return;

      vaciar(cont);
      ponerReloj('grupo', null);

      // Selector si está en más de un nivel
      if (mias.length > 1) {
        const chips = el('div', { class: 'chips', role: 'navigation', 'aria-label': 'Mis niveles' });
        mias.forEach((p) => {
          chips.appendChild(el('a', {
            class: 'chip' + (p === mia ? ' on' : ''),
            href: enlaceGrupo(p.nivel_id),
            'aria-current': p === mia ? 'page' : null,
            text: etiquetaNivel(nivelPorId(niveles, p.nivel_id))
          }));
        });
        cont.appendChild(chips);
      }

      const estado = rGrupo.data && rGrupo.data.estado === 'completado' ? 'completado' : 'activo';
      const repetido = rGrupo.data && rGrupo.data.tipo === 'repetido';
      cont.appendChild(el('section', { class: 'card grupo-cabecera' },
        el('div', null,
          el('div', { class: 'grupo-titulo', text: 'Grupo · ' + etiquetaNivel(nivel) }),
          repetido
            ? el('div', { class: 'grupo-repetido', text: 'Grupo repetido: el equipo de ' + ((recibidor && recibidor.nombre_usuario) || 'su recibidor') + ' vuelve a jugar este nivel.' })
            : null,
          el('div', { class: 'mut', text: 'El recibidor está al centro, los constructores a los lados y los regaladores en las puntas.' })
        ),
        el('span', { class: 'estado-chip ' + estado, text: 'Estado: ' + estado })
      ));

      // Mapa: casillas en plazo vencido con "Retirar y reemplazar" para quien invitó a esa persona
      cont.appendChild(crearMapaGrupo(posiciones, {
        miId,
        acciones: (p) => (p.user_id && p.estado === 'plazo_vencido' && p.es_mi_invitado)
          ? el('div', { class: 'cas-acciones' },
              el('button', { type: 'button', class: 'cb cb-asignar', onclick: () => retirarYReemplazar(p, nivel.nombre), text: 'Retirar y reemplazar' }))
          : null
      }));

      if (mia.posicion === 'recibidor') {
        cont.appendChild(tarjetaAprobacion(posiciones, nivel, null, whatsappsRegs));
      } else {
        if (esRegalador(mia.posicion)) {
          cont.appendChild(avisoRegalador(recibidor, whatsappRecibidor));
        }
        if (rReloj.data) {
          const r = crearReloj(rReloj.data, opcionesReloj());
          ponerReloj('grupo', r);
          cont.appendChild(r.nodo);
        } else {
          const t = tarjetaTareaSinReloj(yo);
          if (t) cont.appendChild(t);
        }
      }
    } catch (err) {
      if (turno !== turnoGrupo) return;
      ponerReloj('grupo', null);
      vaciar(cont);
      cont.appendChild(cajaError('No se pudo cargar tu grupo. ' + traducirErrorDatos(err)));
    }
  }

  // =====================================================================
  // NOTIFICACIONES
  // =====================================================================
  async function actualizarBadge() {
    const { count, error } = await sb.from('notificaciones')
      .select('id', { count: 'exact', head: true })
      .eq('leida', false);
    if (error) return;
    const n = count || 0;
    ['badge-notif', 'badge-menu'].forEach((id) => {
      const b = $(id);
      b.textContent = n > 99 ? '99+' : String(n);
      b.hidden = n === 0;
    });
    $('badge-notif').setAttribute('aria-label', n + ' sin leer');
  }

  function pintarResumen(sinLeer) {
    $('notif-resumen').textContent = sinLeer === 0 ? 'Todo al día' : (sinLeer === 1 ? '1 sin leer' : sinLeer + ' sin leer');
    $('btn-leer-todas').disabled = sinLeer === 0;
  }

  let turnoNotif = 0;
  async function cargarNotificaciones() {
    const turno = ++turnoNotif;
    const lista = $('notif-lista');
    try {
      const { data, error } = await sb.from('notificaciones')
        .select('id, titulo, mensaje, leida, creada_en')
        .order('creada_en', { ascending: false })
        .limit(100);
      if (error) throw error;
      if (turno !== turnoNotif) return;

      let sinLeer = data.filter((n) => !n.leida).length;
      pintarResumen(sinLeer);
      vaciar(lista);

      if (!data.length) {
        lista.appendChild(el('section', { class: 'card aviso-vacio' },
          el('h3', { text: 'No tienes notificaciones' }),
          el('p', { class: 'mut', text: 'Aquí te avisaremos de tu grupo, tus tareas y tus plazos.' })
        ));
        return;
      }

      const caja = el('div', { class: 'card notif-card' });
      data.forEach((n) => {
        const pill = n.leida ? null : el('span', { class: 'pill pill-amarilla pill-nuevo', text: 'Nuevo' });
        const item = el('div', { class: 'notif' + (n.leida ? '' : ' nueva'), tabindex: n.leida ? null : '0', role: n.leida ? null : 'button', title: n.leida ? null : 'Marcar como leída' },
          el('div', { class: 'notif-icono', 'aria-hidden': 'true', text: '!' }),
          el('div', { class: 'notif-cuerpo' },
            el('div', { class: 'notif-titulo' }, n.titulo, pill ? ' ' : null, pill),
            el('div', { class: 'mut', text: n.mensaje }),
            el('div', { class: 'notif-fecha', text: tiempoRelativo(n.creada_en) })
          )
        );
        if (!n.leida) {
          const marcar = async () => {
            if (n.leida) return;
            n.leida = true;
            const { error: e } = await sb.from('notificaciones').update({ leida: true }).eq('id', n.id);
            if (e) { n.leida = false; return aviso(traducirErrorDatos(e)); }
            item.classList.remove('nueva');
            item.removeAttribute('role');
            item.removeAttribute('tabindex');
            item.removeAttribute('title');
            if (pill) pill.remove();
            sinLeer = Math.max(0, sinLeer - 1);
            pintarResumen(sinLeer);
            actualizarBadge();
          };
          item.addEventListener('click', marcar);
          item.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); marcar(); } });
        }
        caja.appendChild(item);
      });
      lista.appendChild(caja);
    } catch (err) {
      if (turno !== turnoNotif) return;
      vaciar(lista);
      lista.appendChild(cajaError('No se pudieron cargar tus notificaciones. ' + traducirErrorDatos(err)));
    }
  }

  $('btn-leer-todas').addEventListener('click', async () => {
    const btn = $('btn-leer-todas');
    btn.disabled = true;
    const { error } = await sb.from('notificaciones').update({ leida: true }).eq('user_id', miId).eq('leida', false);
    if (error) { btn.disabled = false; return aviso(traducirErrorDatos(error)); }
    cargarNotificaciones();
    actualizarBadge();
  });

  // ---------- Arranque y actualización periódica ----------
  mostrarSeccion();
  actualizarBadge();

  function refrescoPeriodico() {
    if (document.visibilityState !== 'visible' || document.querySelector('dialog[open]')) return;
    actualizarBadge();
    const { id, params } = leerHash();
    if (id === 'inicio' || id === 'mi-grupo') cargarSeccion(id, params);
    if (id === 'inicio') actualizarReferidos();
  }
  setInterval(refrescoPeriodico, 60000);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') refrescoPeriodico(); });

  // =====================================================================
  // PERFIL (tarjeta "Enlace de invitación")
  // =====================================================================
  // "Referidos: X de 2" junto al enlace (máximo 2 referidos activos por patrocinador)
  async function actualizarReferidos() {
    const [{ data, error }, r23] = await Promise.all([sb.rpc('mis_referidos'), sb.rpc('mi_reserva')]);
    if (error || typeof data !== 'number') return; // sin el SQL 10 no se muestra
    const conReserva = !r23.error; // el enlace ya no se bloquea: los demás quedan en espera
    const n = Math.min(data, 2);
    const caja = $('referidos');
    vaciar(caja);
    const circ = el('span', { class: 'circulos', 'aria-hidden': 'true' },
      el('span', { class: 'circulo' + (n >= 1 ? ' lleno' : '') }),
      el('span', { class: 'circulo' + (n >= 2 ? ' lleno' : '') }));
    // Quien tenía más de 2 activos antes del cambio (vueltas) los conserva todos
    caja.append(el('span', { text: (conReserva ? 'Referidos activos' : 'Referidos') + ': ' + (data > 2 ? data : data + ' de 2') }), circ);
    caja.hidden = false;
    const avisoLleno = $('referidos-aviso');
    avisoLleno.textContent = 'Tu link está inhabilitado porque ya tienes 2 referidos';
    avisoLleno.hidden = conReserva || data < 2;
  }

  async function cargarPerfil() {
    const { data: perfil, error } = await sb
      .from('perfiles')
      .select('nombre_usuario, codigo_invitacion, creado_en')
      .eq('id', miId)
      .maybeSingle();

    if (error || !perfil) {
      const m = $('panel-msg');
      m.textContent = error
        ? 'No se pudo cargar tu perfil. Revisa tu conexión y recarga la página. (' + error.message + ')'
        : 'No se encontró tu perfil. Avisa al administrador.';
      m.hidden = false;
      $('enlace').textContent = '—';
      return;
    }

    const usuario = perfil.nombre_usuario;
    miUsuario = usuario;
    $('bienvenida').textContent = '¡Bienvenido de nuevo, ' + usuario + '!';
    $('avatar').textContent = usuario.charAt(0).toUpperCase();
    if (perfil.creado_en) {
      const fecha = new Date(perfil.creado_en).toLocaleDateString('es', { day: 'numeric', month: 'long', year: 'numeric' });
      $('miembro-desde').textContent = 'Miembro desde el ' + fecha;
    }

    // Enlace real: index.html?ref=CODIGO sobre la URL actual del sitio
    const url = new URL('index.html', location.href);
    url.search = '?ref=' + encodeURIComponent(perfil.codigo_invitacion);
    url.hash = '';
    enlaceInvitacion = url.toString();

    $('enlace').textContent = enlaceInvitacion;
    $('codigo').textContent = perfil.codigo_invitacion;
    actualizarReferidos();

    const btnWa = $('btn-wa');
    btnWa.href = 'https://wa.me/?text=' + encodeURIComponent('¡Únete a Siembra tu Futuro con mi enlace de invitación! ' + enlaceInvitacion);
    btnWa.hidden = false;

    const btnCopiar = $('btn-copiar');
    const copiado = $('copiado');
    btnCopiar.disabled = false;
    let temporizador;
    btnCopiar.addEventListener('click', async () => {
      const ok = await copiarTexto(enlaceInvitacion);
      copiado.className = 'msg ' + (ok ? 'ok' : 'error');
      copiado.textContent = ok ? '¡Enlace copiado!' : 'No se pudo copiar. Mantén presionado el enlace para copiarlo.';
      copiado.hidden = false;
      clearTimeout(temporizador);
      temporizador = setTimeout(() => { copiado.hidden = true; }, 3000);
    });
  }
})();
