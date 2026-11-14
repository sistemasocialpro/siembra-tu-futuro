// Arranque común de las páginas con menú lateral fuera de panel.html
// (perfil.html, info-personal.html, academia.html, soporte.html). Usa js/comun.js
//
// iniciarPagina(sb) -> Promise<session|null>: exige sesión, menú, cerrar sesión, enlace de
// administración (solo admins), badge de notificaciones e inicial del avatar.

async function iniciarPagina(sb) {
  const session = await exigirSesion(sb);
  if (!session) return null;
  document.body.classList.remove('cargando');

  iniciarCerrarSesion(sb);
  iniciarMenuLateral();

  sb.rpc('es_admin').then(({ data }) => { if (data === true && $('link-admin')) $('link-admin').hidden = false; });

  sb.from('perfiles').select('nombre_usuario').eq('id', session.user.id).maybeSingle()
    .then(({ data }) => { if (data && $('avatar')) $('avatar').textContent = data.nombre_usuario.charAt(0).toUpperCase(); });

  actualizarBadgeNotificaciones(sb);
  return session;
}

async function actualizarBadgeNotificaciones(sb) {
  const { count, error } = await sb.from('notificaciones')
    .select('id', { count: 'exact', head: true })
    .eq('leida', false);
  if (error) return;
  const n = count || 0;
  ['badge-notif', 'badge-menu'].forEach((id) => {
    const b = $(id);
    if (!b) return;
    b.textContent = n > 99 ? '99+' : String(n);
    b.hidden = n === 0;
  });
}

// Avisos dentro de una caja .msg
function mostrarAviso(caja, texto, tipo) {
  caja.textContent = texto;
  caja.className = 'msg ' + (tipo || 'error');
  caja.hidden = false;
}
