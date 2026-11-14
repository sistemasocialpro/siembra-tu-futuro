// Tarjeta "Tu reloj" (Inicio y Mi grupo). Usa js/comun.js
//
// El tiempo restante se calcula SIEMPRE con la hora del servidor: mi_reloj() devuelve "ahora"
// (hora del servidor) y los plazos. Desde ahí se avanza con performance.now(), que es un reloj
// monotónico: cambiar la hora del celular no altera la cuenta.
//
// crearReloj(datos, op) -> { nodo, detener() }
//   datos: respuesta de rpc('mi_reloj')
//   datos.fase: 'tarea' (Paso 1, solo regaladores) | 'esperando' (tarea hecha, X/4 aprobadas) |
//               'invitar' (Paso 2, solo constructores ascendidos) | 'listo' | 'plazo_vencido'
//   op: { onMarcar(): Promise, onCopiarEnlace(): Promise<boolean>, onVencer() }

function crearReloj(datos, op) {
  op = op || {};
  const base = { servidor: Date.parse(datos.ahora), perf: performance.now() };
  const ahoraServidor = () => base.servidor + (performance.now() - base.perf);

  let intervalo = null;
  let vencerAvisado = false;
  const invitados = Math.min(Number(datos.invitados) || 0, 2);
  const fase = datos.fase || (datos.estado === 'reservada' ? 'tarea' : 'invitar');

  const dos = (n) => String(n).padStart(2, '0');
  function hhmmss(ms) {
    const s = Math.max(0, Math.floor(ms / 1000));
    return dos(Math.floor(s / 3600)) + ':' + dos(Math.floor((s % 3600) / 60)) + ':' + dos(s % 60);
  }
  function dhm(ms) {
    const m = Math.max(0, Math.floor(ms / 60000));
    return Math.floor(m / 1440) + ' d ' + Math.floor((m % 1440) / 60) + ' h ' + (m % 60) + ' min';
  }
  function detener() { if (intervalo) { clearInterval(intervalo); intervalo = null; } }
  function circulos(n, total) {
    const caja = el('span', { class: 'circulos', 'aria-hidden': 'true' });
    for (let i = 1; i <= total; i++) caja.appendChild(el('span', { class: 'circulo' + (n >= i ? ' lleno' : '') }));
    return caja;
  }

  const cabecera = (texto) => el('div', { class: 'reloj-cab' },
    el('span', { class: 'reloj-etiqueta', text: 'Tu reloj · Nivel ' + datos.nivel_nombre + ' · ' + (NOMBRE_POSICION[datos.posicion] || '') }),
    texto ? el('span', { class: 'reloj-fase', text: texto }) : null
  );
  const msg = el('div', { class: 'msg error', role: 'alert', hidden: true });
  function mostrarError(t) { msg.textContent = t; msg.hidden = false; }

  let nodo;

  // ---------- Plazo vencido (constructor sin sus 2 invitados a tiempo) ----------
  if (fase === 'plazo_vencido') {
    nodo = el('section', { class: 'card reloj reloj-rojo', 'aria-label': 'Tu reloj' },
      cabecera('Suspendido'),
      el('h3', { text: 'Plazo vencido' }),
      el('p', { text: 'No completaste tus 2 invitados a tiempo. Tu posición quedó suspendida y quien te invitó puede reemplazarte por otra persona que haya invitado.' }),
      el('div', { class: 'reloj-invitados' }, el('span', { text: 'Invitados: ' + invitados + '/2' }), circulos(invitados, 2))
    );
    return { nodo, detener };
  }

  // ---------- Paso 2 completo: ya tiene sus 2 invitados ----------
  if (fase === 'listo') {
    nodo = el('section', { class: 'card reloj reloj-verde', 'aria-label': 'Tu reloj' },
      cabecera('Completado'),
      el('h3', { text: '¡Listo! Ya completaste tus 2 invitados' }),
      el('div', { class: 'reloj-invitados' }, el('span', { text: 'Invitados: 2/2' }), circulos(2, 2)),
      el('p', { class: 'reloj-nota', text: 'Cuando el recibidor de tu grupo reciba sus 4 tareas, pasarás al centro de un grupo nuevo.' })
    );
    return { nodo, detener };
  }

  // ---------- Regalador que ya hizo su tarea: espera a los demás ----------
  if (fase === 'esperando') {
    const aprobadas = Math.min(Number(datos.aprobadas) || 0, 4);
    nodo = el('section', { class: 'card reloj reloj-espera', 'aria-label': 'Tu reloj' },
      cabecera('Paso 1 · Hecho'),
      el('h3', { text: 'Esperando a los demás regaladores (' + aprobadas + '/4 aprobadas)' }),
      el('div', { class: 'reloj-invitados' }, el('span', { text: 'Aprobadas: ' + aprobadas + '/4' }), circulos(aprobadas, 4)),
      el('p', { text: datos.estado === 'confirmada'
        ? 'El recibidor ya aprobó tu tarea. Tu reloj de la tarea se detuvo.'
        : 'Tu tarea está marcada como hecha y tu reloj se detuvo. Falta que el recibidor la apruebe.' }),
      el('p', { class: 'reloj-nota', text: 'Cuando los 4 regaladores estén aprobados subirás a constructor y empezará el Paso 2: invitar a 2 personas.' })
    );
    return { nodo, detener };
  }

  // ---------- Paso 1: haz tu tarea (regaladores, reloj de horas_tarea) ----------
  if (fase === 'tarea') {
    const inicio = Date.parse(datos.reservada_en);
    const fin = Date.parse(datos.fin_tarea);
    const total = Math.max(1, fin - inicio);
    const cifra = el('div', { class: 'reloj-cifra', role: 'timer', 'aria-label': 'Tiempo restante para hacer tu tarea' });
    const relleno = el('div', { class: 'reloj-relleno' });
    const barra = el('div', { class: 'reloj-barra', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '100' }, relleno);
    const texto = el('p', { text: 'Contacta al recibidor por WhatsApp y marca tu tarea como hecha antes de que se acabe el tiempo.' });

    const btnMarcar = el('button', { type: 'button', class: 'btn', text: 'Marcar mi tarea como hecha' });
    btnMarcar.addEventListener('click', async () => {
      if (!op.onMarcar) return;
      btnMarcar.disabled = true;
      msg.hidden = true;
      try {
        const hecho = await op.onMarcar(datos);
        if (hecho === false) btnMarcar.disabled = false; // canceló la confirmación
      } catch (err) {
        mostrarError(traducirErrorDatos(err));
        btnMarcar.disabled = false;
      }
    });

    const botones = el('div', { class: 'botones' }, btnMarcar,
      datos.recibidor_whatsapp
        ? el('a', {
            class: 'bt-amarillo', target: '_blank', rel: 'noopener',
            href: enlaceWhatsApp(datos.recibidor_whatsapp, 'Hola ' + (datos.recibidor_nombre || '') + ', soy ' + (NOMBRE_POSICION[datos.posicion] || 'regalador') + ' en tu grupo de Siembra tu Futuro (nivel ' + datos.nivel_nombre + '). Quiero coordinar mi tarea.'),
            text: 'Escribir por WhatsApp al recibidor'
          })
        : null
    );

    nodo = el('section', { class: 'card reloj reloj-fase1', 'aria-label': 'Tu reloj' },
      cabecera('Paso 1 · Haz tu tarea'),
      el('h3', { text: 'Haz tu tarea' }),
      cifra, barra, texto,
      datos.recibidor_whatsapp ? null : el('p', { class: 'mut', text: datos.recibidor_nombre ? 'El WhatsApp del recibidor no está disponible. Pide ayuda en Soporte.' : 'Tu grupo todavía no tiene recibidor.' }),
      botones, msg
    );

    const arrancoConTiempo = fin - ahoraServidor() > 0;
    function tic() {
      const resta = fin - ahoraServidor();
      cifra.textContent = hhmmss(resta);
      const pct = Math.max(0, Math.min(100, (resta / total) * 100));
      relleno.style.width = pct.toFixed(2) + '%';
      barra.setAttribute('aria-valuenow', String(Math.round(pct)));
      // Verde -> amarillo (menos de la mitad) -> rojo (menos de 1 hora; en pruebas con plazos cortos, último cuarto)
      const rojo = resta < Math.min(3600000, total / 4);
      const amarillo = !rojo && resta < total / 2;
      nodo.classList.toggle('nivel-amarillo', amarillo);
      nodo.classList.toggle('nivel-rojo', rojo);
      if (resta <= 0) {
        texto.textContent = 'Se acabó el tiempo. Tu lugar se liberará en unos minutos.';
        btnMarcar.disabled = true;
        detener();
        if (arrancoConTiempo && !vencerAvisado && op.onVencer) { vencerAvisado = true; setTimeout(op.onVencer, 3000); }
      }
    }
    tic();
    intervalo = setInterval(tic, 1000);
    return { nodo, detener };
  }

  // ---------- Paso 2: subiste a constructor, invita a 2 personas (reloj de dias_invitar) ----------
  const fin = Date.parse(datos.fin_invitar);
  const cifra = el('div', { class: 'reloj-cifra reloj-cifra-dias', role: 'timer', 'aria-label': 'Tiempo restante para invitar a 2 personas' });
  const btnCopiar = el('button', { type: 'button', class: 'btn', text: 'Copiar mi enlace de invitación' });
  const copiado = el('div', { class: 'msg ok', role: 'status', hidden: true });
  btnCopiar.addEventListener('click', async () => {
    if (!op.onCopiarEnlace) return;
    const ok = await op.onCopiarEnlace();
    copiado.className = 'msg ' + (ok ? 'ok' : 'error');
    copiado.textContent = ok ? '¡Enlace copiado! Compártelo con las personas que quieras invitar.' : 'No se pudo copiar. Copia tu enlace desde la tarjeta "Enlace de invitación".';
    copiado.hidden = false;
    setTimeout(() => { copiado.hidden = true; }, 4000);
  });
  const texto = el('p', { text: 'Subiste a constructor. Comparte tu enlace: cada círculo se llena cuando una persona que invitaste toca Participar en este nivel y obtiene su lugar.' });

  nodo = el('section', { class: 'card reloj reloj-fase2', 'aria-label': 'Tu reloj' },
    cabecera('Paso 2 · Subes a constructor e invitas a 2'),
    el('h3', { text: 'Invita a 2 personas' }),
    cifra,
    el('div', { class: 'reloj-invitados' }, el('span', { text: 'Invitados: ' + invitados + '/2' }), circulos(invitados, 2)),
    texto,
    el('div', { class: 'botones' }, btnCopiar),
    copiado, msg
  );

  function tic2() {
    const resta = fin - ahoraServidor();
    cifra.textContent = resta < 86400000 ? hhmmss(resta) : dhm(resta); // último día: HH:MM:SS
    nodo.classList.toggle('nivel-rojo', resta < Math.min(86400000, (fin - Date.parse(datos.ascendido_en)) / 4));
    if (resta <= 0) {
      texto.textContent = 'El plazo para invitar terminó. El sistema revisará tu situación en unos minutos.';
      detener();
    }
  }
  tic2();
  intervalo = setInterval(tic2, 1000);
  return { nodo, detener };
}
