#!/usr/bin/env node
// INFORUAN — testa a Edge Function gg-webhook PUBLICADA, sem gravar nenhum dado pessoal.
// Usa um pedido FICTÍCIO de "cliente real" (checkout normal, telefone inexistente): no modo só internos
// ele deve ser autenticado e DESCARTADO pelo banco (fica só um evento de contagem, sem dados pessoais).
// Lê o segredo do Keychain e nunca o exibe. Só imprime OK/FALHA.
// Uso: node ops/testar-gg-webhook.mjs
import { spawnSync } from 'node:child_process';
import { createHmac } from 'node:crypto';

const URL_FN = 'https://bsmuouivezjnfrcnamky.supabase.co/functions/v1/gg-webhook';
const kc = spawnSync('security', ['find-generic-password', '-s', 'inforuan-gg-webhook-secret', '-a', 'gg-webhook', '-w'], { encoding: 'utf8' });
if (kc.status !== 0) { console.error('Segredo não encontrado no Keychain. Rode antes: node ops/gerar-segredo-gg-webhook.mjs'); process.exit(2); }
const secret = kc.stdout.trim();

let failures = 0;
const check = (label, cond, extra = '') => { if (!cond) failures++; console.log(`${cond ? 'OK   ' : 'FALHA'}  ${label}${extra ? ` (${extra})` : ''}`); };
const stamp = Date.now();
const fake = (n) => JSON.stringify({
  event: 'pix.generated', createdAt: new Date().toISOString(), checkoutId: 'dDTs0BWHlGqWRdqhQakS',
  customer: { name: 'Teste Ficticio', email: 'teste@example.invalid', phone: '5511000000000' },
  payment: { id: `TESTE-EDGE-${stamp}-${n}`, paymentMethod: 'pix', status: 'pending', amount: 0 },
});
const send = async (body, headers = {}, method = 'POST') => {
  const r = await fetch(URL_FN, { method, headers: { 'content-type': 'application/json', ...headers }, body: method === 'POST' ? body : undefined });
  let j = null; try { j = await r.json(); } catch {}
  return { status: r.status, body: j };
};

const g = await send(null, {}, 'GET');
check('GET recusado', g.status === 405, `HTTP ${g.status}`);
const n = await send(fake(0));
check('Sem segredo → 401', n.status === 401, `HTTP ${n.status}`);
const w = await send(fake(0), { authorization: 'Bearer segredo-errado-mas-comprido-o-suficiente' });
check('Segredo errado → 401', w.status === 401, `HTTP ${w.status}`);
const s = await send(fake(0), { 'x-webhook-signature': 'sha256=' + '0'.repeat(64) });
check('Assinatura HMAC errada → 401', s.status === 401, `HTTP ${s.status}`);
const big = await send(JSON.stringify({ pad: 'x'.repeat(70 * 1024) }), { authorization: `Bearer ${secret}` });
check('Corpo acima de 64 KB → 413', big.status === 413, `HTTP ${big.status}`);
const b = await send(fake(1), { authorization: `Bearer ${secret}` });
check('Bearer correto → 200 e descartado (só internos)', b.status === 200 && b.body?.ignored === true, `HTTP ${b.status} ${JSON.stringify(b.body)}`);
const body2 = fake(2);
const h = await send(body2, { 'x-webhook-signature': 'sha256=' + createHmac('sha256', secret).update(body2).digest('hex') });
check('HMAC correto → 200 e descartado (só internos)', h.status === 200 && h.body?.ignored === true, `HTTP ${h.status} ${JSON.stringify(h.body)}`);
if ((b.status === 200 || h.status === 200) && !(b.body?.ignored && h.body?.ignored)) console.log('ATENÇÃO: o motor NÃO está em modo só internos. Pare e avise.');
console.log(failures === 0 ? '\nRESULTADO: TUDO OK' : `\nRESULTADO: ${failures} FALHA(S)`);
process.exit(failures === 0 ? 0 : 1);
