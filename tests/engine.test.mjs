// Testes das regras críticas do motor, rodando o SQL real num Postgres embutido (PGlite).
// Rodar: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('..', import.meta.url).pathname;
const SQL = ['supabase/migrations/0001_core.sql', 'supabase/migrations/0002_functions.sql', 'supabase/migrations/0003_views.sql', 'supabase/migrations/0004_hardening.sql', 'supabase/migrations/0005_fk_indexes.sql', 'supabase/migrations/0006_api_interface.sql', 'supabase/seed/0001_config.sql', 'supabase/migrations/0007_modo_interno.sql', 'supabase/migrations/0009_n8n_engine_limites.sql', 'supabase/migrations/0010_ingestao_gg.sql', 'supabase/migrations/0011_whatsapp_evolution.sql']
  .map((f) => readFileSync(root + f, 'utf8'));

const T0 = new Date('2026-10-02T13:00:00Z'); // 10:00 em São Paulo
const at = (min) => new Date(T0.getTime() + min * 60000).toISOString();
const PHONE = '+5511988887777';
const INTERNAL = '+5511900000001';

async function setup({ holdout = 10, mode = 'live' } = {}) {
  const db = new PGlite();
  for (const s of SQL) await db.exec(s);
  await db.exec(`
    update sequences set active = true;
    update experiments set holdout_pct = ${holdout}, salt = 'salt-fixo-de-teste';
    insert into provider_instances(workspace_id, provider, instance_name, state, paused, pause_reason, rate_per_minute, min_gap_seconds, daily_cap, last_health_check_at)
      values (ws_id('inforuan'), 'evolution', 'inforuan-01', 'open', false, null, 4, 12, 150, now())
      on conflict (instance_name) do update set state = 'open', paused = false, pause_reason = null, active = true,
        rate_per_minute = 4, min_gap_seconds = 12, daily_cap = 150, last_health_check_at = now();
    update catalog_products set access_url = 'https://drive.example/acesso-' || external_product_id;
    update catalog_checkouts set public_url = 'https://pay.example/' || external_checkout_id;
    update settings set value = '["${INTERNAL}"]' where key = 'internal_test_phones';
    update settings set value = '"${mode}"' where key = 'engine_mode';`);
  return db;
}

const one = async (db, sql, params = []) => (await db.query(sql, params)).rows[0];
const all = async (db, sql, params = []) => (await db.query(sql, params)).rows;

function ggPayload(event, id, { phone = PHONE, name = 'Maria da Silva', createdAt = at(0), amount = 37, checkoutId = 'dDTs0BWHlGqWRdqhQakS', bump = false } = {}) {
  const paymentMethod = event.startsWith('card') ? 'credit_card' : 'pix';
  const status = event.endsWith('paid') ? 'paid' : event.endsWith('refunded') ? 'refunded' : event.endsWith('expired') ? 'expired' : 'pending';
  return {
    event, createdAt, checkoutId,
    customer: { name, email: 'maria@example.com', phone: phone.replace('+', ''), document: '000' },
    payment: { id, method: event, paymentMethod, gateway: 'mercadopago', status, amount, pixCode: '00020126PIXCODE' + id },
    product: { id: 'EuwGEZ2vDJI3ACa8j4uE', type: 'main', title: 'Kit Completo Atualiza 40+' },
    products: [{ id: 'EuwGEZ2vDJI3ACa8j4uE', type: 'main', title: 'Kit Completo Atualiza 40+' },
      ...(bump ? [{ id: 'HqtdipMc47d166ZED2zA', type: 'orderbump', title: 'Fotos IA', price: 990 }] : [])],
    utm_source: 'FB', utm_campaign: 'teste|123',
  };
}

async function gg(db, event, id, opts = {}, nowMin = 0) {
  const p = ggPayload(event, id, opts);
  await db.query(`select ingest_webhook('inforuan','ggcheckout',$1,$2,$3,$4)`,
    [`${event}|${id}|${p.payment.status}`, event, { 'content-type': 'application/json', 'x-secret': 'NUNCA-GRAVAR' }, p]);
  return (await one(db, `select process_pending_inbox(50, $1) r`, [at(nowMin)])).r;
}

async function evo(db, payload, nowMin) {
  const key = `${payload.event}|${payload.data?.key?.id ?? payload.data?.keyId ?? JSON.stringify(payload.data)}`;
  await db.query(`select ingest_webhook('inforuan','evolution',$1,$2,'{}',$3)`, [key, payload.event, { ...payload, apikey: 'NUNCA-GRAVAR' }]);
  return (await one(db, `select process_pending_inbox(50, $1) r`, [at(nowMin)])).r;
}
const inbound = (id, text, { phone = PHONE, type = 'conversation', fromMe = false } = {}) => ({
  event: 'messages.upsert', instance: 'inforuan-01',
  data: { key: { remoteJid: phone.replace('+', '') + '@s.whatsapp.net', fromMe, id }, pushName: 'Maria',
    message: type === 'conversation' ? { conversation: text } : { [type]: { caption: text } }, messageType: type,
    messageTimestamp: Math.floor(T0.getTime() / 1000) },
});

const dispatch = (db, min) => one(db, `select dispatch_due_actions('inforuan', 100, $1) r`, [at(min)]);
const claim = (db, min) => all(db, `select * from claim_outbound('inforuan-01', 1, $1)`, [at(min)]);
const sendOk = (db, id, pmid, min) => one(db, `select mark_outbound_result($1, true, $2, null, false, false, $3) r`, [id, pmid, at(min)]);
async function drainSend(db, min) { // simula o worker: reserva e "envia" tudo o que puder neste minuto
  const sent = [];
  for (let s = 0; s < 60; s += 13) {
    const t = min + s / 60;
    const rows = await all(db, `select * from claim_outbound('inforuan-01', 1, $1)`, [at(t)]);
    for (const r of rows) { await sendOk(db, r.id, 'PM-' + r.id.slice(0, 8), t); sent.push(r); }
  }
  return sent;
}
const armOf = async (db, phone = PHONE) =>
  (await one(db, `select a.arm from experiment_assignments a join contacts c on c.id = a.contact_id where c.phone_e164 = $1`, [phone]))?.arm;

// ─────────────────────────────────────────────────────────────────────────────
test('Pix gerado → matrícula + 4 passos agendados (tratamento); segredos não são gravados', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  const acts = await all(db, `select sa.due_at, st.position from scheduled_actions sa join sequence_steps st on st.id = sa.step_id order by st.position`);
  assert.equal(acts.length, 4);
  assert.equal(new Date(acts[0].due_at).toISOString(), at(6));
  assert.equal(new Date(acts[1].due_at).toISOString(), at(20));
  const inbox = await one(db, `select headers, payload from webhook_inbox`);
  assert.equal(inbox.headers['x-secret'], undefined, 'segredo não pode ser persistido');
  const o = await one(db, `select status, amount_cents, payment_method from orders`);
  assert.deepEqual(o, { status: 'pending', amount_cents: 3700, payment_method: 'pix' });
});

test('PAGOU → cancela a régua na hora e agenda pós-venda; nenhuma cobrança chega a quem pagou', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await gg(db, 'pix.paid', 'P1', {}, 2);
  const pend = await one(db, `select count(*)::int n from scheduled_actions where status = 'pending'`);
  assert.equal(pend.n, 0);
  await dispatch(db, 30);
  const out = await all(db, `select purpose, template_key from outbound_messages`);
  assert.deepEqual(out.map((o) => o.template_key), ['pos_compra_acesso']);
  assert.match((await one(db, `select rendered_body from outbound_messages`)).rendered_body, /acesso-EuwGEZ2vDJI3ACa8j4uE/);
});

test('Cobrança já na fila é barrada no envio se o pagamento chegar antes (guard do claim)', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await dispatch(db, 6);                                             // passo 1 vai para a fila
  assert.equal((await one(db, `select count(*)::int n from outbound_messages where status='queued'`)).n, 1);
  await db.query(`update orders set status = 'paid', paid_at = $1`, [at(7)]); // pagamento sem passar pelas regras (pior caso)
  const got = await claim(db, 7);
  assert.equal(got.length, 0);
  assert.equal((await one(db, `select status, status_reason from outbound_messages`)).status_reason, 'paid');
});

test('Webhook duplicado e fora de ordem: idempotente e monotônico', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await gg(db, 'pix.generated', 'P1');               // retentativa da GGCheckout
  await gg(db, 'pix.paid', 'P1', {}, 3);
  await gg(db, 'pix.expired', 'P1', {}, 16);         // chega atrasado
  assert.equal((await one(db, `select count(*)::int n from webhook_inbox`)).n, 3);
  assert.equal((await one(db, `select status from orders`)).status, 'paid');
  assert.equal((await one(db, `select count(*)::int n from enrollments`)).n, 1);
  assert.equal((await one(db, `select count(*)::int n from outbound_messages where purpose='post_purchase'`)).n, 1);
});

test('Pagamento que chega ANTES do "gerado" não cria régua', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.paid', 'P9');
  await gg(db, 'pix.generated', 'P9');
  assert.equal((await one(db, `select count(*)::int n from enrollments`)).n, 0);
  assert.equal((await one(db, `select status from orders`)).status, 'paid');
});

test('Régua completa quando ninguém paga: 4 mensagens, janela de horário respeitada', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  const sent = [];
  for (const m of [6, 20, 180, 1440]) { await dispatch(db, m); sent.push(...(await drainSend(db, m))); }
  assert.deepEqual(sent.map((s) => s.template_key), ['pix_ativo', 'pix_novo_link', 'pix_lembrete_3h', 'pix_ultimo_24h']);
  assert.match(sent[1].rendered_body, /https:\/\/pay\.example\/dDTs0BWHlGqWRdqhQakS/);
  assert.equal((await one(db, `select status from enrollments`)).status, 'completed');
});

test('Pedido às 23h: passos 3 e 4 respeitam a janela 08–21h', async () => {
  const db = await setup({ holdout: 0 });
  const late = '2026-10-03T02:00:00Z'; // 23:00 em SP
  await gg(db, 'pix.generated', 'P1', { createdAt: late });
  const acts = await all(db, `select st.position, sa.due_at from scheduled_actions sa join sequence_steps st on st.id=sa.step_id order by 1`);
  const sp = (d) => new Date(d).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', hour: '2-digit', minute: '2-digit' });
  assert.equal(sp(acts[0].due_at), '23:06');  // passos imediatos não esperam a janela
  assert.equal(sp(acts[2].due_at), '08:00');  // T+3h = 02:00 → 08:00
});

test('Holdout 10%: aleatório, estável e registrado; controle não recebe régua mas recebe pós-venda', async () => {
  const db = await setup({ holdout: 10 });
  const phones = Array.from({ length: 60 }, (_, i) => '+55119' + String(70000000 + i).padStart(8, '0'));
  for (const [i, ph] of phones.entries()) await gg(db, 'pix.generated', 'H' + i, { phone: ph });
  const ctlRow = await one(db, `select c.phone_e164 ph from experiment_assignments a join contacts c on c.id=a.contact_id where a.arm='control' limit 1`);
  assert.ok(ctlRow, 'algum contato caiu no controle');
  const ctl = ctlRow.ph;
  const enr = await one(db, `select e.id, e.arm from enrollments e join contacts c on c.id=e.contact_id where c.phone_e164=$1`, [ctl]);
  assert.equal(enr.arm, 'control');
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions where enrollment_id=$1`, [enr.id])).n, 0);
  assert.ok((await one(db, `select count(*)::int n from scheduled_actions`)).n > 0, 'tratados têm régua');
  await gg(db, 'pix.generated', 'C2', { phone: ctl }, 60);      // novo Pix do mesmo contato: mesmo braço
  assert.equal((await one(db, `select count(distinct e.arm)::int n from enrollments e join contacts c on c.id=e.contact_id where c.phone_e164=$1`, [ctl])).n, 1);
  await gg(db, 'pix.paid', 'C2', { phone: ctl }, 70);
  assert.equal((await one(db, `select count(*)::int n from outbound_messages o join contacts c on c.id=o.contact_id where c.phone_e164=$1 and o.purpose='post_purchase'`, [ctl])).n, 1);

  // distribuição em 2.000 contatos
  const r = await one(db, `
    with cs as (insert into contacts(workspace_id, phone_e164)
                select ws_id('inforuan'), '+5521' || lpad(g::text, 9, '0') from generate_series(1, 2000) g returning id)
    select avg((assign_arm((select id from experiments), id) = 'control')::int)::float p from cs`);
  assert.ok(r.p > 0.08 && r.p < 0.12, 'proporção de controle ~10%: ' + r.p);
});

test('Contato interno: sempre tratamento, marcado para exclusão das métricas', async () => {
  const db = await setup({ holdout: 100 });   // mesmo com 100% de controle
  await gg(db, 'pix.generated', 'I1', { phone: INTERNAL });
  assert.equal(await armOf(db, INTERNAL), 'treatment');
  assert.equal((await one(db, `select is_internal_test from orders`)).is_internal_test, true);
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions`)).n, 4);
});

test('Instância desconectada pausa a fila; reconexão retoma e mensagem vencida expira', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await dispatch(db, 6);
  await evo(db, { event: 'connection.update', instance: 'inforuan-01', data: { state: 'close' } }, 6);
  assert.equal((await claim(db, 7)).length, 0);
  assert.ok(await one(db, `select 1 x from alerts where kind='instance_disconnected'`));
  await evo(db, { event: 'connection.update', instance: 'inforuan-01', data: { state: 'open' } }, 30);
  assert.equal((await claim(db, 30)).length, 0);                    // "Pix ainda válido" venceu (TTL 8 min)
  assert.equal((await one(db, `select status from outbound_messages`)).status, 'expired');
});

test('Limites configuráveis: intervalo mínimo e teto por minuto', async () => {
  const db = await setup({ holdout: 0 });
  for (let i = 0; i < 5; i++) await gg(db, 'pix.generated', 'L' + i, { phone: '+55119555500' + String(10 + i) });
  await dispatch(db, 6);
  await db.exec(`update provider_instances set min_gap_seconds = 0, rate_per_minute = 2`);
  assert.equal((await claim(db, 7)).length, 1);
  assert.equal((await claim(db, 7.1)).length, 1);
  assert.equal((await claim(db, 7.2)).length, 0, 'teto de 2/min');
  await db.exec(`update provider_instances set min_gap_seconds = 30, rate_per_minute = 10`);
  assert.equal((await claim(db, 8.5)).length, 1);
  assert.equal((await claim(db, 8.6)).length, 0, 'intervalo mínimo de 30s');
});

test('Idempotência do enfileiramento e whitelist de propósito (sem disparo para a base)', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  const cid = (await one(db, `select id from contacts`)).id;
  const a = await one(db, `select enqueue_message(ws_id('inforuan'), $1, 'support', 'ia_resposta', '{"texto":"x"}', 'k1') id`, [cid]);
  const b = await one(db, `select enqueue_message(ws_id('inforuan'), $1, 'support', 'ia_resposta', '{"texto":"x"}', 'k1') id`, [cid]);
  assert.ok(a.id);
  assert.equal(a.id, b.id, 'mesma chave de idempotência → mesma mensagem');
  assert.equal((await one(db, `select count(*)::int n from outbound_messages where idempotency_key='k1'`)).n, 1);
  await assert.rejects(db.query(`select enqueue_message(ws_id('inforuan'), $1, 'support', 'handoff_aberto', '{}', 'k9')`, [cid]), /template_purpose_mismatch/);
  await assert.rejects(db.query(`select enqueue_message(ws_id('inforuan'), $1, 'broadcast', 'ia_resposta', '{"texto":"x"}', 'k2')`, [cid]), /purpose_not_allowed/);
  const cold = (await one(db, `insert into contacts(workspace_id, phone_e164) values (ws_id('inforuan'), '+5511911112222') returning id`)).id;
  await assert.rejects(db.query(`select enqueue_message(ws_id('inforuan'), $1, 'support', 'ia_resposta', '{"texto":"x"}', 'k3')`, [cold]), /no_transactional_link/);
});

test('Resposta do cliente pausa a régua e vai para a IA (com debounce)', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  const r = await evo(db, inbound('IN1', 'como faço pra pagar?'), 8);
  assert.equal(r.processed, 1);
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions where status='pending'`)).n, 0);
  assert.equal((await all(db, `select * from claim_ai_work('inforuan', 20, 5, $1)`, [at(8.1)])).length, 0, 'debounce');
  const work = await all(db, `select claim_ai_work r from claim_ai_work('inforuan', 20, 5, $1)`, [at(9)]);
  assert.equal(work.length, 1);
  assert.equal(work[0].r.pending[0].text, 'como faço pra pagar?');
  assert.equal(work[0].r.orders[0].status, 'pending');
});

test('Opt-out por palavra-chave suprime tudo e confirma uma vez', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await dispatch(db, 6);
  await evo(db, inbound('IN1', 'PARAR'), 7);
  assert.ok((await one(db, `select opted_out_at from contacts`)).opted_out_at);
  const out = await all(db, `select template_key, status from outbound_messages order by queued_at`);
  assert.deepEqual(out.map((o) => [o.template_key, o.status]), [['pix_ativo', 'cancelled'], ['opt_out_confirmacao', 'queued']]);
  await gg(db, 'pix.generated', 'P2', {}, 60);
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions where status='pending'`)).n, 0);
});

test('Resposta humana pelo celular (eco fromMe sem outbox) → handoff explícito; IA silencia; liberação manual', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await evo(db, inbound('IN1', 'oi'), 8);
  await evo(db, inbound('HUM1', 'Oi Maria, aqui é a Ana!', { fromMe: true }), 8.5);
  const h = await one(db, `select status, origin, expires_at from handoffs`);
  assert.equal(h.origin, 'human_reply_detected');
  assert.equal(h.status, 'open');
  assert.equal((await all(db, `select * from claim_ai_work('inforuan', 0, 5, $1)`, [at(9)])).length, 0);
  const r = await evo(db, inbound('IN2', 'obrigada'), 9);
  assert.equal(r.processed, 1);
  assert.equal((await one(db, `select ai_pending_since from conversations`)).ai_pending_since, null, 'em modo humano a IA não entra');
  assert.equal((await one(db, `select release_handoff('inforuan', $1, 'ana', $2) n`, [PHONE, at(10)])).n, 1);
  assert.equal((await one(db, `select contact_in_human_mode(id, $1) m from contacts`, [at(10)])).m, false);
});

test('Eco do próprio motor NÃO vira handoff (casamento por id e por conteúdo)', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await dispatch(db, 6);
  const [m] = await claim(db, 6);
  // eco chega ANTES do adapter devolver o id
  await evo(db, inbound('EVO-ID-1', m.rendered_body, { fromMe: true }), 6.05);
  assert.equal((await one(db, `select count(*)::int n from handoffs`)).n, 0);
  assert.equal((await one(db, `select status, provider_message_id from outbound_messages`)).provider_message_id, 'EVO-ID-1');
  await sendOk(db, m.id, 'EVO-ID-1', 6.1);
  await evo(db, { event: 'messages.update', instance: 'inforuan-01', data: { keyId: 'EVO-ID-1', status: 'READ' } }, 7);
  assert.equal((await one(db, `select status from outbound_messages`)).status, 'read');
});

test('Handoff: 10h abre e alerta; 22h vai para fila e é promovido às 9h com resumo', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  const cid = (await one(db, `select id from contacts`)).id;
  const h1 = await one(db, `select (start_handoff(ws_id('inforuan'), $1, 'pediu humano', 'ai', null, $2)).status s`, [cid, at(0)]);
  assert.equal(h1.s, 'open');
  assert.ok(await one(db, `select 1 x from alerts where kind='handoff_open'`));
  await db.query(`select release_handoff('inforuan', $1, 'x', $2)`, [PHONE, at(1)]);
  const night = '2026-10-03T01:00:00Z'; // 22h SP
  const h2 = await one(db, `select (start_handoff(ws_id('inforuan'), $1, 'reembolso', 'ai', null, $2)).status s`, [cid, night]);
  assert.equal(h2.s, 'queued');
  const r = await one(db, `select handoff_housekeeping('inforuan', '2026-10-03T12:01:00Z') r`); // 09:01 SP
  assert.equal(r.r.promoted, 1);
  assert.ok(await one(db, `select 1 x from alerts where kind='handoff_queue_digest'`));
});

test('Resultado da IA: guardrail força handoff sem artigo aprovado; resposta válida vai para a fila', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await evo(db, inbound('IN1', 'qual o prazo de garantia?'), 8);
  const cid = (await one(db, `select id from contacts`)).id;
  const inId = (await one(db, `select id from messages where direction='in'`)).id;
  const r1 = await one(db, `select record_ai_result('inforuan', $1, array[$2::uuid], 'reply', 'São 30 dias!', array['inventado'], null, 'm', 'end_turn', 1, 1, 1, $3) r`, [cid, inId, at(9)]);
  assert.equal(r1.r.decision, 'handoff', 'artigo inexistente → humano');
  await db.query(`select release_handoff('inforuan', $1, 'x', $2)`, [PHONE, at(10)]);
  await db.exec(`insert into kb_articles(workspace_id, slug, title, answer, approved_by, active) values (ws_id('inforuan'), 'garantia', 'Garantia', '7 dias', 'ruan', true)`);
  const r2 = await one(db, `select record_ai_result('inforuan', $1, array[$2::uuid], 'reply', 'A garantia é de 7 dias.', array['garantia'], null, 'm', 'end_turn', 1, 1, 1, $3) r`, [cid, inId, at(11)]);
  assert.equal(r2.r.decision, 'reply');
  assert.ok(await one(db, `select 1 x from outbound_messages where template_key='ia_resposta' and rendered_body='A garantia é de 7 dias.'`));
});

test('Mensagem não-texto (áudio/comprovante) → humano', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.paid', 'P1');
  const r = await evo(db, { ...inbound('IMG1', null, { type: 'imageMessage' }), }, 5);
  assert.equal(r.processed, 1);
  assert.equal((await one(db, `select origin from handoffs`)).origin, 'non_text_message');
  assert.ok(await one(db, `select 1 x from outbound_messages where template_key='handoff_aberto'`));
});

test('Rajada de erros pausa a instância; resultado incerto não reenvia às cegas', async () => {
  const db = await setup({ holdout: 0 });
  for (let i = 0; i < 4; i++) await gg(db, 'pix.generated', 'E' + i, { phone: '+55119666600' + String(10 + i) });
  await dispatch(db, 6);
  await db.exec(`update provider_instances set min_gap_seconds = 0, rate_per_minute = 100`);
  const [u] = await claim(db, 6);
  await db.query(`select mark_outbound_result($1, false, null, 'timeout', true, true, $2)`, [u.id, at(6)]);
  assert.equal((await one(db, `select status from outbound_messages where id=$1`, [u.id])).status, 'uncertain');
  for (const t of [6.1, 6.2]) {
    const [m] = await claim(db, t);
    await db.query(`select mark_outbound_result($1, false, null, '500', true, false, $2)`, [m.id, at(t)]);
  }
  assert.equal((await one(db, `select paused, pause_reason from provider_instances where instance_name = 'inforuan-01'`)).pause_reason, 'error_burst');
  assert.equal((await claim(db, 6.3)).length, 0);
});

test('Reconciliação corrige pagamento cujo webhook se perdeu', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  const r = await one(db, `select reconcile_gg_payment('inforuan', 'P1', 'paid', $1, $1) r`, [at(3)]);
  assert.equal(r.r, 'updated');
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions where status='pending'`)).n, 0);
  assert.equal((await one(db, `select count(*)::int n from outbound_messages where purpose='post_purchase'`)).n, 1);
});

test('Reembolso manual bloqueia ofertas e registra evento', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.paid', 'P1');
  assert.equal((await one(db, `select register_manual_refund('inforuan', 'P1', 'ruan', $1) r`, [at(60)])).r, 'refunded');
  assert.ok((await one(db, `select commercial_blocked_at from contacts`)).commercial_blocked_at);
  assert.ok(await one(db, `select 1 x from events where type='order.refunded' and source='manual:ruan'`));
});

test('Sem link de checkout cadastrado: passos com link são pulados e há alerta (nunca manda link quebrado)', async () => {
  const db = await setup({ holdout: 0 });
  await db.exec(`update catalog_checkouts set public_url = null`);
  await gg(db, 'pix.generated', 'P1');
  await dispatch(db, 20);
  const out = await all(db, `select template_key from outbound_messages`);
  assert.deepEqual(out.map((o) => o.template_key), ['pix_ativo']);
  assert.ok(await one(db, `select 1 x from alerts where kind='missing_checkout_url'`));
});

test('Medição do holdout por intenção de tratar (só janelas encerradas; pagos antes de T+6 ficam fora)', async () => {
  const db = await setup({ holdout: 50 });
  const base = '2026-09-01T13:00:00Z'; // janelas de 72h já encerradas
  const phones = Array.from({ length: 40 }, (_, i) => '+55118' + String(80000000 + i).padStart(8, '0'));
  for (const [i, ph] of phones.entries()) await gg(db, 'pix.generated', 'M' + i, { phone: ph, createdAt: base });
  await gg(db, 'pix.generated', 'FAST', { phone: '+5511877770000', createdAt: base });
  await gg(db, 'pix.paid', 'FAST', { phone: '+5511877770000', createdAt: '2026-09-01T13:02:00Z' });  // pagou em 2 min: não elegível
  // metade dos tratados paga em 1h
  const treated = await all(db, `select c.phone_e164 ph, e.order_id from enrollments e join contacts c on c.id=e.contact_id where e.arm='treatment' and c.phone_e164 <> '+5511877770000'`);
  for (const [i, t] of treated.entries()) if (i % 2 === 0)
    await db.query(`select apply_order_status(ws_id('inforuan'), external_id, 'paid', '2026-09-01T14:00:00Z', 'test') from orders where id=$1`, [t.order_id]);
  const rows = await all(db, `select arm, eligible_closed::int, converted::int from v_recovery_holdout order by arm`);
  const tr = rows.find((r) => r.arm === 'treatment'), ct = rows.find((r) => r.arm === 'control');
  assert.equal(tr.eligible_closed + ct.eligible_closed, 40, 'o que pagou em 2 min não entra');
  assert.equal(ct.converted, 0);
  assert.equal(tr.converted, Math.ceil(treated.length / 2));
  const lift = await one(db, `select lift_pp::float from v_recovery_lift`);
  assert.ok(lift.lift_pp > 40);
});

test('Checagem pré-envio: guard carrega o id externo; cancel_outbound e reconciliação em lote', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await dispatch(db, 6);
  const [m] = await claim(db, 6);
  assert.equal(m.guard.order_external_id, 'P1');
  const r = await one(db, `select reconcile_gg_batch('inforuan', $1, $2) r`, [[{ id: 'P1', status: 'paid', paid_at: at(6) }, { id: 'DESCONHECIDO', status: 'paid' }], at(6.1)]);
  assert.deepEqual(r.r, { updated: 1, inserted: 1 });
  await db.query(`select cancel_outbound($1, 'paid_precheck')`, [m.id]);
  assert.equal((await one(db, `select status from outbound_messages where id=$1`, [m.id])).status, 'cancelled');
  const w = await all(db, `select claim_ai_work r from claim_ai_work('inforuan', 0, 5, $1)`, [at(7)]);
  assert.equal(w.length, 0);
});

test('Interface api: n8n_engine só executa funções de api; não lê tabelas nem chama funções de public', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'P1');
  await dispatch(db, 6);
  await db.query(`update outbound_messages set next_attempt_at = now() - interval '1 minute', queued_at = now() - interval '1 minute', ttl_at = now() + interval '1 hour'`);
  await db.exec(`set role n8n_engine`);
  await assert.rejects(db.query(`select * from public.contacts`), /permission denied/);
  await assert.rejects(db.query(`select * from public.outbound_messages`), /permission denied/);
  await assert.rejects(db.query(`select public.claim_outbound('inforuan-01', 1)`), /permission denied/);
  await assert.rejects(db.query(`select * from public.v_recovery_holdout`), /permission denied/);
  const m = await one(db, `select api.claim_outbound('inforuan-01', 1) r`);
  assert.equal(m.r.template_key, 'pix_ativo');
  assert.equal((await one(db, `select api.mark_outbound_result($1, true, 'PM-1') r`, [m.r.id])).r, 'sent');
  await db.query(`select api.heartbeat('n8n', '{"v":"test"}')`);
  await db.exec(`reset role`);
  assert.ok(await one(db, `select 1 x from service_heartbeats where service = 'n8n'`));
  assert.equal((await one(db, `select status from outbound_messages`)).status, 'sent');
});

test('Retenção: JSON bruto processado com mais de 30 dias é apagado; recente fica', async () => {
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'OLD', { createdAt: '2026-08-01T13:00:00Z' });
  await db.query(`update webhook_inbox set received_at = '2026-08-01T13:00:00Z'`);
  await db.query(`update orders set updated_at = '2026-08-01T13:00:00Z'`);
  await gg(db, 'pix.generated', 'NEW');
  const r = await one(db, `select purge_retention(30, $1) r`, [at(0)]);
  assert.equal(r.r.inbox_payloads, 1);
  assert.equal(r.r.orders_raw, 1);
  const rows = await all(db, `select payload from webhook_inbox order by id`);
  assert.ok(rows[0].payload.purged_at && !rows[0].payload.customer, 'antigo sem dados pessoais');
  assert.ok(rows[1].payload.customer, 'recente intacto');
  assert.equal((await one(db, `select purge_retention(30, $1) r`, [at(0)])).r.inbox_payloads, 0, 'idempotente');
});

test('Vigia alerta quando o n8n para de mandar sinal de vida', async () => {
  const db = await setup({ holdout: 0 });
  await db.query(`select record_heartbeat('n8n', '{}', $1)`, [at(0)]);
  await db.query(`select watchdog('inforuan', $1)`, [at(10)]);
  assert.equal((await one(db, `select count(*)::int n from alerts where kind = 'n8n_heartbeat_stale'`)).n, 0);
  await db.query(`select watchdog('inforuan', $1)`, [at(20)]);
  assert.equal((await one(db, `select count(*)::int n from alerts where kind = 'n8n_heartbeat_stale'`)).n, 1);
});

// ─── 0007: modo só internos, envio simulado e tarefas de banco ──────────────
test('Só internos (padrão da 0007): cliente real não é matriculado nem sorteado; interno recebe a régua', async () => {
  const db = await setup({ holdout: 0, mode: 'internal_only' });
  await gg(db, 'pix.generated', 'R1');
  assert.equal((await one(db, `select count(*)::int n from enrollments`)).n, 0);
  assert.equal(await armOf(db), undefined, 'cliente real fora do holdout');
  await gg(db, 'pix.generated', 'I1', { phone: INTERNAL });
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions`)).n, 4);
  await dispatch(db, 6);
  const out = await all(db, `select to_phone_e164 from outbound_messages`);
  assert.deepEqual(out.map((o) => o.to_phone_e164), [INTERNAL]);
});

test('Só internos: pagamento de cliente real não enfileira pós-venda (fica registrado como suprimido)', async () => {
  const db = await setup({ holdout: 0, mode: 'internal_only' });
  await gg(db, 'pix.paid', 'R1');
  assert.equal((await one(db, `select count(*)::int n from outbound_messages`)).n, 0);
  const ev = await one(db, `select payload from events where type = 'outbound.suppressed'`);
  assert.equal(ev.payload.reason, 'internal_only');
  assert.equal(ev.payload.template, 'pos_compra_acesso');
  await gg(db, 'pix.paid', 'I1', { phone: INTERNAL });
  assert.equal((await one(db, `select count(*)::int n from outbound_messages where template_key = 'pos_compra_acesso'`)).n, 1);
});

test('Modo inválido ou ausente vale como só internos; volta de live cancela não internos já na fila', async () => {
  const db = await setup({ holdout: 0, mode: 'qualquer-coisa' });
  await gg(db, 'pix.generated', 'R0');
  assert.equal((await one(db, `select count(*)::int n from enrollments`)).n, 0);
  await db.exec(`update settings set value = '"live"' where key = 'engine_mode'`);
  await gg(db, 'pix.generated', 'R1', { phone: '+5511977776666' });
  await dispatch(db, 6);
  assert.equal((await one(db, `select count(*)::int n from outbound_messages where status = 'queued'`)).n, 1);
  await db.query(`select set_engine_mode('inforuan', 'internal_only', 'teste')`);
  assert.equal((await claim(db, 7)).length, 0);
  assert.equal((await one(db, `select status_reason from outbound_messages`)).status_reason, 'internal_only');
  await assert.rejects(db.query(`select set_engine_mode('inforuan', 'turbo', 'teste')`), /engine_mode_invalid/);
  await assert.rejects(db.query(`select set_engine_mode('inforuan', 'live', '')`), /engine_mode_requires_operator/);
  await db.query(`select set_engine_mode('inforuan', 'live', 'teste')`);
  assert.ok(await one(db, `select 1 x from alerts where kind = 'engine_mode' and severity = 'critical'`));
});

test('Envio simulado: nasce pausado, só "envia" para internos, respeita o guard de pagamento', async () => {
  const db = await setup({ holdout: 0 });                        // live: cliente real também entra na fila
  await db.exec(`update provider_instances set paused = true where instance_name = 'inforuan-01'`);
  const sim = await one(db, `select provider, paused, state from provider_instances where instance_name = 'inforuan-sim'`);
  assert.deepEqual(sim, { provider: 'simulated', paused: true, state: 'open' });
  await gg(db, 'pix.generated', 'R1');
  await gg(db, 'pix.generated', 'I1', { phone: INTERNAL });
  await dispatch(db, 6);
  assert.equal((await one(db, `select simulate_outbound('inforuan-sim', 10, $1) r`, [at(6)])).r.simulated, 0, 'pausada');
  await db.query(`select unpause_instance('inforuan-sim', 'teste')`);
  assert.equal((await one(db, `select simulate_outbound('inforuan-sim', 10, $1) r`, [at(7)])).r.simulated, 1);
  const rows = await all(db, `select to_phone_e164, status, provider, provider_message_id from outbound_messages order by to_phone_e164`);
  const real = rows.find((r) => r.to_phone_e164 === PHONE);
  const internal = rows.find((r) => r.to_phone_e164 === INTERNAL);
  assert.equal(real.status, 'queued', 'simulada nunca pega cliente real');
  assert.equal(internal.status, 'sent');
  assert.equal(internal.provider, 'simulated');
  assert.match(internal.provider_message_id, /^sim:/);
  assert.ok(await one(db, `select 1 x from messages where provider = 'simulated' and origin = 'engine'`));
  await assert.rejects(db.query(`select simulate_outbound('inforuan-01')`), /not_a_simulated_instance/);
});

test('engine_tick ponta a ponta (só internos): Pix → régua → envio simulado → pagou → pós-venda; vigia ignora a simulada', async () => {
  const db = await setup({ holdout: 0, mode: 'internal_only' });
  await db.exec(`delete from provider_instances where instance_name = 'inforuan-01'`);
  await db.query(`select unpause_instance('inforuan-sim', 'teste')`);
  const p = ggPayload('pix.generated', 'E1', { phone: INTERNAL });
  await db.query(`select ingest_webhook('inforuan','ggcheckout','e1-gen','pix.generated','{}',$1)`, [p]);
  const t0 = (await one(db, `select engine_tick('inforuan', $1) r`, [at(0)])).r;
  assert.equal(t0.inbox.processed, 1);
  assert.equal(t0.sim.simulated, 0);
  const t6 = (await one(db, `select engine_tick('inforuan', $1) r`, [at(6)])).r;
  assert.equal(t6.dispatch.enqueued, 1);
  assert.equal(t6.sim.simulated, 1);
  const paid = ggPayload('pix.paid', 'E1', { phone: INTERNAL });
  await db.query(`select ingest_webhook('inforuan','ggcheckout','e1-paid','pix.paid','{}',$1)`, [paid]);
  const t8 = (await one(db, `select engine_tick('inforuan', $1) r`, [at(8)])).r;
  assert.equal(t8.inbox.processed, 1);
  assert.equal(t8.sim.simulated, 1);
  const sent = await all(db, `select template_key from outbound_messages where status = 'sent' order by sent_at`);
  assert.deepEqual(sent.map((r) => r.template_key), ['pix_ativo', 'pos_compra_acesso']);
  assert.equal((await one(db, `select count(*)::int n from scheduled_actions where status = 'pending'`)).n, 0, 'pagamento cancelou a régua');
  assert.ok(await one(db, `select 1 x from service_heartbeats where service = 'db_tick'`));
  await db.query(`select engine_housekeeping('inforuan', $1)`, [at(30)]);
  assert.equal((await one(db, `select count(*)::int n from alerts where kind = 'health_stale'`)).n, 0);
});

test('n8n_engine não executa as funções novas de operação', async () => {
  const db = await setup({ holdout: 0 });
  await db.exec(`set role n8n_engine`);
  for (const q of [`select public.engine_tick('inforuan')`, `select public.simulate_outbound()`,
    `select public.set_engine_mode('inforuan', 'live', 'x')`, `select public.engine_housekeeping('inforuan')`]) {
    await assert.rejects(db.query(q), /permission denied/, q);
  }
  await db.exec(`reset role`);
});

test('0009: n8n_engine continua sem login, com limite de conexões e timeouts de sessão', async () => {
  const db = await setup({ holdout: 0 });
  const r = await one(db, `select rolcanlogin, rolconnlimit, (select setconfig from pg_db_role_setting s where s.setrole = r.oid) cfg
                             from pg_roles r where rolname = 'n8n_engine'`);
  assert.equal(r.rolcanlogin, false, 'login só é liberado à parte, pelo operador');
  assert.equal(r.rolconnlimit, 10);
  assert.deepEqual([...r.cfg].sort(), ['idle_in_transaction_session_timeout=60s', 'lock_timeout=5s', 'statement_timeout=15s']);
});

// ─── Etapa 4: workflows do n8n falam SÓ com a api, como n8n_engine ──────────
const loadWorkflows = async () => {
  await import('../n8n/build.mjs');                               // regenera n8n/dist (gitignored)
  const { readdirSync } = await import('node:fs');
  const d = root + 'n8n/dist/';
  return readdirSync(d).filter((f) => f.endsWith('.json')).map((f) => JSON.parse(readFileSync(d + f, 'utf8')));
};
// Mesma regra do nó Postgres v2.5+: expressão que devolve array; objeto → JSON.stringify.
const n8nParams = (n, ctx = {}) => {
  const raw = n.parameters.options?.queryReplacement;
  if (!raw) return [];
  const inner = raw.replace(/^=\{\{\s*/, '').replace(/\s*\}\}$/, '');
  const $ = (name) => ({ item: { json: ctx.nodes?.[name] ?? {} }, first: () => ({ json: ctx.nodes?.[name] ?? {} }) });
  const vals = new Function('$json', '$', `return (${inner});`)(ctx.json ?? {}, $);
  return vals.filter((v) => v !== undefined).map((v) => (typeof v === 'object' && v !== null ? JSON.stringify(v) : v));
};
const pgNode = (wfs, wfName, nodeName) => wfs.find((w) => w.name === wfName).nodes.find((n) => n.name === nodeName);

test('Workflows: IR-02/04/05/06/07/08, todos inativos, sem service_role/REST; SQL só chama funções da api', async () => {
  const wfs = await loadWorkflows();
  assert.deepEqual(wfs.map((w) => w.name).sort(), ['IR-02 Entrada WhatsApp', 'IR-04 Envio WhatsApp', 'IR-05 Atendimento IA',
    'IR-06 Alertas Telegram', 'IR-07 Saude da conexao', 'IR-08 Reconciliacao GGCheckout']);
  for (const w of wfs) {
    assert.equal(w.active, false, w.name);
    const txt = JSON.stringify(w);
    assert.doesNotMatch(txt, /supabaseApi|service_role|rest\/v1|supabase\.co/i, w.name);
    for (const n of w.nodes.filter((n) => n.type === 'n8n-nodes-base.postgres')) {
      assert.equal(n.typeVersion, 2.7);
      assert.equal(n.parameters.operation, 'executeQuery');
      assert.equal(n.credentials.postgres.name, 'INFORUAN Supabase (n8n_engine)');
      const sql = n.parameters.query;
      assert.doesNotMatch(sql, /\{\{/, 'sem expressões dentro do SQL (só $1)');
      for (const [, schema] of sql.matchAll(/\b([a-z_]+)\.[a-z_]+\s*\(/g)) assert.equal(schema, 'api', `${n.name}: ${sql}`);
      for (const [, target] of sql.matchAll(/\bfrom\s+([^\s]+)/gi)) assert.match(target, /^(api\.|\(|jsonb_array_elements_text)/, `${n.name}: from ${target}`);
    }
  }
});

test('Workflows: cada SQL roda como n8n_engine com os parâmetros que o n8n monta', async () => {
  const wfs = await loadWorkflows();
  const db = await setup({ holdout: 0 });
  await gg(db, 'pix.generated', 'W1');                             // contato real com pedido (vínculo transacional)
  await evo(db, inbound('MSG-W1', 'Como acesso meu produto?'), 0); // conversa pendente para a IA
  await db.query(`select raise_alert(ws_id('inforuan'), 'teste', 'info', 'alerta de teste', 'teste:1')`);
  const contact = (await one(db, `select id from contacts where phone_e164 = $1`, [PHONE])).id;
  const run = async (n, ctx) => { await db.exec('set role n8n_engine'); try { return (await db.query(n.parameters.query, n8nParams(n, ctx))).rows; } finally { await db.exec('reset role'); } };

  const work = await run(pgNode(wfs, 'IR-05 Atendimento IA', 'Reservar conversas prontas'));
  assert.equal(work.length, 1);
  assert.equal(work[0].r.contact_id, contact);
  assert.equal(work[0].r.pending[0].text, 'Como acesso meu produto?');

  const rec = await run(pgNode(wfs, 'IR-05 Atendimento IA', 'Registrar e enfileirar'), { json: {
    p_contact: contact, p_inbound_ids: work[0].r.pending.map((m) => m.id), p_decision: 'handoff', p_reply: null,
    p_kb_slugs: [], p_handoff_reason: 'teste', p_model: 'm', p_stop_reason: 'end_turn', p_tokens_in: 10, p_tokens_out: null, p_latency_ms: 5 } });
  assert.equal(rec[0].r.decision, 'handoff');
  assert.equal((await one(db, `select answered_by_ai_at is not null x from messages where provider_message_id = 'MSG-W1'`)).x, true);

  await run(pgNode(wfs, 'IR-06 Alertas Telegram', 'Sinal de vida do n8n'));
  assert.equal((await one(db, `select meta->>'via' v from service_heartbeats where service = 'n8n'`)).v, 'IR-06');
  const alerts = await run(pgNode(wfs, 'IR-06 Alertas Telegram', 'Reservar alertas'));
  const a = alerts.find((x) => x.r.text === 'alerta de teste').r;
  assert.equal(a.workspace_id, undefined, 'api não expõe workspace_id');
  await run(pgNode(wfs, 'IR-06 Alertas Telegram', 'Confirmar envio'), { nodes: { 'Tem alerta?': a } });
  assert.ok((await one(db, `select sent_at from alerts where id = $1`, [a.id])).sent_at);

  const rc = await run(pgNode(wfs, 'IR-08 Reconciliacao GGCheckout', 'Reconciliar em lote'),
    { json: { items: [{ id: 'W1', status: 'paid', paid_at: at(3) }, { id: 'NUNCA-VISTO', status: 'paid', paid_at: at(3) }] } });
  assert.deepEqual(rc[0].r, { updated: 1, inserted: 1 });
  assert.equal((await one(db, `select status from orders where external_id = 'W1'`)).status, 'paid');
});

// ─── 0011: entrada da Evolution (api.ingest_evolution_event) ────────────────
const evoApi = async (db, payload) => {
  await db.exec('set role n8n_engine');
  try { return (await one(db, `select api.ingest_evolution_event($1::jsonb) r`, [JSON.stringify(payload)])).r; }
  finally { await db.exec('reset role'); }
};
const statusUpd = (keyId, phone, status) => ({ event: 'messages.update', instance: 'inforuan-01',
  data: { keyId, remoteJid: phone.replace('+', '') + '@s.whatsapp.net', fromMe: true, status } });

test('0011: instância inforuan-01 nasce inativa e pausada, com limites de aquecimento', async () => {
  const db = new PGlite();
  for (const s of SQL) await db.exec(s);
  const i = await one(db, `select provider, active, paused, pause_reason, rate_per_minute, min_gap_seconds, daily_cap from provider_instances where instance_name = 'inforuan-01'`);
  assert.deepEqual(i, { provider: 'evolution', active: false, paused: true, pause_reason: 'not_activated', rate_per_minute: 2, min_gap_seconds: 30, daily_cap: 40 });
  await db.query(`select watchdog('inforuan', $1)`, [at(0)]);
  assert.equal((await one(db, `select count(*)::int n from alerts where kind = 'health_stale'`)).n, 0, 'inativa: vigia não alerta');
});

test('0011 só internos: mensagem e status de não interno descartados sem dado pessoal; interno entra; token removido', async () => {
  const db = await setup({ holdout: 0, mode: 'internal_only' });
  const r1 = await evoApi(db, { ...inbound('M-REAL', 'Oi, quero saber do meu pedido'), apikey: 'NUNCA-GRAVAR' });
  assert.deepEqual(r1, { accepted: false, reason: 'internal_only' });
  assert.equal((await evoApi(db, statusUpd('S-REAL', PHONE, 'READ'))).reason, 'internal_only');
  assert.equal((await one(db, `select count(*)::int n from webhook_inbox`)).n, 0);
  assert.equal((await one(db, `select count(*)::int n from contacts`)).n, 0);
  assert.equal((await one(db, `select count(*)::int n from message_status_events`)).n, 0);
  const ev = await all(db, `select payload from events where type = 'evo.ignored_internal_only' order by id`);
  assert.deepEqual(ev.map((e) => e.payload), [{ event: 'messages.upsert' }, { event: 'messages.update' }]);

  const r2 = await evoApi(db, { ...inbound('M-INT', 'teste interno', { phone: INTERNAL }), apikey: 'NUNCA-GRAVAR' });
  assert.deepEqual(r2, { accepted: true, duplicate: false });
  assert.deepEqual(await evoApi(db, inbound('M-INT', 'teste interno', { phone: INTERNAL })), { accepted: true, duplicate: true });
  const msg = await one(db, `select m.text, c.phone_e164 from messages m join contacts c on c.id = m.contact_id`);
  assert.deepEqual(msg, { text: 'teste interno', phone_e164: INTERNAL });
  assert.equal((await one(db, `select count(*)::int n from webhook_inbox where payload ? 'apikey'`)).n, 0, 'token nunca gravado');
  assert.equal((await one(db, `select count(*)::int n from webhook_inbox where processed_at is null`)).n, 0, 'processado na hora');
});

test('0011: instância errada e eventos inúteis recusados; conexão sempre passa e atualiza o estado; live aceita cliente real', async () => {
  const db = await setup({ holdout: 0, mode: 'internal_only' });
  assert.equal((await evoApi(db, { ...inbound('X', 'oi'), instance: 'outra-instancia' })).reason, 'wrong_instance');
  assert.equal((await evoApi(db, { event: 'qrcode.updated', instance: 'inforuan-01', data: {} })).reason, 'ignored_event');
  assert.equal((await evoApi(db, { event: 'contacts.upsert', instance: 'inforuan-01', data: [{ id: '5511@s.whatsapp.net' }] })).reason, 'ignored_event');
  assert.equal((await one(db, `select count(*)::int n from webhook_inbox`)).n, 0);
  const c = await evoApi(db, { event: 'connection.update', instance: 'inforuan-01', data: { state: 'close' } });
  assert.equal(c.accepted, true);
  assert.equal((await one(db, `select state, paused, pause_reason from provider_instances where instance_name = 'inforuan-01'`)).state, 'close');
  assert.ok(await one(db, `select 1 x from alerts where kind = 'instance_disconnected'`), 'queda de conexão alerta');
  await db.exec(`update settings set value = '"live"' where key = 'engine_mode'`);
  assert.equal((await evoApi(db, inbound('M-LIVE', 'oi'))).accepted, true);
  assert.ok(await one(db, `select 1 x from contacts where phone_e164 = $1`, [PHONE]));
});

test('0011: status de envio do motor (interno) é registrado; n8n_engine não chama as funções internas', async () => {
  const db = await setup({ holdout: 0, mode: 'internal_only' });
  await gg(db, 'pix.generated', 'I1', { phone: INTERNAL });
  await dispatch(db, 6);
  const [m] = await claim(db, 6);
  await sendOk(db, m.id, 'PM-INT-1', 6);
  assert.equal((await evoApi(db, statusUpd('PM-INT-1', INTERNAL, 'DELIVERY_ACK'))).accepted, true);
  assert.equal((await one(db, `select status from outbound_messages where id = $1`, [m.id])).status, 'delivered');
  await db.exec('set role n8n_engine');
  await assert.rejects(db.query(`select public.process_evolution_payload(ws_id('inforuan'), 1, '{}'::jsonb)`), /permission denied/);
  await assert.rejects(db.query(`select public.evo_jid_phone('x')`), /permission denied/);
  await db.exec('reset role');
});

test('Workflows WhatsApp: IR-02/04/07 rodam como n8n_engine; Evolution só com token da instância e pela rede interna', async () => {
  const wfs = await loadWorkflows();
  const all4 = JSON.stringify(wfs.find((w) => w.name === 'IR-04 Envio WhatsApp'));
  assert.match(all4, /http:\/\/evolution:8080\/message\/sendText\/inforuan-01/);
  for (const w of wfs) for (const n of w.nodes.filter((n) => /evolution:8080/.test(JSON.stringify(n.parameters))))
    assert.equal(n.credentials?.httpHeaderAuth?.name, 'Evolution INFORUAN (token da instância)', `${w.name}/${n.name}`);
  const ir02 = wfs.find((w) => w.name === 'IR-02 Entrada WhatsApp');
  assert.equal(ir02.settings.saveDataErrorExecution, 'none', 'IR-02 não guarda execução (mensagens de clientes)');
  assert.equal(wfs.find((w) => w.name === 'IR-04 Envio WhatsApp').settings.saveDataErrorExecution, 'none');

  const db = await setup({ holdout: 0, mode: 'internal_only' });
  const run = async (wf, nodeName, ctx) => { await db.exec('set role n8n_engine'); try { const n = pgNode(wfs, wf, nodeName); return (await db.query(n.parameters.query, n8nParams(n, ctx))).rows; } finally { await db.exec('reset role'); } };

  // IR-02: entrega um evento de mensagem interna ao motor
  const r = await run('IR-02 Entrada WhatsApp', 'Entregar ao motor', { json: { body: inbound('W-INT', 'oi, teste', { phone: INTERNAL }) } });
  assert.deepEqual(r[0].r, { accepted: true, duplicate: false });

  // IR-04: reserva → (pagou na checagem) reconcilia + cancela; (não pagou) registra resultado
  await gg(db, 'pix.generated', 'W4', { phone: INTERNAL });
  await db.query(`update scheduled_actions set due_at = now() - interval '1 minute' where status = 'pending' and due_at = (select min(due_at) from scheduled_actions)`);
  await db.query(`select dispatch_due_actions('inforuan', 100)`);
  await db.query(`update outbound_messages set next_attempt_at = now() - interval '1 minute', ttl_at = now() + interval '1 hour', queued_at = now()`);
  const [c] = await run('IR-04 Envio WhatsApp', 'Reservar próxima mensagem');
  assert.equal(c.r.to_phone_e164, INTERNAL);
  assert.equal(c.r.guard.order_external_id, 'W4');
  const res = await run('IR-04 Envio WhatsApp', 'Registrar resultado', { json: { p_id: c.r.id, p_ok: true, p_provider_message_id: 'EVO-1' } });
  assert.equal(res[0].r, 'sent');
  await run('IR-04 Envio WhatsApp', 'Registrar pagamento (reconciliação)', { nodes: { 'Mensagem reservada': c.r } });
  assert.equal((await one(db, `select status from orders where external_id = 'W4'`)).status, 'paid');
  await db.query(`update outbound_messages set status = 'sending' where id = $1`, [c.r.id]);
  await run('IR-04 Envio WhatsApp', 'Cancelar mensagem', { nodes: { 'Mensagem reservada': c.r } });
  assert.equal((await one(db, `select status_reason from outbound_messages where id = $1`, [c.r.id])).status_reason, 'paid_precheck');

  // IR-07: estado da conexão
  await run('IR-07 Saude da conexao', 'Atualizar estado (pausa automática)', { json: { p_instance: 'inforuan-01', p_state: 'close' } });
  assert.deepEqual(await one(db, `select state, paused, pause_reason from provider_instances where instance_name = 'inforuan-01'`),
    { state: 'close', paused: true, pause_reason: 'disconnected' });
});
