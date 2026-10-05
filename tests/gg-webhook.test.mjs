// Edge Function gg-webhook: HTTP (handler.ts) + porta de entrada no banco (0010), no Postgres real (PGlite).
// Rodar: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { handleGgWebhook } from '../supabase/functions/gg-webhook/handler.ts';

const root = new URL('..', import.meta.url).pathname;
const FILES = ['migrations/0001_core.sql', 'migrations/0002_functions.sql', 'migrations/0003_views.sql', 'migrations/0004_hardening.sql',
  'migrations/0005_fk_indexes.sql', 'migrations/0006_api_interface.sql', 'seed/0001_config.sql', 'migrations/0007_modo_interno.sql',
  'migrations/0009_n8n_engine_limites.sql', 'migrations/0010_ingestao_gg.sql'].map((f) => readFileSync(root + 'supabase/' + f, 'utf8'));

const SECRET = 'segredo-de-teste-com-mais-de-24-caracteres';
const INTERNAL = '+5511900000001';
const TEST_CHECKOUT = 'q0EbnyHD8PgIraUBZTTl';

async function setup() {
  const db = new PGlite();
  for (const s of FILES) await db.exec(s);
  await db.exec(`update settings set value = '["${INTERNAL}"]' where key = 'internal_test_phones';
                 update sequences set active = true; update experiments set holdout_pct = 0;`);
  return db;
}
const one = async (db, sql, p = []) => (await db.query(sql, p)).rows[0];
const dbRpc = (db, calls = []) => async (fn, args) => {
  calls.push({ fn, args });
  assert.equal(fn, 'ingest_gg_webhook');
  const r = await one(db, `select public.ingest_gg_webhook($1::jsonb, $2::jsonb) r`, [JSON.stringify(args.p_headers), JSON.stringify(args.p_payload)]);
  return { status: 200, body: r.r };
};
const payload = (event, id, { phone = '5511988887777', checkoutId = 'dDTs0BWHlGqWRdqhQakS', status } = {}) => ({
  event, createdAt: new Date().toISOString(), checkoutId,
  customer: { name: 'Maria da Silva', email: 'maria@example.com', phone, document: '000' },
  payment: { id, paymentMethod: 'pix', status: status ?? (event.endsWith('paid') ? 'paid' : 'pending'), amount: 5, pixCode: 'PIX' + id },
  product: { id: 'EuwGEZ2vDJI3ACa8j4uE', title: 'Kit Completo Atualiza 40+' },
});
const post = (body, headers = {}) => new Request('https://x.supabase.co/functions/v1/gg-webhook', {
  method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body),
  headers: { 'content-type': 'application/json', ...headers },
});
const bearer = { authorization: `Bearer ${SECRET}` };

// ─── HTTP ────────────────────────────────────────────────────────────────────
test('HTTP: método, segredo ausente/curto, autenticação errada → nada chega ao banco', async () => {
  const calls = [];
  const rpc = async (...a) => { calls.push(a); return { status: 200, body: { accepted: true } }; };
  assert.equal((await handleGgWebhook(new Request('https://x/f', { method: 'GET' }), { secret: SECRET, rpc })).status, 405);
  assert.equal((await handleGgWebhook(post({}, bearer), { secret: undefined, rpc })).status, 503);
  assert.equal((await handleGgWebhook(post({}, bearer), { secret: 'curto', rpc })).status, 503);
  for (const h of [{}, { authorization: 'Bearer errado' }, { 'x-secret': 'errado' }, { 'x-webhook-signature': 'sha256=00' },
                   { authorization: SECRET }, { 'x-secret': SECRET + 'x' }]) {
    assert.equal((await handleGgWebhook(post(payload('pix.generated', 'P1'), h), { secret: SECRET, rpc })).status, 401, JSON.stringify(h));
  }
  assert.equal(calls.length, 0);
});

test('HTTP: aceita Bearer, x-secret e HMAC; repassa só cabeçalhos permitidos e nunca o segredo', async () => {
  const calls = [];
  const rpc = async (fn, args) => { calls.push(args); return { status: 200, body: { accepted: true, duplicate: false } }; };
  const body = JSON.stringify(payload('pix.generated', 'P1'));
  const sig = 'sha256=' + createHmac('sha256', SECRET).update(body).digest('hex');
  for (const h of [bearer, { 'x-secret': SECRET }, { 'x-webhook-signature': sig }, { 'X-Webhook-Signature': sig.toUpperCase().replace('SHA256=', 'sha256=') }]) {
    const r = await handleGgWebhook(post(body, { ...h, 'user-agent': 'GG', cookie: 'c=1', 'x-api-key': 'k' }), { secret: SECRET, rpc });
    assert.equal(r.status, 200, JSON.stringify(h));
  }
  assert.equal(calls.length, 4);
  for (const a of calls) {
    assert.deepEqual(Object.keys(a.p_headers).sort(), ['content-type', 'user-agent']);
    assert.doesNotMatch(JSON.stringify(a), new RegExp(SECRET));
  }
});

test('HTTP: tamanho máximo (declarado e real), JSON inválido, banco fora → 500 (a GGCheckout reenvia)', async () => {
  const rpc = async () => ({ status: 200, body: { accepted: true } });
  const big = JSON.stringify({ event: 'pix.paid', pad: 'x'.repeat(70 * 1024) });
  assert.equal((await handleGgWebhook(post(big, bearer), { secret: SECRET, rpc })).status, 413);
  const lying = new Request('https://x/f', { method: 'POST', body: big, headers: { ...bearer, 'content-length': '10' } });
  assert.equal((await handleGgWebhook(lying, { secret: SECRET, rpc })).status, 413);
  assert.equal((await handleGgWebhook(post('{nao é json', bearer), { secret: SECRET, rpc })).status, 400);
  assert.equal((await handleGgWebhook(post('[1,2]', bearer), { secret: SECRET, rpc })).status, 400);
  assert.equal((await handleGgWebhook(post({ event: 'pix.paid' }, bearer), { secret: SECRET, rpc: async () => { throw new Error('x'); } })).status, 500);
  assert.equal((await handleGgWebhook(post({ event: 'pix.paid' }, bearer), { secret: SECRET, rpc: async () => ({ status: 503, body: null }) })).status, 500);
});

test('HTTP: logs nunca contêm corpo, telefone, e-mail ou segredo', async () => {
  const db = await setup();
  const lines = [];
  for (const h of [bearer, { authorization: 'Bearer errado' }]) {
    await handleGgWebhook(post(payload('pix.generated', 'L1', { phone: INTERNAL.slice(1) }), h), { secret: SECRET, rpc: dbRpc(db), log: (l) => lines.push(l) });
  }
  const all = lines.join('\n');
  assert.ok(lines.length >= 2);
  assert.doesNotMatch(all, /Maria|maria@|5511|PIXL1|segredo/);
});

// ─── Ponta a ponta com o banco (0010) ────────────────────────────────────────
test('Só internos: cliente real é descartado sem dado pessoal; checkout de teste e telefone interno entram e processam', async () => {
  const db = await setup();
  const deps = { secret: SECRET, rpc: dbRpc(db) };
  const real = await handleGgWebhook(post(payload('pix.generated', 'R1'), bearer), deps);
  assert.equal(real.status, 200);
  assert.equal((await real.json()).ignored, true);
  assert.equal((await one(db, `select count(*)::int n from webhook_inbox`)).n, 0);
  assert.equal((await one(db, `select count(*)::int n from contacts`)).n, 0);
  const ev = await one(db, `select payload from events where type = 'gg.ignored_internal_only'`);
  assert.deepEqual(ev.payload, { event: 'pix.generated', checkout_id: 'dDTs0BWHlGqWRdqhQakS' });

  assert.equal((await handleGgWebhook(post(payload('pix.generated', 'T1', { checkoutId: TEST_CHECKOUT, phone: '5511977776666' }), bearer), deps)).status, 200);
  assert.equal((await handleGgWebhook(post(payload('pix.generated', 'I1', { phone: INTERNAL.slice(1) }), bearer), deps)).status, 200);
  const rows = await db.query(`select o.external_id, o.is_internal_test, c.is_internal_test ci, w.processed_at is not null p
                                 from orders o join contacts c on c.id = o.contact_id join webhook_inbox w on w.payload #>> '{payment,id}' = o.external_id
                                order by 1`);
  assert.deepEqual(rows.rows.map((r) => [r.external_id, r.is_internal_test, r.ci, r.p]), [['I1', true, true, true], ['T1', true, false, true]]);
  assert.equal((await one(db, `select count(*)::int n from enrollments`)).n, 1, 'régua só para o contato interno');
});

test('Duplicado é idempotente; modo live aceita cliente real; pagamento processa na hora e para a régua', async () => {
  const db = await setup();
  const deps = { secret: SECRET, rpc: dbRpc(db) };
  const p = payload('pix.generated', 'I2', { phone: INTERNAL.slice(1) });
  for (let i = 0; i < 3; i++) assert.equal((await handleGgWebhook(post(p, bearer), deps)).status, 200);
  assert.equal((await one(db, `select count(*)::int n from webhook_inbox`)).n, 1);
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions where status = 'pending'`)).n, 4);
  await handleGgWebhook(post(payload('pix.paid', 'I2', { phone: INTERNAL.slice(1) }), bearer), deps);
  assert.equal((await one(db, `select status from orders where external_id = 'I2'`)).status, 'paid');
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions where status = 'pending'`)).n, 0);

  await db.exec(`update settings set value = '"live"' where key = 'engine_mode'`);
  assert.equal((await handleGgWebhook(post(payload('pix.generated', 'R2'), bearer), deps)).status, 200);
  assert.ok(await one(db, `select 1 x from orders where external_id = 'R2'`));
});

test('Limite por minuto: excedente → 429 + alerta crítico (deduplicado); payload sem id → 400', async () => {
  const db = await setup();
  await db.exec(`update settings set value = '3' where key = 'gg_webhook_rate_per_minute'`);
  const deps = { secret: SECRET, rpc: dbRpc(db) };
  const codes = [];
  for (let i = 0; i < 5; i++) codes.push((await handleGgWebhook(post(payload('pix.generated', 'Q' + i, { checkoutId: TEST_CHECKOUT }), bearer), deps)).status);
  assert.deepEqual(codes, [200, 200, 200, 429, 429]);
  assert.equal((await one(db, `select count(*)::int n from alerts where kind = 'gg_webhook_rate_limited'`)).n, 1);
  assert.equal((await handleGgWebhook(post({ event: 'pix.paid', checkoutId: TEST_CHECKOUT }, bearer), deps)).status, 400);
});

test('Permissões: só service_role executa ingest_gg_webhook (n8n_engine não)', async () => {
  const db = await setup();
  await db.exec('set role n8n_engine');
  await assert.rejects(db.query(`select public.ingest_gg_webhook('{}'::jsonb, '{}'::jsonb)`), /permission denied/);
  await db.exec('reset role');
});
