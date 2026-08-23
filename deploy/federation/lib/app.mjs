// app.mjs — routage et regles de la passerelle de federation.
//
// Ecrit comme une fonction pure de ses dependances (base, horloge,
// fetch) pour etre testable sans ouvrir de socket ni de base : les
// tests injectent des doubles et verifient les regles, pas la plomberie.
//
// Trois familles de routes :
//   /federation/v1/...        appelees par un PAIR, signees Ed25519
//   /federation/v1/local/...  appelees par NOTRE interface, jeton GoTrue
//   /federation/v1/health|identity   publiques (sonde et jumelage)

import { randomUUID } from 'node:crypto';
import { signPeerToken, verifyPeerToken, verifyLocalToken, publicKeyFromSpki } from './jwt.mjs';

const PREFIX = '/federation/v1';

class HttpError extends Error {
  constructor(status, code, extra = {}) {
    super(code);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

const json = (status, body) => ({ status, body });

export function createApp({ config, db, fetchImpl = fetch, now = () => new Date() }) {
  const publicKeyB64 = config.publicKeyB64;

  // ── Authentification ─────────────────────────────────────────────
  function bearer(headers) {
    const raw = headers.authorization || headers.Authorization || '';
    const m = /^Bearer\s+(.+)$/i.exec(raw);
    if (!m) throw new HttpError(401, 'missing_token');
    return m[1];
  }

  // Le pair s'annonce dans `iss`. On ne fait confiance a ce champ que
  // pour CHOISIR la cle publique : c'est la signature qui authentifie.
  async function authPeer(headers, { capability } = {}) {
    const token = bearer(headers);
    let iss;
    try {
      iss = JSON.parse(Buffer.from(token.split('.')[1], 'base64url')).iss;
    } catch {
      throw new HttpError(401, 'malformed_token');
    }
    if (!iss) throw new HttpError(401, 'missing_issuer');

    const rows = await db.select('federation_peers',
      `instance_id=eq.${encodeURIComponent(iss)}&limit=1`);
    const peer = rows?.[0];
    if (!peer) throw new HttpError(403, 'unknown_peer');
    if (peer.status !== 'active') throw new HttpError(403, 'peer_not_active');

    let payload;
    try {
      payload = verifyPeerToken(token, publicKeyFromSpki(peer.public_key), { audience: config.instanceId });
    } catch (e) {
      throw new HttpError(401, 'invalid_signature', { detail: e.message });
    }
    if (capability === 'reservations' && !peer.allow_reservations) throw new HttpError(403, 'reservations_not_allowed');
    if (capability === 'finance' && !peer.allow_finance) throw new HttpError(403, 'finance_not_allowed');

    // Trace de vie : sert au diagnostic « le VPN est-il debout ? ».
    db.patch('federation_peers', `id=eq.${peer.id}`, { last_seen_at: now().toISOString() }).catch(() => {});
    return { peer, payload };
  }

  async function authLocalUser(headers) {
    const token = bearer(headers);
    let payload;
    try {
      payload = verifyLocalToken(token, config.localJwtSecret);
    } catch (e) {
      throw new HttpError(401, 'invalid_token', { detail: e.message });
    }
    if (!payload.sub) throw new HttpError(401, 'missing_subject');
    return { userId: payload.sub, token };
  }

  // ── Profils ombres ───────────────────────────────────────────────
  // Un usager distant n'a pas de compte ici. On lui fabrique, a la
  // premiere operation, un profil local inerte : il ne peut pas se
  // connecter (aucun mot de passe utilisable), il sert uniquement de
  // titulaire pour les cles etrangeres du schema existant.
  async function resolveGuest(peer, remoteUserId, remoteName) {
    const existing = await db.select('federation_guests',
      `peer_id=eq.${peer.id}&remote_user_id=eq.${encodeURIComponent(remoteUserId)}&limit=1`);
    if (existing?.[0]) return existing[0].profile_id;

    if (!config.gotrueUrl) throw new HttpError(503, 'gotrue_unavailable');
    const email = `fed-${peer.instance_id}-${remoteUserId}@federation.local`.toLowerCase();
    const res = await fetchImpl(`${config.gotrueUrl.replace(/\/$/, '')}/admin/users`, {
      method: 'POST',
      headers: {
        apikey: config.serviceKey,
        Authorization: `Bearer ${config.serviceKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email,
        email_confirm: true,
        password: randomUUID() + randomUUID(),   // jamais communique
        user_metadata: { full_name: remoteName || `Invite ${peer.display_name}` },
      }),
    });
    if (!res.ok) throw new HttpError(502, 'guest_creation_failed', { detail: (await res.text()).slice(0, 200) });
    const user = await res.json();

    // Le trigger on_auth_user_created a deja cree la ligne profiles.
    await db.patch('profiles', `id=eq.${user.id}`, {
      full_name: remoteName || `Invite ${peer.display_name}`,
      origin_peer_id: peer.id,
      is_active: true,
    });
    await db.insert('federation_guests', {
      peer_id: peer.id,
      remote_user_id: remoteUserId,
      profile_id: user.id,
      display_name: remoteName || null,
    });
    return user.id;
  }

  // ── Tarification ─────────────────────────────────────────────────
  // Le prix fait foi chez le proprietaire de l'espace. Le pair propose
  // un montant, on le recalcule et on refuse s'il ne correspond pas :
  // sans cela, une instance compromise fixerait ses propres tarifs.
  async function priceFor(spaceId, slots) {
    const rows = await db.select('space_pricing',
      `space_id=eq.${spaceId}&select=price_per_slot,valid_from,valid_to&order=valid_from.desc&limit=1`);
    const price = Number(rows?.[0]?.price_per_slot ?? 0);
    return Math.round(price * slots * 100) / 100;
  }

  // ── Appel sortant vers un pair ───────────────────────────────────
  async function callPeer(peer, path, { method = 'GET', body, subject } = {}) {
    const token = signPeerToken(
      { iss: config.instanceId, aud: peer.instance_id, sub: subject || null },
      config.privateKey,
      { kid: config.instanceId },
    );
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), config.peerTimeoutMs);
    try {
      const res = await fetchImpl(peer.base_url.replace(/\/$/, '') + path, {
        method,
        signal: ctrl.signal,
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await res.text();
      let data = null;
      try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text.slice(0, 200) }; }
      return { ok: res.ok, status: res.status, data };
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Routes ───────────────────────────────────────────────────────
  const routes = {
    // Sonde : volontairement anonyme, c'est ce que le pair interroge
    // pour savoir si le tunnel est debout.
    [`GET ${PREFIX}/health`]: async () => json(200, { ok: true, instance_id: config.instanceId }),

    // Carte de visite lue au jumelage.
    [`GET ${PREFIX}/identity`]: async () => json(200, {
      instance_id: config.instanceId,
      display_name: config.displayName,
      public_key: publicKeyB64,
    }),

    // Demande de jumelage. Enregistree en 'pending' : c'est un
    // administrateur qui active, jamais le reseau.
    [`POST ${PREFIX}/pair`]: async ({ body }) => {
      const { instance_id, display_name, base_url, public_key, introduced_by } = body || {};
      if (!instance_id || !base_url || !public_key) throw new HttpError(400, 'invalid_pairing_request');
      try {
        publicKeyFromSpki(public_key);
      } catch {
        throw new HttpError(400, 'invalid_public_key');
      }

      const existing = await db.select('federation_peers',
        `instance_id=eq.${encodeURIComponent(instance_id)}&limit=1`);
      if (existing?.[0]) {
        // Une demande ne peut pas changer la cle d'un pair deja connu :
        // ce serait un remplacement d'identite par simple appel reseau.
        if (existing[0].public_key !== public_key) throw new HttpError(409, 'key_mismatch');
        return json(200, { ok: true, status: existing[0].status });
      }
      await db.insert('federation_peers', {
        instance_id,
        display_name: display_name || instance_id,
        base_url,
        public_key,
        status: 'pending',
        introduced_by: introduced_by || 'local',
      });
      return json(201, { ok: true, status: 'pending' });
    },

    // Catalogue offert aux pairs : seuls les espaces explicitement
    // partages par un administrateur y figurent.
    [`GET ${PREFIX}/spaces`]: async ({ headers }) => {
      await authPeer(headers, { capability: 'reservations' });
      const spaces = await db.select('common_spaces',
        'federation_shared=eq.true&is_available=eq.true&select=id,name,description,capacity,location,space_pricing(price_per_slot)');
      return json(200, { instance_id: config.instanceId, spaces: spaces || [] });
    },

    [`POST ${PREFIX}/reservations`]: async ({ headers, body }) => {
      const { peer } = await authPeer(headers, { capability: 'reservations' });
      const { idempotency_key, remote_user_id, remote_user_name, space_id, start, end, slots, cost } = body || {};
      if (!idempotency_key || !remote_user_id || !space_id || !start || !end || !slots) {
        throw new HttpError(400, 'invalid_request');
      }

      const shared = await db.select('common_spaces',
        `id=eq.${space_id}&federation_shared=eq.true&limit=1`);
      if (!shared?.[0]) throw new HttpError(404, 'space_not_shared');

      const authoritative = await priceFor(space_id, slots);
      if (cost !== undefined && Math.abs(Number(cost) - authoritative) > 0.001) {
        throw new HttpError(409, 'price_mismatch', { cost: authoritative });
      }

      const profileId = await resolveGuest(peer, remote_user_id, remote_user_name);
      const result = await db.rpc('federation_reserve_space', {
        p_peer_id: peer.id,
        p_key: idempotency_key,
        p_profile_id: profileId,
        p_space_id: space_id,
        p_start: start,
        p_end: end,
        p_slots: slots,
        p_cost: authoritative,
      });
      if (!result?.ok) return json(409, result || { ok: false, error: 'unknown' });
      return json(200, result);
    },

    [`POST ${PREFIX}/reservations/cancel`]: async ({ headers, body }) => {
      const { peer } = await authPeer(headers, { capability: 'reservations' });
      const { idempotency_key, reservation_id, reason, refund } = body || {};
      if (!idempotency_key || !reservation_id) throw new HttpError(400, 'invalid_request');
      const result = await db.rpc('federation_cancel_reservation', {
        p_peer_id: peer.id,
        p_key: idempotency_key,
        p_res_id: reservation_id,
        p_reason: reason || null,
        p_refund: Number(refund || 0),
      });
      if (!result?.ok) return json(409, result || { ok: false, error: 'unknown' });
      return json(200, result);
    },

    [`POST ${PREFIX}/transfers`]: async ({ headers, body }) => {
      const { peer } = await authPeer(headers, { capability: 'finance' });
      const { idempotency_key, remote_user_id, remote_user_name, target_email, amount, type, description } = body || {};
      if (!idempotency_key || !amount) throw new HttpError(400, 'invalid_request');

      // Deux facons de designer le beneficiaire : un de nos locataires
      // (par courriel) ou l'invite du pair (profil ombre).
      let profileId;
      if (target_email) {
        const rows = await db.select('profiles',
          `email=eq.${encodeURIComponent(target_email)}&select=id&limit=1`);
        if (!rows?.[0]) throw new HttpError(404, 'target_not_found');
        profileId = rows[0].id;
      } else if (remote_user_id) {
        profileId = await resolveGuest(peer, remote_user_id, remote_user_name);
      } else {
        throw new HttpError(400, 'missing_target');
      }

      const result = await db.rpc('federation_apply_transfer', {
        p_peer_id: peer.id,
        p_key: idempotency_key,
        p_profile_id: profileId,
        p_amount: Number(amount),
        p_type: type || 'admin_credit',
        p_description: description || null,
      });
      if (!result?.ok) return json(409, result || { ok: false, error: 'unknown' });
      return json(200, result);
    },

    // ── Cote interface locale ──────────────────────────────────────
    [`GET ${PREFIX}/local/peers`]: async ({ headers }) => {
      await authLocalUser(headers);
      const peers = await db.select('federation_peers',
        'status=eq.active&select=instance_id,display_name,allow_reservations,allow_finance,last_seen_at&order=display_name');
      return json(200, { peers: peers || [] });
    },

    // Agrege les catalogues des pairs. Un pair injoignable n'empeche
    // pas les autres de repondre : la liste est partielle, jamais en
    // erreur, et `unreachable` le dit a l'interface.
    [`GET ${PREFIX}/local/spaces`]: async ({ headers }) => {
      await authLocalUser(headers);
      const peers = await db.select('federation_peers',
        'status=eq.active&allow_reservations=eq.true&select=id,instance_id,display_name,base_url,public_key');
      const spaces = [];
      const unreachable = [];
      await Promise.all((peers || []).map(async (peer) => {
        try {
          const res = await callPeer(peer, `${PREFIX}/spaces`);
          if (!res.ok) { unreachable.push(peer.instance_id); return; }
          for (const s of res.data?.spaces || []) {
            spaces.push({ ...s, _peer_instance_id: peer.instance_id, _peer_name: peer.display_name });
          }
        } catch {
          unreachable.push(peer.instance_id);
        }
      }));
      return json(200, { spaces, unreachable });
    },

    // Reservation d'un espace chez un pair. L'ordre compte : on engage
    // localement (debit + creance) AVANT le reseau, puis on solde selon
    // la reponse. Une coupure laisse la requete en file, jamais un
    // debit orphelin.
    [`POST ${PREFIX}/local/reservations`]: async ({ headers, body }) => {
      const { userId } = await authLocalUser(headers);
      const { peer_instance_id, space_id, start, end, slots } = body || {};
      if (!peer_instance_id || !space_id || !start || !end || !slots) throw new HttpError(400, 'invalid_request');

      const peers = await db.select('federation_peers',
        `instance_id=eq.${encodeURIComponent(peer_instance_id)}&status=eq.active&limit=1`);
      const peer = peers?.[0];
      if (!peer) throw new HttpError(404, 'peer_not_found');
      if (!peer.allow_reservations) throw new HttpError(403, 'reservations_not_allowed');

      // Prix annonce par le proprietaire, jamais calcule ici.
      const cat = await callPeer(peer, `${PREFIX}/spaces`);
      if (!cat.ok) throw new HttpError(503, 'peer_unreachable');
      const space = (cat.data?.spaces || []).find((s) => s.id === space_id);
      if (!space) throw new HttpError(404, 'space_not_shared');
      const price = Number(space.space_pricing?.[0]?.price_per_slot ?? 0);
      const cost = Math.round(price * slots * 100) / 100;

      const key = `${config.instanceId}:${userId}:${space_id}:${start}`;
      const begun = await db.rpc('federation_begin_outbound', {
        p_peer_id: peer.id,
        p_key: key,
        p_kind: 'reservation.create',
        p_user_id: userId,
        p_amount: cost,
        p_payload: { user_id: userId, space_id, start, end, slots, cost, peer: peer.instance_id },
      });
      if (!begun?.ok) throw new HttpError(409, begun?.error || 'begin_failed');
      if (begun.replayed && begun.status === 'settled') {
        return json(200, { ok: true, replayed: true, ...(begun.response || {}) });
      }

      let res;
      try {
        res = await callPeer(peer, `${PREFIX}/reservations`, {
          method: 'POST',
          subject: userId,
          body: {
            idempotency_key: key,
            remote_user_id: userId,
            remote_user_name: body.user_name || null,
            space_id, start, end, slots, cost,
          },
        });
      } catch {
        // Reseau coupe : la file reessaiera, l'argent reste engage.
        await db.rpc('federation_defer_outbound', {
          p_request_id: begun.request_id, p_delay: '00:00:30', p_error: 'peer_unreachable',
        });
        return json(202, { ok: false, queued: true, error: 'peer_unreachable' });
      }

      if (res.ok && res.data?.ok) {
        await db.rpc('federation_settle_outbound', {
          p_request_id: begun.request_id, p_status: 'settled', p_response: res.data, p_error: null,
        });
        return json(200, { ok: true, cost, ...res.data });
      }

      // 5xx : le pair est la mais fatigue — on reessaiera. 4xx : refus
      // definitif (creneau pris, prix change), on rend l'argent.
      if (res.status >= 500) {
        await db.rpc('federation_defer_outbound', {
          p_request_id: begun.request_id, p_delay: '00:01:00', p_error: `peer_${res.status}`,
        });
        return json(202, { ok: false, queued: true, error: 'peer_error' });
      }
      await db.rpc('federation_settle_outbound', {
        p_request_id: begun.request_id, p_status: 'failed', p_response: res.data,
        p_error: res.data?.error || `peer_${res.status}`,
      });
      return json(409, { ok: false, error: res.data?.error || 'rejected', detail: res.data });
    },
  };

  // ── Point d'entree ───────────────────────────────────────────────
  async function handle({ method, path, headers = {}, body = null }) {
    const route = routes[`${method} ${path}`];
    if (!route) return json(404, { error: 'not_found' });
    try {
      return await route({ method, path, headers, body });
    } catch (e) {
      if (e instanceof HttpError) return json(e.status, { error: e.code, ...e.extra });
      return json(500, { error: 'internal_error', detail: String(e.message || e).slice(0, 200) });
    }
  }

  return { handle, callPeer, routes };
}

export { HttpError };
