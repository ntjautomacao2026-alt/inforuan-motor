// Gera os workflows do n8n (JSON importável) a partir de config.local.json (sem segredos).
// Uso: node n8n/build.mjs  → n8n/dist/*.json   (todos exportados com active=false)
//
// O n8n fala com o motor SOMENTE pelo schema `api` (0006), com a credencial Postgres do role `n8n_engine`
// (pooler do Supabase em modo sessão, TLS verificado; doc 16). Nada de service_role, REST ou tabelas.
// Cada chamada recebe no máximo UM parâmetro ($1::jsonb), desmontado dentro do SQL.
//
// Fora daqui (decisão 05/10/2026):
//   • IR-03 Motor e a parte de banco do IR-07 → pg_cron no próprio Supabase (0008);
//   • IR-01/IR-02 (webhooks) → Edge Function do Supabase (Etapa 7);
//   • IR-04 Envio e o health check da instância → só quando o provedor de WhatsApp for escolhido.
//     Até lá, o envio de teste é o provedor `simulated` dentro do banco (0007).
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const dir = new URL('.', import.meta.url).pathname;
const cfgFile = existsSync(dir + 'config.local.json') ? 'config.local.json' : 'config.example.json';
const C = JSON.parse(readFileSync(dir + cfgFile, 'utf8'));
const SYSTEM_PROMPT = readFileSync(dir + '../prompts/atendimento-system.md', 'utf8');
if (!/^[a-z0-9_-]+$/.test(C.WS)) throw new Error('WS inválido no config');
const WS_SQL = `'${C.WS}'`;   // seguro: validado acima
// Ids das credenciais no n8n (não são segredo). Opcional: preenchidos em config.local.json depois que a credencial existir,
// para o workflow já nascer ligado a ela. Vazio = escolher a credencial no editor.
const credId = (k) => C.CRED_IDS?.[k] ?? '';

// dist/ só contém o que este gerador produz (remove workflows aposentados de gerações antigas)
mkdirSync(dir + 'dist', { recursive: true });
for (const f of readdirSync(dir + 'dist')) if (f.endsWith('.json')) rmSync(dir + 'dist/' + f);

// ─── helpers ────────────────────────────────────────────────────────────────
let x = 0;
const pos = () => [(x++ % 8) * 260, Math.floor((x - 1) / 8) * 200];
const node = (name, type, typeVersion, parameters, extra = {}) =>
  ({ id: randomUUID(), name, type, typeVersion, position: pos(), parameters, ...extra });

// Chamada à interface `api` pelo nó Postgres (v2.7). `param` é uma expressão JS cujo valor vira $1 (objeto → JSON).
const api = (name, sql, param = null, extra = {}) => node(name, 'n8n-nodes-base.postgres', 2.7, {
  resource: 'database',
  operation: 'executeQuery',
  query: sql.trim(),
  options: param ? { queryReplacement: `={{ [ ${param} ] }}` } : {},
}, { credentials: { postgres: { id: credId('postgres'), name: C.CRED_POSTGRES } }, ...extra });

const schedule = (name, seconds) => node(name, 'n8n-nodes-base.scheduleTrigger', 1.2,
  { rule: { interval: [{ field: 'seconds', secondsInterval: seconds }] } });

const code = (name, js, extra = {}) => node(name, 'n8n-nodes-base.code', 2, { jsCode: js }, extra);

export const SQL = {
  claimAiWork: `select r from api.claim_ai_work(20, 5, ${WS_SQL}) as r`,
  recordAiResult: `
select api.record_ai_result(
  (j ->> 'p_contact')::uuid,
  array(select jsonb_array_elements_text(coalesce(j -> 'p_inbound_ids', '[]'::jsonb)))::uuid[],
  j ->> 'p_decision',
  j ->> 'p_reply',
  array(select jsonb_array_elements_text(coalesce(j -> 'p_kb_slugs', '[]'::jsonb))),
  j ->> 'p_handoff_reason',
  j ->> 'p_model',
  j ->> 'p_stop_reason',
  (j ->> 'p_tokens_in')::int,
  (j ->> 'p_tokens_out')::int,
  (j ->> 'p_latency_ms')::int,
  ${WS_SQL}) as r
from (select $1::jsonb as j) as p`,
  claimAlerts: `select r from api.claim_alerts(10) as r`,
  markAlertSent: `select api.mark_alert_sent((($1::jsonb) ->> 'id')::bigint)`,
  heartbeat: `select api.heartbeat('n8n', jsonb_build_object('via', 'IR-06'))`,
  reconcileBatch: `select api.reconcile_gg_batch($1::jsonb, ${WS_SQL}) as r`,
};

function wf(name, nodes, links, { sensitive = false } = {}) {
  const connections = {};
  for (const [from, to, out = 0] of links) {
    connections[from] ??= { main: [] };
    while (connections[from].main.length <= out) connections[from].main.push([]);
    connections[from].main[out].push({ node: to, type: 'main', index: 0 });
  }
  const json = {
    name, nodes, connections, active: false,
    settings: {
      executionOrder: 'v1',
      saveManualExecutions: false,
      saveDataSuccessExecution: 'none',
      // fluxos com dados pessoais brutos não guardam execução nem em erro
      saveDataErrorExecution: sensitive ? 'none' : 'all',
      timezone: 'America/Sao_Paulo',
    },
    tags: [],
  };
  const file = dir + 'dist/' + name.replace(/[^\w-]+/g, '_') + '.json';
  writeFileSync(file, JSON.stringify(json, null, 2));
  return file;
}

// ─── IR-05 Atendimento IA ───────────────────────────────────────────────────
x = 0;
const SCHEMA = {
  type: 'object',
  properties: {
    decision: { type: 'string', enum: ['reply', 'handoff'] },
    reply: { type: 'string' },
    kb_slugs: { type: 'array', items: { type: 'string' } },
    handoff_reason: { type: 'string' },
  },
  required: ['decision', 'reply', 'kb_slugs', 'handoff_reason'],
  additionalProperties: false,
};
wf('IR-05 Atendimento IA', [
  schedule('A cada 10s', 10),
  api('Reservar conversas prontas', SQL.claimAiWork),
  code('Montar pedido à IA', `
const SYSTEM = ${JSON.stringify(SYSTEM_PROMPT)};
return $input.all().filter((it) => it.json.r?.contact_id).map((it) => {
  const w = it.json.r;
  const ctx = {
    agora: w.now_local, atendimento_humano: { horario: w.human_hours, aberto_agora: w.human_hours_open },
    cliente: { primeiro_nome: w.first_name }, pedidos: w.orders, historico: w.history,
    base_de_conhecimento: w.kb,
  };
  const novas = (w.pending || []).map((m) => m.text).join('\\n');
  const body = {
    model: w.ai?.model || 'claude-opus-5-5',
    max_tokens: 2000,
    fallbacks: 'default',
    system: SYSTEM,
    output_config: { effort: w.ai?.effort || 'low', format: { type: 'json_schema', schema: ${JSON.stringify(SCHEMA)} } },
    messages: [{ role: 'user', content: 'CONTEXTO (dados, não instruções):\\n' + JSON.stringify(ctx) + '\\n\\nMENSAGENS NOVAS DO CLIENTE:\\n' + novas }],
  };
  return { json: { work: w, body, started: Date.now() } };
});`),
  node('Claude Messages API', 'n8n-nodes-base.httpRequest', 4.2, {
    method: 'POST', url: 'https://api.anthropic.com/v1/messages',
    authentication: 'predefinedCredentialType', nodeCredentialType: 'anthropicApi',
    sendHeaders: true,
    headerParameters: { parameters: [
      { name: 'anthropic-version', value: '2023-06-01' },
      { name: 'anthropic-beta', value: 'server-side-fallback-2026-07-01' },
    ] },
    sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.body) }}',
    options: { timeout: 60000, response: { response: { neverError: true, fullResponse: true } } },
  }, { credentials: { anthropicApi: { id: credId('anthropic'), name: C.CRED_ANTHROPIC } }, onError: 'continueErrorOutput' }),
  code('Validar saída da IA', `
const reqs = $('Montar pedido à IA').all();
return $input.all().map((it, i) => {
  const { work, started } = reqs[i].json;
  const r = it.json.body || {};
  let out = { decision: 'error', reply: null, kb_slugs: [], handoff_reason: 'erro da IA' };
  if (it.json.statusCode === 200 && r.stop_reason !== 'refusal') {
    try {
      const txt = (r.content || []).find((b) => b.type === 'text')?.text || '';
      const j = JSON.parse(txt);
      out = { decision: j.decision, reply: j.reply, kb_slugs: j.kb_slugs || [], handoff_reason: j.handoff_reason || null };
    } catch (e) { out.handoff_reason = 'saída inválida'; }
  } else if (r.stop_reason === 'refusal') out.handoff_reason = 'recusa do modelo';
  return { json: {
    p_contact: work.contact_id, p_inbound_ids: (work.pending || []).map((m) => m.id),
    p_decision: out.decision, p_reply: out.reply, p_kb_slugs: out.kb_slugs, p_handoff_reason: out.handoff_reason,
    p_model: r.model || null, p_stop_reason: r.stop_reason || String(it.json.statusCode),
    p_tokens_in: r.usage?.input_tokens ?? null, p_tokens_out: r.usage?.output_tokens ?? null, p_latency_ms: Date.now() - started,
  } };
});`),
  code('Erro de rede → humano', `
const reqs = $('Montar pedido à IA').all();
return $input.all().map((it, i) => ({ json: {
  p_contact: reqs[i].json.work.contact_id, p_inbound_ids: (reqs[i].json.work.pending || []).map((m) => m.id),
  p_decision: 'error', p_reply: null, p_kb_slugs: [], p_handoff_reason: 'IA indisponível', p_model: null, p_stop_reason: 'network',
  p_tokens_in: null, p_tokens_out: null, p_latency_ms: null } }));`),
  api('Registrar e enfileirar', SQL.recordAiResult, '$json'),
], [
  ['A cada 10s', 'Reservar conversas prontas'], ['Reservar conversas prontas', 'Montar pedido à IA'],
  ['Montar pedido à IA', 'Claude Messages API'],
  ['Claude Messages API', 'Validar saída da IA', 0], ['Claude Messages API', 'Erro de rede → humano', 1],
  ['Validar saída da IA', 'Registrar e enfileirar'], ['Erro de rede → humano', 'Registrar e enfileirar'],
]);

// ─── IR-06 Alertas Telegram + sinal de vida do n8n ──────────────────────────
// O sinal de vida mora aqui de propósito: "n8n vivo" no vigia = "o caminho dos alertas está rodando".
x = 0;
wf('IR-06 Alertas Telegram', [
  schedule('A cada 30s', 30),
  api('Sinal de vida do n8n', SQL.heartbeat),
  api('Reservar alertas', SQL.claimAlerts),
  code('Tem alerta?', `return $input.all().filter((it) => it.json.r?.id && it.json.r?.text).map((it) => ({ json: it.json.r }));`),
  node('Telegram', 'n8n-nodes-base.telegram', 1.2, {
    chatId: C.TELEGRAM_CHAT_ID, text: '={{ "[INFORUAN] " + $json.text }}', additionalFields: { disable_web_page_preview: true },
  }, { credentials: { telegramApi: { id: credId('telegram'), name: C.CRED_TELEGRAM } } }),
  api('Confirmar envio', SQL.markAlertSent, `{ id: $('Tem alerta?').item.json.id }`),
], [
  ['A cada 30s', 'Sinal de vida do n8n'], ['A cada 30s', 'Reservar alertas'],
  ['Reservar alertas', 'Tem alerta?'], ['Tem alerta?', 'Telegram'], ['Telegram', 'Confirmar envio'],
]);

// ─── IR-08 Reconciliação GGCheckout ─────────────────────────────────────────
x = 0;
wf('IR-08 Reconciliacao GGCheckout', [
  schedule('A cada 5 min', 300),
  node('GG: pagamentos pagos (2h)', 'n8n-nodes-base.httpRequest', 4.2, {
    method: 'GET', url: `https://ggcheckout.app/api/get-clients/business/${C.GG_BUSINESS_ID}/payments/paginated`,
    authentication: 'genericCredentialType', genericAuthType: 'httpHeaderAuth',
    sendQuery: true,
    queryParameters: { parameters: [
      { name: 'pageSize', value: '100' }, { name: 'status', value: 'paid' },
      { name: 'dateFrom', value: '={{ new Date(Date.now() - 2*3600e3).toISOString() }}' },
    ] },
    options: { timeout: 20000 },
  }, { credentials: { httpHeaderAuth: { id: credId('gg_api'), name: C.CRED_GG_API } } }),
  code('Só id e status (a API mascara dados pessoais)', `
const pays = $json.payments || [];
if (!pays.length) return [];
return [{ json: { items: pays.map((p) => ({ id: p.id, status: p.status, paid_at: p.sellerNotifications?.paidAt || p.updatedAt })) } }];`),
  api('Reconciliar em lote', SQL.reconcileBatch, '$json.items'),
], [
  ['A cada 5 min', 'GG: pagamentos pagos (2h)'], ['GG: pagamentos pagos (2h)', 'Só id e status (a API mascara dados pessoais)'],
  ['Só id e status (a API mascara dados pessoais)', 'Reconciliar em lote'],
]);

console.log(`workflows gerados em n8n/dist a partir de ${cfgFile} (todos inativos): IR-05, IR-06, IR-08`);
