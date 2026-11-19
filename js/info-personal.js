// Info personal (info-personal.html): mis datos, cambiar contraseña y salir de la plataforma.
// Usa js/comun.js y js/pagina.js. Los datos se guardan con rpc('actualizar_mi_perfil'):
// la tabla perfiles NO se abre para escribir.
(async function () {
  'use strict';

  const sb = crearClienteSupabase();
  const session = await iniciarPagina(sb);
  if (!session) return;

  // Países (Ecuador por defecto). El WhatsApp se valida con normalizarWhatsApp() de js/config.js:
  // en Ecuador acepta 0999999999; en otros países, + y código de país.
  const PAISES = [
    "Ecuador", "Argentina", "Bolivia", "Brasil", "Chile", "Colombia", "Costa Rica", "Cuba", "El Salvador",
    "España", "Estados Unidos", "Guatemala", "Honduras", "Italia", "México", "Nicaragua", "Panamá",
    "Paraguay", "Perú", "Puerto Rico", "República Dominicana", "Uruguay", "Venezuela", "Otro"
  ];

  const selPais = $('ip-pais');
  PAISES.forEach((nombre) => selPais.appendChild(el('option', { value: nombre, text: nombre })));

  const msgInfo = $('info-form-msg');
  // Datos de acceso (correo actual y, si pidió cambiarlo, el correo nuevo pendiente de confirmar)
  let usuarioAuth = session.user;

  // ---------- Cargar datos ----------
  let perfil = null;
  async function cargar() {
    const [rp, rr] = await Promise.all([
      sb.from('perfiles')
        .select('nombre_usuario, nombre_completo, whatsapp, pais, acepta_whatsapp_visible, creado_en')
        .eq('id', session.user.id).maybeSingle(),
      sb.rpc('mi_resumen_perfil')
    ]);
    if (rp.error || !rp.data) {
      mostrarAviso(msgInfo, 'No se pudieron cargar tus datos. ' + (rp.error ? traducirErrorDatos(rp.error) : 'No se encontró tu perfil.'));
      return;
    }
    perfil = rp.data;
    pintarCabecera(rr.error ? null : rr.data);
    pintarFormulario();
  }

  function pintarCabecera(resumen) {
    $('ip-avatar').textContent = perfil.nombre_usuario.charAt(0).toUpperCase();
    $('ip-usuario').textContent = perfil.nombre_usuario;
    $('ip-desde').textContent = 'Miembro desde el ' + formatoFecha(perfil.creado_en);
    const chips = $('ip-chips');
    vaciar(chips);
    const actual = resumen && resumen.nivel_actual;
    const nivelActual = actual && (resumen.niveles || []).find((n) => n.nivel_id === actual.id);
    chips.append(
      el('span', { class: 'chip', text: 'Nivel: ' + (actual ? actual.nombre : '—') }),
      el('span', { class: 'chip', text: 'Posición: ' + (nivelActual && nivelActual.posicion ? NOMBRE_POSICION[nivelActual.posicion] : 'sin posición') })
    );
    $('ip-verificado').hidden = !session.user.email_confirmed_at;
  }

  function pintarFormulario() {
    $('ip-nombre').value = perfil.nombre_completo || '';
    $('ip-usuario-in').value = perfil.nombre_usuario;
    $('ip-correo').value = usuarioAuth.email || '';
    $('ayuda-ip-correo').textContent = usuarioAuth.new_email
      ? 'Pendiente de confirmar: ' + usuarioAuth.new_email + '. Abre el enlace que te enviamos por correo.'
      : '';
    $('ip-acepta').checked = !!perfil.acepta_whatsapp_visible;

    const pais = perfil.pais || 'Ecuador';
    if (!PAISES.includes(pais)) {
      selPais.insertBefore(el('option', { value: pais, text: pais }), selPais.lastChild);
    }
    selPais.value = pais;
    $('ip-wa').value = perfil.whatsapp || '';
    vistaPreviaWa();
  }

  // ---------- Modo lectura / "Editar mis datos" ----------
  const EDITABLES = ['ip-nombre', 'ip-wa', 'ip-correo'];
  let editando = false;
  function modoEdicion(on) {
    editando = on;
    EDITABLES.forEach((id) => { $(id).readOnly = !on; });
    selPais.disabled = !on;
    $('ip-acepta').disabled = !on;
    $('form-info').classList.toggle('editando', on);
    $('btn-editar').hidden = on;
    $('btn-cancelar').hidden = !on;
    $('btn-info').hidden = !on;
    if (!on) ['ip-nombre', 'ip-wa', 'ip-correo'].forEach((id) => error(id, ''));
  }
  $('btn-editar').addEventListener('click', () => {
    msgInfo.hidden = true;
    modoEdicion(true);
    $('ip-nombre').focus();
  });
  $('btn-cancelar').addEventListener('click', () => {
    msgInfo.hidden = true;
    pintarFormulario();
    modoEdicion(false);
  });

  // "Se guardará como +593991234567" mientras escribe (misma regla que la base de datos)
  const AYUDA_WA = 'Ecuador: 0999999999. Otros países: + y código de país.';
  function vistaPreviaWa() {
    const n = normalizarWhatsApp($('ip-wa').value, selPais.value);
    $('ayuda-ip-wa').textContent = n ? 'Se guardará como ' + n : AYUDA_WA;
    if ($('err-ip-wa').textContent) error('ip-wa', errorWhatsApp($('ip-wa').value, selPais.value));
  }
  $('ip-wa').addEventListener('input', vistaPreviaWa);
  selPais.addEventListener('change', vistaPreviaWa);

  // ---------- Guardar datos ----------
  function error(id, texto) {
    $('err-' + id).textContent = texto;
    const campo = $(id);
    if (texto) campo.setAttribute('aria-invalid', 'true'); else campo.removeAttribute('aria-invalid');
    return !texto;
  }

  $('form-info').addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!editando) return;
    msgInfo.hidden = true;
    const nombre = $('ip-nombre').value.trim().replace(/\s+/g, ' ');
    // Se envía ya normalizado (+593…); la base vuelve a normalizar con normalizar_whatsapp()
    const whatsapp = normalizarWhatsApp($('ip-wa').value, selPais.value);
    const pais = selPais.value === 'Otro' ? null : selPais.value;
    const correo = $('ip-correo').value.trim().toLowerCase();

    // Misma validación que el registro
    const okNombre = error('ip-nombre',
      !nombre ? 'Escribe tu nombre y apellido.'
        : nombre.length < 3 ? 'El nombre es muy corto.'
          : !/\p{L}/u.test(nombre) ? 'El nombre debe contener letras.' : '');
    const okWa = error('ip-wa', errorWhatsApp($('ip-wa').value, selPais.value));
    const okCorreo = error('ip-correo', !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo) ? 'Escribe un correo válido.' : '');
    if (!okNombre || !okWa || !okCorreo) return mostrarAviso(msgInfo, 'Revisa los campos marcados en rojo.');

    // Qué cambió (con el valor anterior, para confirmar)
    const cambios = [];
    if (nombre !== (perfil.nombre_completo || '')) cambios.push(['Nombre y apellido', perfil.nombre_completo, nombre]);
    if (whatsapp !== (perfil.whatsapp || '')) cambios.push(['WhatsApp', perfil.whatsapp, whatsapp]);
    if ((pais || 'Otro') !== (perfil.pais || 'Ecuador')) cambios.push(['País', perfil.pais, pais || 'Otro']);
    if ($('ip-acepta').checked !== !!perfil.acepta_whatsapp_visible) {
      cambios.push(['WhatsApp visible para tu recibidor', perfil.acepta_whatsapp_visible ? 'Sí' : 'No', $('ip-acepta').checked ? 'Sí' : 'No']);
    }
    const cambiaPerfil = cambios.length > 0;
    const cambiaCorreo = correo !== String(usuarioAuth.email || '').toLowerCase();
    if (cambiaCorreo) cambios.push(['Correo', usuarioAuth.email, correo]);
    if (!cambios.length) return mostrarAviso(msgInfo, 'No cambiaste ningún dato.');

    const si = await confirmar({
      titulo: 'Guardar mis datos',
      texto: [el('ul', { class: 'equipo-lista' }, ...cambios.map(([q, antes, ahora]) => el('li', null,
        el('b', { text: q + ': ' }), (antes || '—') + ' → ' + (ahora || '—'))))].concat(cambiaCorreo
        ? [el('div', { class: 'modal-nota', text: 'Para cambiar tu correo te enviaremos un enlace de confirmación. Hasta que lo abras seguirás entrando con tu correo actual.' })]
        : []),
      boton: 'Guardar cambios'
    });
    if (!si) return;

    const btn = $('btn-info');
    btn.disabled = true;
    try {
      if (cambiaPerfil) {
        const { data, error: err } = await sb.rpc('actualizar_mi_perfil', {
          p_nombre: nombre, p_whatsapp: whatsapp, p_pais: pais, p_acepta_whatsapp: $('ip-acepta').checked
        });
        if (err) throw err;
        perfil = Object.assign(perfil, data);
      }
      let textoCorreo = '';
      if (cambiaCorreo) {
        const r = await sb.auth.updateUser({ email: correo }, { emailRedirectTo: new URL('info-personal.html', location.href).href });
        if (r.error) {
          const t = String(r.error.message || '');
          throw new Error(/already|registered|exists/i.test(t) ? 'Ese correo ya lo usa otra cuenta.'
            : /rate|too many|seconds/i.test(t) ? 'Pediste el cambio hace muy poco. Espera unos minutos e inténtalo de nuevo.'
              : /invalid/i.test(t) ? 'Escribe un correo válido.' : t);
        }
        if (r.data && r.data.user) usuarioAuth = r.data.user;
        textoCorreo = String(usuarioAuth.email || '').toLowerCase() === correo
          ? ' Tu correo ya es ' + correo + '.'
          : ' Te enviamos un correo a ' + correo + ' para confirmar el cambio: abre el enlace y listo.';
      }
      pintarFormulario();
      modoEdicion(false);
      mostrarAviso(msgInfo, (cambiaPerfil ? 'Tus datos se actualizaron.' : 'Listo.') + textoCorreo, 'ok');
    } catch (err) {
      mostrarAviso(msgInfo, err && err.code ? traducirErrorDatos(err) : String((err && err.message) || err));
    } finally {
      btn.disabled = false;
    }
  });

  // ---------- Cambiar contraseña ----------
  $('form-pass').addEventListener('submit', async (e) => {
    e.preventDefault();
    const m = $('pass-msg');
    m.hidden = true;
    const actual = $('ip-pass-actual').value;
    const nueva = $('ip-pass-nueva').value;
    const conf = $('ip-pass-conf').value;
    if (!actual) return mostrarAviso(m, 'Escribe tu contraseña actual.');
    if (nueva.length < 8) return mostrarAviso(m, 'La nueva contraseña debe tener al menos 8 caracteres.');
    if (nueva !== conf) return mostrarAviso(m, 'Las contraseñas nuevas no coinciden.');
    if (nueva === actual) return mostrarAviso(m, 'La nueva contraseña debe ser distinta de la actual.');

    const btn = $('btn-pass');
    btn.disabled = true;
    try {
      // Verifica la contraseña actual antes de cambiarla
      const v = await sb.auth.signInWithPassword({ email: session.user.email, password: actual });
      if (v.error) throw Object.assign(new Error('actual'), { actual: true });
      const u = await sb.auth.updateUser({ password: nueva });
      if (u.error) throw u.error;
      $('form-pass').reset();
      mostrarAviso(m, 'Tu contraseña se actualizó.', 'ok');
    } catch (err) {
      const t = String((err && err.message) || '');
      mostrarAviso(m, err && err.actual ? 'La contraseña actual no es correcta.'
        : /same|different/i.test(t) ? 'La nueva contraseña debe ser distinta de la actual.'
          : /weak|short|at least/i.test(t) ? 'La contraseña es muy débil. Usa al menos 8 caracteres.'
            : traducirErrorDatos(err));
    } finally {
      btn.disabled = false;
    }
  });

  // ---------- Salir de la plataforma (borra la cuenta) ----------
  $('btn-salir-red').addEventListener('click', async () => {
    const m = $('salir-msg');
    m.hidden = true;
    const campo = el('input', { class: 'in', id: 'confirmar-eliminar', type: 'text', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false' });
    const pregunta = confirmar({
      titulo: 'Salir y eliminar mi cuenta',
      texto: [el('p', { class: 'modal-p', text: 'Vas a salir de Siembra tu Futuro. Tus posiciones quedarán libres, tu patrocinador recibirá un aviso y tu cuenta se borrará. Esta acción no se puede deshacer.' })],
      extra: el('label', { class: 'lb', for: 'confirmar-eliminar' }, 'Para confirmar, escribe ELIMINAR', campo),
      boton: 'Salir y eliminar mi cuenta',
      peligro: true
    });
    const ok = $('dlg-confirmar-ok');
    ok.disabled = true;
    campo.addEventListener('input', () => { ok.disabled = campo.value.trim().toUpperCase() !== 'ELIMINAR'; });
    campo.focus();
    const si = await pregunta;
    ok.disabled = false;
    if (!si || campo.value.trim().toUpperCase() !== 'ELIMINAR') return;

    const btn = $('btn-salir-red');
    btn.disabled = true;
    const { error: err } = await sb.rpc('salir_de_la_red');
    if (err) {
      btn.disabled = false;
      return mostrarAviso(m, traducirErrorDatos(err));
    }
    window.saliendoCuenta = true;
    try { await sb.auth.signOut({ scope: 'local' }); } catch (x) { /* la cuenta ya no existe */ }
    location.replace('index.html?cuenta=eliminada');
  });

  // Correo vigente y cambio pendiente (por ejemplo, al volver desde el enlace de confirmación)
  try {
    const { data } = await sb.auth.getUser();
    if (data && data.user) usuarioAuth = data.user;
  } catch (e) { /* se usa la sesión guardada */ }
  await cargar();
  modoEdicion(false);
})();
