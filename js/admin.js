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
  const TABS = ['usuarios', 'grupos', 'espera', 'config'];
  const CARGAR = { usuarios: cargarUsuarios, grupos: cargarGrupos, espera: cargarEspera, config: cargarConfig };
  function mostrarTab(nombre) {
    TABS.forEach((k) => {
      $('tab-' + k).setAttribute('aria-selected', k === nombre ? 'true' : 'false');
      $('pan-' + k).hidden = k !== nombre;
    });
    ocultarAviso();
    CARGAR[nombre]();
  }
  TABS.forEach((k) => $('tab-' + k).addEventListener('click', () => mostrarTab(k)));

  // ---------- Datos comunes ----------
  async function cargarPerfiles() {
    const { data, error } = await sb
      .from('perfiles')
      .select('id, nombre_usuario, nombre_completo, whatsapp, codigo_invitacion, invitado_por, es_fundador, creado_en')
      .order('creado_en', { ascending: false });
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

  async function cargarUsuarios() {
    try {
      await Promise.all([cargarPerfiles(), cargarCorreos()]);
      pintarUsuarios();
    } catch (err) {
      const tb = $('tabla-usuarios');
      vaciar(tb);
      tb.appendChild(el('tr', null, el('td', { colspan: '9', class: 'msg error', text: 'No se pudieron cargar los usuarios. ' + traducirErrorDatos(err) })));
    }
  }

  function pintarUsuarios() {
    const q = normalizar($('buscar-usuarios').value.trim());
    const visibles = perfiles.filter((p) => !q ||
      [p.nombre_usuario, p.nombre_completo, correoPorId[p.id], p.whatsapp, p.codigo_invitacion, nombreDe(p.invitado_por)]
        .some((v) => normalizar(v).includes(q))
    );
    const tb = $('tabla-usuarios');
    vaciar(tb);
    if (!visibles.length) {
      tb.appendChild(el('tr', null, el('td', { colspan: '9', class: 'mut', text: perfiles.length ? 'Ningún usuario coincide con la búsqueda.' : 'Todavía no hay usuarios registrados.' })));
    }
    visibles.forEach((p) => {
      tb.appendChild(el('tr', null,
        el('td', null, el('b', { text: p.nombre_usuario })),
        el('td', { text: p.nombre_completo || '—' }),
        el('td', { text: correoPorId[p.id] || '—' }),
        el('td', null, p.whatsapp
          ? el('a', { class: 'link', href: enlaceWhatsApp(p.whatsapp, 'Hola ' + p.nombre_usuario + ', te escribo de Siembra tu Futuro.'), target: '_blank', rel: 'noopener', text: p.whatsapp })
          : '—'),
        el('td', { class: 'mono', text: p.codigo_invitacion }),
        el('td', { text: nombreDe(p.invitado_por) || (p.invitado_por ? '(eliminado)' : '—') }),
        el('td', { text: formatoFecha(p.creado_en) }),
        el('td', null, p.es_fundador
          ? el('div', { class: 'celda-fundador' },
              el('span', { class: 'pill pill-verde', text: 'Fundador' }),
              el('button', { type: 'button', class: 'cb cb-quitar', onclick: () => cambiarFundador(p, false), text: 'Quitar' }))
          : el('button', { type: 'button', class: 'cb', onclick: () => cambiarFundador(p, true), text: 'Marcar como fundador' })),
        el('td', null, el('div', { class: 'celda-fundador' },
          el('button', { type: 'button', class: 'cb', onclick: () => cambiarClave(p), text: 'Cambiar clave' }),
          el('button', { type: 'button', class: 'cb cb-quitar', onclick: () => eliminarCuenta(p), text: 'Eliminar cuenta' })))
      ));
    });
    $('cuenta-usuarios').textContent = q
      ? visibles.length + ' de ' + perfiles.length + ' usuarios'
      : perfiles.length + (perfiles.length === 1 ? ' usuario' : ' usuarios');
  }
  $('buscar-usuarios').addEventListener('input', pintarUsuarios);

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
    if (ok) { cargarUsuarios(); actualizarBadgeEspera(); }
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
    if (ok) cargarUsuarios();
  }

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
