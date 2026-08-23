// outbox.mjs — reprise des operations sortantes apres coupure du VPN.
//
// Une reservation engagee alors que le pair etait injoignable reste en
// file : l'argent est deja retenu chez nous, la creance aussi. Le
// boucleur rejoue l'appel avec la MEME cle d'idempotence — le pair ne
// creera donc jamais deux reservations — jusqu'a reussite ou epuisement
// des tentatives, auquel cas le locataire est rembourse.

const PREFIX = '/federation/v1';

export function createOutbox({ config, db, app, log = console }) {
  let timer = null;
  let running = false;

  async function drainOnce(nowIso = new Date().toISOString()) {
    const pending = await db.select('federation_requests',
      `direction=eq.outbound&status=eq.pending&next_attempt_at=lte.${nowIso}` +
      '&select=id,peer_id,idempotency_key,kind,payload,attempts&order=next_attempt_at&limit=20');

    let sent = 0, deferred = 0, abandoned = 0;
    for (const req of pending || []) {
      const peers = await db.select('federation_peers', `id=eq.${req.peer_id}&limit=1`);
      const peer = peers?.[0];
      if (!peer || peer.status !== 'active') {
        await db.rpc('federation_settle_outbound', {
          p_request_id: req.id, p_status: 'failed', p_response: null, p_error: 'peer_inactive',
        });
        abandoned++;
        continue;
      }

      if (req.attempts >= config.outboxMaxAttempts) {
        // On rend l'argent plutot que de laisser une retenue eternelle.
        await db.rpc('federation_settle_outbound', {
          p_request_id: req.id, p_status: 'failed', p_response: null, p_error: 'max_attempts',
        });
        abandoned++;
        continue;
      }

      const p = req.payload || {};
      let res;
      try {
        res = await app.callPeer(peer, `${PREFIX}/reservations`, {
          method: 'POST',
          subject: p.user_id,
          body: {
            idempotency_key: req.idempotency_key,
            remote_user_id: p.user_id,
            space_id: p.space_id,
            start: p.start,
            end: p.end,
            slots: p.slots,
            cost: p.cost,
          },
        });
      } catch (e) {
        await defer(req, 'peer_unreachable');
        deferred++;
        continue;
      }

      if (res.ok && res.data?.ok) {
        await db.rpc('federation_settle_outbound', {
          p_request_id: req.id, p_status: 'settled', p_response: res.data, p_error: null,
        });
        sent++;
      } else if (res.status >= 500) {
        await defer(req, `peer_${res.status}`);
        deferred++;
      } else {
        await db.rpc('federation_settle_outbound', {
          p_request_id: req.id, p_status: 'failed', p_response: res.data,
          p_error: res.data?.error || `peer_${res.status}`,
        });
        abandoned++;
      }
    }
    return { sent, deferred, abandoned, examined: (pending || []).length };
  }

  // Recul exponentiel plafonne a 30 min : un VPN coupe une nuit ne doit
  // pas marteler le lien au retour.
  function defer(req, error) {
    const seconds = Math.min(30 * 60, 30 * Math.pow(2, Math.min(req.attempts, 6)));
    const hh = String(Math.floor(seconds / 3600)).padStart(2, '0');
    const mm = String(Math.floor((seconds % 3600) / 60)).padStart(2, '0');
    const ss = String(seconds % 60).padStart(2, '0');
    return db.rpc('federation_defer_outbound', {
      p_request_id: req.id, p_delay: `${hh}:${mm}:${ss}`, p_error: error,
    });
  }

  function start() {
    if (timer) return;
    timer = setInterval(async () => {
      if (running) return;
      running = true;
      try {
        const r = await drainOnce();
        if (r.examined) log.info('[outbox]', JSON.stringify(r));
      } catch (e) {
        log.warn('[outbox] echec du cycle:', e.message);
      } finally {
        running = false;
      }
    }, config.outboxIntervalMs);
    timer.unref?.();
  }

  function stop() {
    if (timer) clearInterval(timer);
    timer = null;
  }

  return { start, stop, drainOnce, defer };
}
