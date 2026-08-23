// db.mjs — acces a la base via PostgREST avec la cle service_role.
//
// Pas de client Postgres : le service parle le meme protocole que le
// reste de l'application, ce qui garde une seule facon d'atteindre la
// base et evite d'embarquer une dependance native dans l'image.

export function createDb({ postgrestUrl, serviceKey, timeoutMs = 8000 }) {
  const base = postgrestUrl.replace(/\/$/, '');

  async function request(path, { method = 'GET', body, headers = {} } = {}) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await fetch(base + path, {
        method,
        signal: ctrl.signal,
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          'Content-Type': 'application/json',
          ...headers,
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await res.text();
      const data = text ? JSON.parse(text) : null;
      if (!res.ok) {
        const err = new Error(`postgrest ${res.status}: ${text.slice(0, 200)}`);
        err.status = res.status;
        throw err;
      }
      return data;
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    request,
    select: (table, query = '') => request(`/${table}${query ? '?' + query : ''}`),
    insert: (table, row, prefer = 'return=representation') =>
      request(`/${table}`, { method: 'POST', body: row, headers: { Prefer: prefer } }),
    patch: (table, query, row) =>
      request(`/${table}?${query}`, { method: 'PATCH', body: row, headers: { Prefer: 'return=representation' } }),
    rpc: (fn, args) => request(`/rpc/${fn}`, { method: 'POST', body: args }),
  };
}
