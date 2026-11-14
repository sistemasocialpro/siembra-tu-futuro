// Soporte (soporte.html): enlaces oficiales (tabla enlaces_soporte), estado de la cuenta y
// preguntas frecuentes con los plazos reales de la configuración. Usa js/comun.js y js/pagina.js.
(async function () {
  'use strict';

  const sb = crearClienteSupabase();
  const session = await iniciarPagina(sb);
  if (!session) return;

  // ---------- Tarjetas de enlaces ----------
  const ICONOS = {
    telegram: 'M21 4L3 11l6 2 2 6 3-4 5 4 2-15zM9 13l9-6-7 8',
    linktree: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
    whatsapp: 'M4 20l1.3-4A8 8 0 1 1 8 18.7L4 20zM9 9c0 3 3 6 6 6l1.5-1.5-2-1-1 1c-1 0-2.5-1.5-2.5-2.5l1-1-1-2L9 9z',
    correo: 'M3 6h18v12H3zM3 6l9 7 9-7'
  };
  const TARJETAS = [
    { clave: 'telegram', titulo: 'Canal oficial de Telegram', texto: 'Únete a la comunidad para noticias y soporte.', href: (v) => v },
    { clave: 'linktree', titulo: 'Enlaces oficiales', texto: 'Todos los enlaces oficiales del sistema en un solo lugar.', href: (v) => v },
    { clave: 'whatsapp', titulo: 'WhatsApp de soporte', texto: 'Escríbenos si tienes una duda.',
      href: (v) => enlaceWhatsApp(v, 'Hola, tengo una duda sobre Siembra tu Futuro.') },
    { clave: 'correo', titulo: 'Correo de soporte', texto: 'Escríbenos por correo.', href: (v) => 'mailto:' + v }
  ];

  function icono(clave) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('width', '26'); svg.setAttribute('height', '26'); svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('d', ICONOS[clave]);
    p.setAttribute('fill', 'none'); p.setAttribute('stroke', 'currentColor');
    p.setAttribute('stroke-width', '2'); p.setAttribute('stroke-linecap', 'round'); p.setAttribute('stroke-linejoin', 'round');
    svg.appendChild(p);
    return el('span', { class: 'soporte-icono' }, svg);
  }

  async function cargarEnlaces() {
    const grid = $('soporte-grid');
    const { data, error } = await sb.from('enlaces_soporte').select('clave, valor, activo');
    const porClave = {};
    (error ? [] : data).forEach((e) => { porClave[e.clave] = e; });
    vaciar(grid);
    TARJETAS.forEach((t) => {
      const e = porClave[t.clave];
      const listo = e && e.activo && e.valor;
      const cuerpo = [icono(t.clave),
        el('div', { class: 'soporte-txt' },
          el('b', { text: t.titulo }),
          el('span', { class: 'mut', text: t.texto }),
          listo ? null : el('span', { class: 'pill pill-gris', text: 'Próximamente' }))];
      grid.appendChild(listo
        ? el('a', { class: 'card soporte-card', href: t.href(e.valor), target: '_blank', rel: 'noopener' }, cuerpo)
        : el('div', { class: 'card soporte-card inactiva', 'aria-disabled': 'true' }, cuerpo));
    });
  }

  // ---------- Estado de la cuenta ----------
  async function cargarEstado() {
    const caja = $('estado-cuenta');
    const { data, error } = await sb.rpc('mi_resumen_perfil');
    vaciar(caja);
    const enlaceReglas = el('a', { class: 'chip chip-link', href: 'reglas.html', target: '_blank', rel: 'noopener', text: 'Reglas' });
    if (error || !data) {
      caja.append(el('span', { class: 'mut', text: 'No se pudo cargar el estado de tu cuenta. ' + traducirErrorDatos(error) }), enlaceReglas);
      return;
    }
    const conGrupo = (data.niveles || []).some((n) => n.posicion);
    const grupo = conGrupo ? 'activo' : data.en_espera ? 'en espera' : 'sin grupo';
    caja.append(
      el('span', { class: 'chip', text: 'Nivel actual: ' + (data.nivel_actual ? data.nivel_actual.nombre : '—') }),
      el('span', { class: 'chip', text: 'Mi grupo: ' + grupo }),
      el('span', { class: 'chip', text: 'Referidos: ' + data.referidos + ' de 2' }),
      enlaceReglas
    );
  }

  // ---------- Plazos reales en las preguntas frecuentes ----------
  async function cargarPlazos() {
    const [rc, rn] = await Promise.all([
      sb.from('configuracion').select('clave, valor').in('clave', ['horas_tarea', 'dias_invitar']),
      sb.from('dias_invitar_nivel').select('nivel_id', { count: 'exact', head: true })
    ]);
    if (rc.error) return;
    const v = {};
    rc.data.forEach((c) => { v[c.clave] = Number(c.valor); });
    if (v.horas_tarea) {
      $('faq-horas').textContent = formatoNumero(v.horas_tarea) + (v.horas_tarea === 1 ? ' hora' : ' horas');
    }
    if (v.dias_invitar) {
      const porNivel = !rn.error && rn.count > 0;
      $('faq-dias').textContent = formatoNumero(v.dias_invitar) + (v.dias_invitar === 1 ? ' día' : ' días') +
        (porNivel ? ' (puede variar según el nivel)' : '');
    }
  }

  cargarEnlaces();
  cargarEstado();
  cargarPlazos();
})();
