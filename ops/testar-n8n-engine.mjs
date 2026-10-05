#!/usr/bin/env node
// INFORUAN — testa o login do n8n_engine pelo pooler do Supabase (modo sessão), a partir do Mac.
// Lê a senha do Keychain e NUNCA a exibe. Só imprime OK/FALHA de cada verificação.
// Uso: node ops/testar-n8n-engine.mjs aws-0-REGIAO.pooler.supabase.com
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import pg from 'pg';

const PROJECT_REF = 'bsmuouivezjnfrcnamky';
const SERVICE = 'inforuan-supabase-n8n_engine';
// Certificado público da CA do Supabase ("Supabase Root 2021 CA"), baixado do dashboard (Database → SSL Configuration).
const CA_FILE = new URL('../infra/certs/supabase-prod-ca-2021.crt', import.meta.url).pathname;
const ca = existsSync(CA_FILE) ? readFileSync(CA_FILE, 'utf8') : undefined;
const host = process.argv[2];
if (!host || !/^[a-z0-9-]+\.pooler\.supabase\.com$/.test(host)) {
  console.error('Informe o host do Session pooler, ex.: node ops/testar-n8n-engine.mjs aws-0-sa-east-1.pooler.supabase.com');
  process.exit(2);
}
const kc = spawnSync('security', ['find-generic-password', '-s', SERVICE, '-a', 'n8n_engine', '-w'], { encoding: 'utf8' });
if (kc.status !== 0) { console.error('Senha não encontrada no Keychain. Rode antes: node ops/gerar-senha-n8n-engine.mjs'); process.exit(2); }
const password = kc.stdout.trim();

let failures = 0;
const ok = (label, extra = '') => console.log(`OK     ${label}${extra ? ` (${extra})` : ''}`);
const fail = (label, extra = '') => { failures++; console.log(`FALHA  ${label}${extra ? ` (${extra})` : ''}`); };
const scrub = (msg) => String(msg).split(password).join('***');

async function connect(verifyCa) {
  const client = new pg.Client({
    host, port: 5432, database: 'postgres', user: `n8n_engine.${PROJECT_REF}`, password,
    ssl: { rejectUnauthorized: verifyCa, servername: host, ...(verifyCa && ca ? { ca } : {}) }, connectionTimeoutMillis: 10000,
    application_name: 'inforuan-teste-n8n_engine',
  });
  await client.connect();
  return client;
}

let client;
try {
  client = await connect(true);
  ok('Conexão TLS com certificado verificado', ca ? 'CA do Supabase' : 'cadeia padrão do sistema');
} catch (e) {
  const msg = scrub(e.message);
  if (/certificate|self.signed|unable to verify/i.test(msg)) {
    fail(ca ? 'Certificado TLS não verificado com a CA do Supabase' : 'Certificado TLS não verificado (falta infra/certs/supabase-prod-ca-2021.crt)', msg);
    try { client = await connect(false); ok('Conexão TLS sem verificação de CA (só para concluir os testes de permissão)'); }
    catch (e2) { fail('Conexão', scrub(e2.message)); process.exit(1); }
  } else { fail('Conexão', msg); process.exit(1); }
}

const q = async (sql) => (await client.query(sql)).rows;
const tlsProto = client.connection?.stream?.getProtocol?.();
tlsProto ? ok('Conexão Mac → pooler criptografada', tlsProto) : fail('Conexão Mac → pooler SEM criptografia');
try {
  const [me] = await q(`select current_user u, current_setting('statement_timeout') st, current_setting('lock_timeout') lt,
                               current_setting('idle_in_transaction_session_timeout') it`);
  me.u === 'n8n_engine' ? ok('Usuário da sessão é n8n_engine') : fail('Usuário da sessão', me.u);
  me.st === '15s' && me.lt === '5s' && me.it === '1min' ? ok('Limites de sessão aplicados', `${me.st} / ${me.lt} / ${me.it}`)
    : fail('Limites de sessão', `${me.st} / ${me.lt} / ${me.it}`);
  await q(`select api.heartbeat('teste_conexao', '{"origem":"mac"}')`);
  ok('api.heartbeat executou');
} catch (e) { fail('Chamadas permitidas', scrub(e.message)); }

const mustDeny = [
  ['ler tabela do motor (public.contacts)', 'select count(*) from public.contacts'],
  ['ler configurações (public.settings)', 'select count(*) from public.settings'],
  ['chamar função interna (public.engine_tick)', `select public.engine_tick('inforuan')`],
  ['trocar o modo do motor (public.set_engine_mode)', `select public.set_engine_mode('inforuan', 'live', 'teste')`],
  ['ver agendamentos (cron.job)', 'select count(*) from cron.job'],
  ['ler usuários do Auth (auth.users)', 'select count(*) from auth.users'],
  ['ler arquivos do Storage (storage.objects)', 'select count(*) from storage.objects'],
  ['ler estatísticas (extensions.pg_stat_statements)', 'select count(*) from extensions.pg_stat_statements'],
  ['criar tabela em public', 'create table public.teste_n8n_engine(id int)'],
  ['criar schema', 'create schema teste_n8n_engine'],
];
for (const [label, sql] of mustDeny) {
  try { await q(sql); fail(`Bloqueio: ${label}`, 'foi PERMITIDO'); }
  catch (e) { /permission denied|must be owner/i.test(e.message) ? ok(`Bloqueio: ${label}`) : fail(`Bloqueio: ${label}`, scrub(e.message)); }
}
await client.end();
console.log(failures === 0 ? '\nRESULTADO: TUDO OK' : `\nRESULTADO: ${failures} FALHA(S)`);
process.exit(failures === 0 ? 0 : 1);
