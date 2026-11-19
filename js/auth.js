// Inicio de sesión y registro (index.html)

// ---------- Diseño en celular (menos de 768px) ----------
// Los campos no llevan etiqueta encima: el nombre va dentro como placeholder (data-ph-movil),
// por ejemplo "Teléfono / WhatsApp *". En computadora queda el placeholder original (0999999999).
// Va PRIMERO y aparte del login: se aplica aunque falle algo después (por ejemplo, si no carga
// la librería de Supabase).
(function () {
  'use strict';
  try {
    const celular = window.matchMedia('(max-width: 767.98px)');
    const campos = document.querySelectorAll('[data-ph-movil]');
    campos.forEach((x) => { x.dataset.phPc = x.getAttribute('placeholder') || ''; });
    const aplicar = () => {
      campos.forEach((x) => {
        const ph = celular.matches ? x.dataset.phMovil : x.dataset.phPc;
        if (ph) x.setAttribute('placeholder', ph); else x.removeAttribute('placeholder');
      });
    };
    aplicar();
    if (celular.addEventListener) celular.addEventListener('change', aplicar);
    else if (celular.addListener) celular.addListener(aplicar);
  } catch (err) { /* sin matchMedia: quedan los textos originales */ }
})();

(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const RE_CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  // A dónde vuelve la persona desde el correo de "¿Olvidaste tu clave?". Esta dirección debe
  // estar en Supabase → Authentication → URL Configuration → Redirect URLs.
  const URL_RECUPERAR = 'https://sistemasocialpro.github.io/siembra-tu-futuro/';

  // ¿Viene del enlace del correo? (#access_token=…&type=recovery o #error_code=otp_expired…)
  const hashURL = new URLSearchParams(location.hash.replace(/^#/, ''));
  const vieneDeRecuperacion = hashURL.get('type') === 'recovery';
  const errorEnlace = hashURL.get('error_code') || hashURL.get('error');

  let sb = crearClienteSupabase({ leerEnlace: vieneDeRecuperacion });

  // Entra a panel.html (participante) o admin.html (administrador sin perfil)
  async function irAlInicio(session) {
    try { sessionStorage.removeItem('stf-abierta'); } catch (e) { /* sin sessionStorage */ }
    const destino = await paginaDeInicio(sb, session.user.id);
    // (33) Clave temporal del administrador: se queda aquí para crear su clave nueva
    if (String(destino).startsWith('index.html')) return abrirClaveTemporal();
    location.replace(destino || 'panel.html');
  }

  let modoTemporal = false;
  function abrirClaveTemporal() {
    modoTemporal = true;
    const form = $('form-nueva-clave');
    form.querySelector('h2').textContent = 'Crea tu clave nueva';
    form.querySelector('p').textContent = 'Entraste con una clave temporal que te dio el administrador. Para seguir, crea tu propia clave (al menos 6 caracteres) y escríbela dos veces.';
    if (!$('nueva-salir')) {
      const salir = document.createElement('button');
      salir.type = 'button';
      salir.className = 'link-boton';
      salir.id = 'nueva-salir';
      salir.textContent = 'Salir';
      salir.addEventListener('click', async () => {
        try { await sb.auth.signOut({ scope: 'local' }); } catch (e) { /* igual salimos */ }
        location.replace('index.html');
      });
      form.appendChild(salir);
    }
    abrirNuevaClave();
  }

  function limpiarEnlace() {
    if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  }

  // Si ya hay sesión, ir directo al panel (salvo que venga a crear su clave nueva)
  if (!vieneDeRecuperacion) {
    sb.auth.getSession().then(({ data }) => {
      if (data && data.session) irAlInicio(data.session);
    });
  }

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
      return 'Usuario o contraseña incorrectos.';
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

  // Vistas sin pestañas: 'olvide' (pedir el enlace) y 'nueva' (escribir la clave nueva)
  const vistas = { olvide: $('form-olvide'), nueva: $('form-nueva-clave') };
  function mostrarVista(nombre) {
    $('tabs-acceso').hidden = true;
    Object.values(forms).forEach((f) => { f.hidden = true; });
    $('reg-bloqueado').hidden = true;
    Object.keys(vistas).forEach((k) => { vistas[k].hidden = k !== nombre; });
    document.querySelector('.acceso-card').classList.remove('ancha');
  }

  function mostrarTab(nombre) {
    $('tabs-acceso').hidden = false;
    Object.values(vistas).forEach((v) => { v.hidden = true; });
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

  // Si el WhatsApp de soporte está activo, la pantalla "¿Olvidaste tu clave?" ofrece escribir
  // por WhatsApp cuando no llega el correo.
  const redWa = $('red-whatsapp');
  const olvideWa = $('olvide-wa');
  redWa.hidden = true;
  let soporteWa = null;
  function actualizarOlvideWa() {
    if (!soporteWa) return;
    const correo = $('olvide-correo').value.trim();
    let texto = 'Hola, olvidé mi clave de Siembra tu Futuro y no me llega el correo para recuperarla.';
    if (correo) texto += ' Mi correo es: ' + correo;
    olvideWa.href = enlaceWhatsApp(soporteWa, texto);
  }
  sb.rpc('whatsapp_soporte').then(({ data, error }) => {
    if (error || !data) return;
    soporteWa = data;
    redWa.href = enlaceWhatsApp(soporteWa, 'Hola, quiero información sobre Siembra tu Futuro.');
    redWa.hidden = false;
    actualizarOlvideWa();
    $('olvide-wa-fila').hidden = false;
    $('olvide-correo').addEventListener('input', actualizarOlvideWa);
    olvideWa.addEventListener('click', actualizarOlvideWa);
  });

  // ---------- ¿Olvidaste tu clave? ----------
  $('olvide').addEventListener('click', (e) => {
    e.preventDefault();
    ocultarMsg($('olvide-msg'));
    // El login pide usuario: solo se copia si lo escrito es un correo
    const correoLogin = $('login-id').value.trim();
    if (RE_CORREO.test(correoLogin) && !$('olvide-correo').value) $('olvide-correo').value = correoLogin;
    actualizarOlvideWa();
    mostrarVista('olvide');
    $('olvide-correo').focus();
  });

  vistas.olvide.addEventListener('submit', async (e) => {
    e.preventDefault();
    const msg = $('olvide-msg');
    const boton = $('olvide-btn');
    ocultarMsg(msg);
    const email = $('olvide-correo').value.trim();
    if (!email) return mostrarMsg(msg, 'Escribe tu correo.');
    if (!RE_CORREO.test(email)) return mostrarMsg(msg, 'El correo no es válido. Revísalo e inténtalo de nuevo.');

    cargando(boton, true, 'Enviando…');
    try {
      const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: URL_RECUPERAR });
      if (error) throw error;
      // Mismo mensaje exista o no la cuenta (no se revela quién está registrado)
      mostrarMsg(msg, 'Listo. Si ese correo está registrado, te enviamos un enlace para crear tu clave nueva. Revisa también la carpeta de spam o correo no deseado.', 'ok');
    } catch (err) {
      mostrarMsg(msg, traducirError(err));
    } finally {
      cargando(boton, false);
    }
  });

  // ---------- Clave nueva (vuelve desde el correo) ----------
  let pantallaNuevaLista = false;
  function abrirNuevaClave() {
    if (pantallaNuevaLista) return;
    pantallaNuevaLista = true;
    limpiarEnlace();
    mostrarVista('nueva');
    $('nueva-pass').focus();
  }

  if (errorEnlace) {
    // Enlace vencido o ya usado
    limpiarEnlace();
    mostrarVista('olvide');
    mostrarMsg($('olvide-msg'), 'El enlace para cambiar tu clave ya venció o ya fue usado. Escribe tu correo y pide uno nuevo.');
  } else if (vieneDeRecuperacion) {
    // supabase-js lee el enlace y avisa con PASSWORD_RECOVERY
    sb.auth.onAuthStateChange((evento) => {
      if (evento === 'PASSWORD_RECOVERY') abrirNuevaClave();
    });
    // Respaldo: si el evento ya pasó, basta con que exista la sesión del enlace
    sb.auth.getSession().then(({ data }) => {
      if (data && data.session) return abrirNuevaClave();
      limpiarEnlace();
      mostrarVista('olvide');
      mostrarMsg($('olvide-msg'), 'El enlace para cambiar tu clave no es válido o ya venció. Escribe tu correo y pide uno nuevo.');
    });
  }

  function errorNuevaClave(id, texto) {
    $('err-' + id).textContent = texto;
    if (texto) $(id).setAttribute('aria-invalid', 'true'); else $(id).removeAttribute('aria-invalid');
  }

  vistas.nueva.addEventListener('submit', async (e) => {
    e.preventDefault();
    const msg = $('nueva-msg');
    const boton = $('nueva-btn');
    ocultarMsg(msg);
    const p1 = $('nueva-pass').value;
    const p2 = $('nueva-pass2').value;
    errorNuevaClave('nueva-pass', !p1 ? 'Escribe tu clave nueva.' : (p1.length < 6 ? 'Debe tener al menos 6 caracteres.' : ''));
    errorNuevaClave('nueva-pass2', !p2 ? 'Repite la clave nueva.' : (p1 !== p2 ? 'Las claves no coinciden.' : ''));
    if (!p1 || p1.length < 6) { $('nueva-pass').focus(); return mostrarMsg(msg, 'Revisa los campos marcados en rojo.'); }
    if (p1 !== p2) { $('nueva-pass2').focus(); return mostrarMsg(msg, 'Revisa los campos marcados en rojo.'); }

    cargando(boton, true, 'Guardando…');
    try {
      const { data, error } = await sb.auth.updateUser({ password: p1 });
      if (error) throw error;
      // (33) Ya tiene su propia clave: deja de ser temporal (también si vino por un enlace)
      try { await sb.rpc('clave_cambiada'); } catch (e2) { /* sin el SQL 33 no pasa nada */ }
      mostrarMsg(msg, '¡Listo! Tu clave nueva quedó guardada. Entrando…', 'ok');
      boton.disabled = true;
      setTimeout(() => irAlInicio({ user: data.user }), 1500);
    } catch (err) {
      const code = String((err && err.code) || '');
      const texto = String((err && err.message) || '');
      if (code === 'same_password' || /different from the old/i.test(texto))
        mostrarMsg(msg, modoTemporal ? 'La clave nueva debe ser distinta de la clave temporal.' : 'La clave nueva debe ser distinta de la anterior.');
      else if (code === 'weak_password' || /password should|password is too/i.test(texto))
        mostrarMsg(msg, 'La clave es muy débil. Usa al menos 6 caracteres, mejor con letras y números.');
      else if (code === 'session_not_found' || /auth session missing|session/i.test(texto))
        mostrarMsg(msg, 'El enlace ya venció. Vuelve a pedir uno en "¿Olvidaste tu clave?".');
      else
        mostrarMsg(msg, traducirError(err));
      cargando(boton, false);
    }
  });
  ['nueva-pass', 'nueva-pass2'].forEach((id) => $(id).addEventListener('input', () => errorNuevaClave(id, '')));

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

    const usuario = $('login-id').value.trim();
    const pass = $('login-pass').value;
    if (!usuario || !pass) return mostrarMsg(msg, 'Escribe tu usuario y tu contraseña.');

    // Recordarme: decide dónde se guarda la sesión
    guardarRecordar($('login-recordar').checked);
    sb = crearClienteSupabase();

    cargando(boton, true, 'Entrando…');
    try {
      // Supabase entra con correo: correo_para_login (SQL 17) lo devuelve solo si la clave es
      // correcta. El correo queda en esta variable y nunca se muestra en pantalla.
      // Si se escribe un correo (cuenta de administrador, que no tiene usuario) se usa directo.
      let email = usuario;
      if (!RE_CORREO.test(usuario)) {
        const r = await sb.rpc('correo_para_login', { p_usuario: usuario.toLowerCase(), p_clave: pass });
        if (r.error) {
          if (r.error.code === 'P0001') return mostrarMsg(msg, r.error.message);
          // Falta ejecutar el SQL 17: mientras tanto se puede entrar con el correo
          if (r.error.code === 'PGRST202' || r.error.code === '42883')
            return mostrarMsg(msg, 'La entrada con usuario todavía no está activa. Por ahora escribe tu correo en lugar del usuario.');
          throw r.error;
        }
        if (!r.data) return mostrarMsg(msg, 'Usuario o contraseña incorrectos.');
        email = r.data;
      }
      const { data, error } = await sb.auth.signInWithPassword({ email, password: pass });
      if (error) throw error;
      await irAlInicio(data.session);
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
      if (v === usuarioOcupado) return 'Ese usuario ya existe. Elige otro.';
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

  // ---------- Ojo: ver / ocultar contraseña ----------
  document.querySelectorAll('[data-ojo]').forEach((b) => {
    b.addEventListener('click', () => {
      const input = $(b.dataset.ojo);
      const ver = input.type === 'password';
      input.type = ver ? 'text' : 'password';
      b.setAttribute('aria-pressed', ver ? 'true' : 'false');
      b.setAttribute('aria-label', ver ? 'Ocultar contraseña' : 'Mostrar contraseña');
    });
  });

  // ---------- Usuario: avisar al momento si ya existe ----------
  const AYUDA_USUARIO = '3 a 20: minúsculas, números o _';
  let usuarioOcupado = '';   // último usuario que la base dijo que ya existe
  let revisionUsuario = 0;
  let esperaUsuario = null;
  async function revisarUsuarioLibre() {
    const v = $('reg-usuario').value.trim().toLowerCase();
    if (VALIDADORES['reg-usuario']($('reg-usuario'))) return;
    const n = ++revisionUsuario;
    const { data, error } = await sb.rpc('usuario_disponible', { p_usuario: v });
    if (n !== revisionUsuario || error) return;
    if (data === false) {
      usuarioOcupado = v;
      ponerError('reg-usuario', 'Ese usuario ya existe. Elige otro.');
    } else {
      $('ayuda-reg-usuario').textContent = 'Usuario disponible.';
    }
  }
  $('reg-usuario').addEventListener('input', () => {
    $('ayuda-reg-usuario').textContent = AYUDA_USUARIO;
    clearTimeout(esperaUsuario);
    esperaUsuario = setTimeout(revisarUsuarioLibre, 500);
  });

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
        usuarioOcupado = usuario;
        ponerError('reg-usuario', 'Ese usuario ya existe. Elige otro.');
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
