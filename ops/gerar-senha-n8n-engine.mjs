#!/usr/bin/env node
// INFORUAN — gera a senha do n8n_engine NO SEU MAC, sem exibi-la.
//   • senha aleatória de 40 caracteres (letras e números);
//   • guardada só no Keychain do macOS (serviço "inforuan-supabase-n8n_engine");
//   • copia para a área de transferência o SQL com a senha JÁ CIFRADA (SCRAM-SHA-256),
//     para colar no SQL Editor do Supabase. O texto puro nunca sai do Mac.
// Uso: node ops/gerar-senha-n8n-engine.mjs            (recusa se já existir senha no Keychain)
//      node ops/gerar-senha-n8n-engine.mjs --rotacionar (substitui; depois é preciso colar o SQL de novo)
import { randomInt, randomBytes, pbkdf2Sync, createHmac, createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const SERVICE = 'inforuan-supabase-n8n_engine';
const ACCOUNT = 'n8n_engine';
const rotate = process.argv.includes('--rotacionar');

const exists = spawnSync('security', ['find-generic-password', '-s', SERVICE, '-a', ACCOUNT], { stdio: 'ignore' }).status === 0;
if (exists && !rotate) {
  console.error('Já existe uma senha do n8n_engine no Keychain. Nada foi alterado.');
  console.error('Para trocar a senha de propósito: node ops/gerar-senha-n8n-engine.mjs --rotacionar');
  process.exit(1);
}

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
const password = Array.from({ length: 40 }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');

// Guarda no Keychain pelo modo interativo do `security` (a senha não aparece na lista de processos).
const add = spawnSync('security', ['-i'], {
  input: `add-generic-password -U -s ${SERVICE} -a ${ACCOUNT} -l INFORUAN-Supabase-n8n_engine -w "${password}"\n`,
  stdio: ['pipe', 'ignore', 'inherit'],
});
const saved = spawnSync('security', ['find-generic-password', '-s', SERVICE, '-a', ACCOUNT, '-w'], { encoding: 'utf8' });
if (add.status !== 0 || saved.status !== 0 || saved.stdout.trim() !== password) {
  console.error('Falha ao gravar no Keychain. Nada foi copiado.');
  process.exit(1);
}

// Verificador SCRAM-SHA-256 (mesmo formato que o Postgres grava em pg_authid; conferido contra o Postgres).
const iterations = 4096;
const salt = randomBytes(16);
const salted = pbkdf2Sync(password, salt, iterations, 32, 'sha256');
const clientKey = createHmac('sha256', salted).update('Client Key').digest();
const storedKey = createHash('sha256').update(clientKey).digest('base64');
const serverKey = createHmac('sha256', salted).update('Server Key').digest('base64');
const verifier = `SCRAM-SHA-256$${iterations}:${salt.toString('base64')}$${storedKey}:${serverKey}`;

const sql = `-- INFORUAN: libera o login do n8n_engine com a senha JÁ CIFRADA (gerada no Mac; o texto puro não está aqui).
-- Cole no SQL Editor do Supabase e clique em Run. Não salve esta consulta como snippet.
alter role n8n_engine with login password '${verifier}';
select rolname, rolcanlogin, rolconnlimit, rolpassword is not null as tem_senha from pg_authid where rolname = 'n8n_engine';
`;
const copy = spawnSync('pbcopy', [], { input: sql });
if (copy.status !== 0) { console.error('Falha ao copiar para a área de transferência.'); process.exit(1); }

console.log(exists ? 'Senha do n8n_engine TROCADA no Keychain.' : 'Senha do n8n_engine criada e guardada no Keychain.');
console.log(`  Keychain: serviço "${SERVICE}", conta "${ACCOUNT}". A senha NÃO foi exibida.`);
console.log('Copiado para a área de transferência: o SQL com a senha já cifrada.');
console.log('Próximo passo: colar no SQL Editor do Supabase e clicar em Run.');
