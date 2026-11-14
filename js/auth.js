// Inicio de sesión y registro (index.html)
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const RE_CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  let sb = crearClienteSupabase();

  // Si ya hay sesión, ir directo al panel
  sb.auth.getSession().then(({ data }) => {
    if (data && data.session) location.replace('panel.html');
  });

  // ---------- Mensajes ----------
  function mostrarMsg(el, texto, tipo) {
    el.textContent = texto;
    el.className = 'msg ' + (tipo || 'error');
    el.hidden = false;
  }
  function ocultarMsg(el) { el.hidden = true; el.textContent = ''; }

  function cargando(boton, activo, textoCargando) {
    if (activo) {
      boton.dataset.texto = boton.textContent;
      boton.textContent = textoCargando;
      boton.disabled = true;
    } else {
      boton.textContent = boton.dataset.texto || boton.textContent;
      boton.disabled = false;
    }
  }

  function traducirError(error) {
    if (!error) return 'Ocurrió un error inesperado. Inténtalo de nuevo.';
    const msg = String(error.message || '');
    const code = String(error.code || '');
    if (code === 'invalid_credentials' || /invalid login credentials/i.test(msg))
      return 'Correo o contraseña incorrectos.';
    if (code === 'user_already_exists' || code === 'email_exists' || /already registered|already exists/i.test(msg))
      return 'Ese correo ya está registrado. Inicia sesión o usa otro correo.';
    if (code === 'weak_password' || /password should|password is too/i.test(msg))
      return 'La contraseña es muy débil. Usa al menos 8 caracteres.';
    if (code === 'email_address_invalid' || /invalid format|email address .* is invalid/i.test(msg))
      return 'El correo no es válido. Revísalo e inténtalo de nuevo.';
    if (code === 'email_not_confirmed' || /email not confirmed/i.test(msg))
      return 'Tu correo todavía no está confirmado.';
    if (/rate limit|too many/i.test(msg) || /rate_limit/.test(code))
      return 'Demasiados intentos. Espera unos minutos y vuelve a intentarlo.';
    if (/database error saving new user/i.test(msg))
      return 'No se pudo crear tu perfil. Es posible que ese nombre de usuario ya esté en uso; prueba con otro.';
    if (code === 'PGRST202' || code === '42883' || /could not find the function/i.test(msg))
      return 'El sistema todavía no está configurado (falta ejecutar el SQL en Supabase). Avisa al administrador.';
    if (/failed to fetch|networkerror|network request failed|load failed/i.test(msg))
      return 'No hay conexión con el servidor. Revisa tu internet e inténtalo de nuevo.';
    return 'Ocurrió un error: ' + msg;
  }

  // ---------- Pestañas ----------
  const forms = { login: $('form-login'), registro: $('form-registro') };
  const tabs = { login: $('tab-login'), registro: $('tab-registro') };

  // Registro bloqueado ({ titulo, texto }): se muestra el aviso en lugar del formulario
  let bloqueo = null;

  function mostrarTab(nombre) {
    Object.keys(forms).forEach((k) => {
      const activo = k === nombre;
      forms[k].hidden = !activo || (k === 'registro' && !!bloqueo);
      tabs[k].setAttribute('aria-selected', activo ? 'true' : 'false');
    });
    $('reg-bloqueado').hidden = !(nombre === 'registro' && bloqueo);
    // El registro usa dos columnas: tarjeta un poco más ancha
    document.querySelector('.acceso-card').classList.toggle('ancha', nombre === 'registro');
  }
  Object.values(tabs).forEach((t) => t.addEventListener('click', () => mostrarTab(t.dataset.tab)));
  document.querySelectorAll('[data-ir]').forEach((a) =>
    a.addEventListener('click', (e) => { e.preventDefault(); mostrarTab(a.dataset.ir); })
  );

  // ---------- Redes y soporte ----------
  // El WhatsApp de soporte se configura en Administración → Configuración → Enlaces de soporte
  // (tabla enlaces_soporte). Sin sesión se lee con rpc('whatsapp_soporte'). Si no está
  // activo, no se muestran sus botones.
  if (REDES.instagram) { $('red-instagram').href = REDES.instagram; $('red-instagram').hidden = false; }
  if (REDES.tiktok) { $('red-tiktok').href = REDES.tiktok; $('red-tiktok').hidden = false; }

  const olvide = $('olvide');
  const redWa = $('red-whatsapp');
  olvide.hidden = true;
  redWa.hidden = true;
  let soporteWa = null;
  function actualizarOlvide() {
    const id = $('login-id').value.trim();
    let texto = 'Hola, olvidé mi contraseña de Siembra tu Futuro y necesito ayuda para recuperarla.';
    if (id) texto += ' Mi correo es: ' + id;
    olvide.href = enlaceWhatsApp(soporteWa, texto);
  }
  sb.rpc('whatsapp_soporte').then(({ data, error }) => {
    if (error || !data) return;
    soporteWa = data;
    redWa.href = enlaceWhatsApp(soporteWa, 'Hola, quiero información sobre Siembra tu Futuro.');
    redWa.hidden = false;
    actualizarOlvide();
    olvide.hidden = false;
    $('login-id').addEventListener('input', actualizarOlvide);
    olvide.addEventListener('click', actualizarOlvide);
  });

  // ---------- Cuenta eliminada (viene de "Salir y eliminar mi cuenta") ----------
  const params = new URLSearchParams(location.search);
  if (params.get('cuenta') === 'eliminada') {
    mostrarMsg($('login-msg'), 'Tu cuenta fue eliminada.', 'ok');
  }

  // ---------- Código de invitación (?ref=) y registro solo con link ----------
  const refURL = (params.get('ref') || '').trim().toUpperCase();
  let refValido = null;
  let exigeLink = true; // lo confirma registro_exige_link(); la base aplica la regla igual
  const regInvito = $('reg-invito');

  const SIN_LINK = {
    titulo: 'Necesitas un link de invitación',
    texto: 'Para registrarte necesitas el link de invitación de alguien de la comunidad.'
  };
  const LINK_LLENO = {
    titulo: 'Este link no tiene cupo',
    texto: 'Tu patrocinador ya tiene sus 2 referidos y no puede recibir más por ahora. Por favor contáctate con la persona que te invitó.'
  };

  function bloquearRegistro(motivo) {
    bloqueo = motivo;
    $('reg-bloq-titulo').textContent = motivo.titulo;
    $('reg-bloq-msg').textContent = motivo.texto;
    if (!forms.registro.hidden || refURL) mostrarTab('registro');
  }

  function codigoInvalido() {
    if (exigeLink) return bloquearRegistro(SIN_LINK);
    regInvito.textContent = 'El código de invitación del enlace no es válido. Puedes registrarte igual o pedir un enlace nuevo.';
    regInvito.hidden = false;
  }

  if (refURL) mostrarTab('registro');

  (async function revisarRegistro() {
    const rExige = await sb.rpc('registro_exige_link');
    // Si la función no existe todavía (falta el SQL 12) se asume que no se exige
    exigeLink = rExige.error ? false : rExige.data !== false;

    if (!refURL) {
      if (exigeLink) bloquearRegistro(SIN_LINK);
      return;
    }
    if (!/^[A-Z0-9]{8}$/.test(refURL)) return codigoInvalido();

    const [{ data, error }, cupo] = await Promise.all([
      sb.rpc('usuario_por_codigo', { p_codigo: refURL }),
      sb.rpc('referido_disponible', { p_codigo: refURL })
    ]);
    if (error || !data) return codigoInvalido();
    // Máximo 2 referidos activos por patrocinador (si falta el SQL 10, la base decide)
    if (!cupo.error && cupo.data === false) return bloquearRegistro(LINK_LLENO);

    refValido = refURL;
    regInvito.textContent = 'Te invitó: ';
    const b = document.createElement('b');
    b.textContent = data;
    regInvito.appendChild(b);
    regInvito.hidden = false;
  })();

  // ---------- Iniciar sesión ----------
  forms.login.addEventListener('submit', async (e) => {
    e.preventDefault();
    const msg = $('login-msg');
    const boton = $('login-btn');
    ocultarMsg(msg);

    const email = $('login-id').value.trim();
    const pass = $('login-pass').value;
    if (!email || !pass) return mostrarMsg(msg, 'Escribe tu correo y tu contraseña.');
    if (!RE_CORREO.test(email)) return mostrarMsg(msg, 'El correo no es válido. Revísalo e inténtalo de nuevo.');

    // Recordarme: decide dónde se guarda la sesión
    guardarRecordar($('login-recordar').checked);
    sb = crearClienteSupabase();

    cargando(boton, true, 'Entrando…');
    try {
      const { error } = await sb.auth.signInWithPassword({ email, password: pass });
      if (error) throw error;
      location.replace('panel.html');
    } catch (err) {
      mostrarMsg(msg, traducirError(err));
    } finally {
      cargando(boton, false);
    }
  });

  // ---------- Registro: validación por campo ----------
  // WhatsApp: normalizarWhatsApp() y errorWhatsApp() están en js/config.js (misma regla que el SQL).
  // El registro no tiene selector de país: se asume Ecuador salvo que empiece con + o 00.
  const PAIS_REGISTRO = 'Ecuador';
  const ayudaWa = $('ayuda-reg-whatsapp');
  const AYUDA_WA = 'Ecuador: 0999999999. Otros países: + y código de país.';
  function vistaPreviaWhatsApp() {
    const n = normalizarWhatsApp($('reg-whatsapp').value, PAIS_REGISTRO);
    ayudaWa.textContent = n ? 'Se guardará como ' + n : AYUDA_WA;
  }
  $('reg-whatsapp').addEventListener('input', vistaPreviaWhatsApp);

  const VALIDADORES = {
    'reg-nombre': (el) => {
      const v = el.value.trim().replace(/\s+/g, ' ');
      if (!v) return 'Escribe tu nombre completo.';
      if (v.length < 3) return 'El nombre es muy corto.';
      if (!/\p{L}/u.test(v)) return 'El nombre debe contener letras.';
      return '';
    },
    'reg-usuario': (el) => {
      const v = el.value.trim().toLowerCase();
      if (!v) return 'Elige un nombre de usuario.';
      if (!/^[a-z0-9_]{3,20}$/.test(v))
        return 'De 3 a 20 caracteres: letras minúsculas, números o guion bajo (_), sin espacios ni tildes.';
      return '';
    },
    'reg-correo': (el) => {
      const v = el.value.trim();
      if (!v) return 'Escribe tu correo.';
      if (!RE_CORREO.test(v)) return 'El correo no es válido.';
      return '';
    },
    'reg-whatsapp': (el) => errorWhatsApp(el.value, PAIS_REGISTRO),
    'reg-pass': (el) => {
      if (!el.value) return 'Escribe una contraseña.';
      if (el.value.length < 8) return 'Debe tener al menos 8 caracteres.';
      return '';
    },
    'reg-pass2': (el) => {
      if (!el.value) return 'Repite la contraseña.';
      if (el.value !== $('reg-pass').value) return 'Las contraseñas no coinciden.';
      return '';
    },
    'reg-acepta-wa': (el) => (el.checked ? '' : 'Debes aceptar para poder coordinar con tu grupo.'),
    'reg-terminos': (el) => (el.checked ? '' : 'Debes aceptar las reglas y políticas.')
  };

  let intentoEnviar = false;

  function ponerError(id, texto) {
    const el = $(id);
    $('err-' + id).textContent = texto;
    if (el.type === 'checkbox') {
      const lbl = el.closest('.check');
      if (texto) lbl.setAttribute('data-invalido', ''); else lbl.removeAttribute('data-invalido');
    }
    if (texto) el.setAttribute('aria-invalid', 'true'); else el.removeAttribute('aria-invalid');
  }

  function validarCampo(id) {
    const texto = VALIDADORES[id]($(id));
    ponerError(id, texto);
    return !texto;
  }

  function validarTodo() {
    let primeroMal = null;
    Object.keys(VALIDADORES).forEach((id) => {
      if (!validarCampo(id) && !primeroMal) primeroMal = $(id);
    });
    if (primeroMal) primeroMal.focus();
    return !primeroMal;
  }

  // Revalida al salir del campo y, tras el primer intento, también al escribir
  Object.keys(VALIDADORES).forEach((id) => {
    const el = $(id);
    const evento = el.type === 'checkbox' ? 'change' : 'input';
    el.addEventListener('blur', () => {
      if (intentoEnviar || (el.type !== 'checkbox' && el.value)) validarCampo(id);
    });
    el.addEventListener(evento, () => {
      if (intentoEnviar || el.getAttribute('aria-invalid')) validarCampo(id);
      if (id === 'reg-pass' && $('reg-pass2').value) validarCampo('reg-pass2');
    });
  });

  // ---------- Registro: envío ----------
  forms.registro.addEventListener('submit', async (e) => {
    e.preventDefault();
    const msg = $('reg-msg');
    const boton = $('reg-btn');
    ocultarMsg(msg);
    intentoEnviar = true;

    if (!validarTodo()) {
      return mostrarMsg(msg, 'Revisa los campos marcados en rojo.');
    }

    const nombreCompleto = $('reg-nombre').value.trim().replace(/\s+/g, ' ');
    const usuario = $('reg-usuario').value.trim().toLowerCase();
    const correo = $('reg-correo').value.trim();
    // Se envía ya normalizado (+593…); la base vuelve a normalizar con normalizar_whatsapp()
    const whatsapp = normalizarWhatsApp($('reg-whatsapp').value, PAIS_REGISTRO);
    const pass = $('reg-pass').value;

    guardarRecordar(true);
    sb = crearClienteSupabase();

    cargando(boton, true, 'Creando cuenta…');
    try {
      const disp = await sb.rpc('usuario_disponible', { p_usuario: usuario });
      if (disp.error) throw disp.error;
      if (disp.data === false) {
        ponerError('reg-usuario', 'Ese nombre de usuario ya está en uso. Prueba con otro.');
        $('reg-usuario').focus();
        return mostrarMsg(msg, 'Revisa los campos marcados en rojo.');
      }

      const { data, error } = await sb.auth.signUp({
        email: correo,
        password: pass,
        options: {
          data: {
            nombre_usuario: usuario,
            nombre_completo: nombreCompleto,
            whatsapp: whatsapp,
            acepta_whatsapp_visible: $('reg-acepta-wa').checked,
            codigo_ref: refValido
          }
        }
      });
      if (error) throw error;

      if (data && data.session) {
        location.replace('panel.html');
      } else {
        // Solo pasaría si la confirmación de correo se activara en Supabase
        mostrarMsg(msg, 'Cuenta creada. Revisa tu correo para confirmarla y luego inicia sesión.', 'ok');
      }
    } catch (err) {
      // Supabase no deja pasar el texto del trigger ("Database error saving new user"):
      // se vuelve a preguntar si el link tiene cupo o si ahora se exige link.
      if (/database error saving new user/i.test(String(err && err.message))) {
        if (refValido) {
          const cupo = await sb.rpc('referido_disponible', { p_codigo: refValido });
          if (!cupo.error && cupo.data === false) return bloquearRegistro(LINK_LLENO);
        } else {
          const ex = await sb.rpc('registro_exige_link');
          if (!ex.error && ex.data !== false) return bloquearRegistro(SIN_LINK);
        }
      }
      mostrarMsg(msg, traducirError(err));
    } finally {
      cargando(boton, false);
    }
  });
})();
