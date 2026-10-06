// INFORUAN — lógica HTTP da Edge Function gg-webhook (sem dependências; roda em Deno e no Node para testes).
// Autentica, limita tamanho e repassa ao banco (public.ingest_gg_webhook). As regras de negócio ficam no banco.
// Nunca registra corpo, cabeçalhos ou segredo em log.

export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ status: number; body: unknown }>;
export interface Deps {
  secret: string | undefined;        // GG_WEBHOOK_SECRET (obrigatório: sem ele, tudo é recusado)
  rpc: Rpc;
  maxBytes?: number;                  // padrão 64 KB
  log?: (line: string) => void;
}

const KEEP_HEADERS = ['content-type', 'user-agent', 'x-request-id', 'x-ggcheckout-event'];
const enc = new TextEncoder();

const json = (status: number, body: Record<string, unknown>): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

// Comparação em tempo constante (não vaza, pelo tempo, quantos caracteres batem).
function safeEqual(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

async function hmacHex(secret: string, raw: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, raw));
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
}

// Aceita as três formas documentadas pela GGCheckout: Bearer, x-secret ou X-Webhook-Signature (HMAC-SHA256 do corpo).
async function authorized(req: Request, secret: string, raw: Uint8Array): Promise<boolean> {
  const auth = req.headers.get('authorization') ?? '';
  if (auth.toLowerCase().startsWith('bearer ') && safeEqual(auth.slice(7).trim(), secret)) return true;
  const xs = req.headers.get('x-secret');
  if (xs !== null && safeEqual(xs.trim(), secret)) return true;
  const sig = req.headers.get('x-webhook-signature');
  if (sig !== null) {
    const got = sig.trim().toLowerCase().replace(/^sha256=/, '');
    if (safeEqual(got, await hmacHex(secret, raw))) return true;
  }
  return false;
}

async function readCapped(req: Request, max: number): Promise<Uint8Array | null> {
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.byteLength; }
  return out;
}

export async function handleGgWebhook(req: Request, deps: Deps): Promise<Response> {
  const log = deps.log ?? (() => {});
  const max = deps.maxBytes ?? 64 * 1024;
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });
  if (!deps.secret || deps.secret.length < 24) { log('gg-webhook 503 segredo ausente'); return json(503, { error: 'not_configured' }); }

  const declared = Number(req.headers.get('content-length') ?? '0');
  if (declared > max) return json(413, { error: 'payload_too_large' });
  const raw = await readCapped(req, max);
  if (raw === null) return json(413, { error: 'payload_too_large' });

  if (!(await authorized(req, deps.secret, raw))) { log('gg-webhook 401'); return json(401, { error: 'unauthorized' }); }

  let payload: Record<string, unknown>;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(raw));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('not_object');
    payload = parsed as Record<string, unknown>;
  } catch { return json(400, { error: 'invalid_json' }); }

  const headers: Record<string, string> = {};
  for (const h of KEEP_HEADERS) { const v = req.headers.get(h); if (v !== null) headers[h] = v.slice(0, 300); }

  let r: { status: number; body: unknown };
  try { r = await deps.rpc('ingest_gg_webhook', { p_headers: headers, p_payload: payload }); }
  catch { log('gg-webhook 500 banco indisponível'); return json(500, { error: 'storage_unavailable' }); }
  if (r.status < 200 || r.status >= 300) { log(`gg-webhook 500 rpc ${r.status}`); return json(500, { error: 'storage_error' }); }

  const res = (r.body ?? {}) as { accepted?: boolean; reason?: string; duplicate?: boolean };
  const event = String(payload.event ?? '').slice(0, 40);
  if (res.accepted) { log(`gg-webhook 200 ${event}${res.duplicate ? ' duplicado' : ''}`); return json(200, { ok: true }); }
  if (res.reason === 'internal_only') { log(`gg-webhook 200 ignorado (só internos) ${event}`); return json(200, { ok: true, ignored: true }); }
  if (res.reason === 'rate_limited') { log('gg-webhook 429'); return json(429, { error: 'rate_limited' }); }
  if (res.reason === 'invalid_payload') {
    // Autenticado, mas sem id de pagamento (ex.: "ping" de verificação da GGCheckout ao salvar o webhook).
    // Segredo já validado → 200 sem gravar nada; o log leva só os NOMES dos campos (nunca valores).
    const keys = Object.keys(payload).slice(0, 20).map((k) => k.replace(/[^\w.-]/g, '').slice(0, 30)).join(',');
    log(`gg-webhook 200 ignorado (sem id de pagamento) campos=${keys}`);
    return json(200, { ok: true, ignored: true });
  }
  log('gg-webhook 500 resposta inesperada do banco');
  return json(500, { error: 'unexpected' });
}
