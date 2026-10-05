#!/usr/bin/env node
// INFORUAN — segredo do webhook da GGCheckout, gerado NO SEU MAC e guardado só no Keychain.
// O valor nunca é exibido. Para colar em outro lugar (Secrets do Supabase, painel da GGCheckout), use --copiar.
// Uso: node ops/gerar-segredo-gg-webhook.mjs              cria (recusa se já existir) e copia para a área de transferência
//      node ops/gerar-segredo-gg-webhook.mjs --copiar     copia o segredo existente de novo
//      node ops/gerar-segredo-gg-webhook.mjs --rotacionar troca o segredo (depois atualizar Supabase e GGCheckout)
// Depois de colar: limpe a área de transferência com  pbcopy < /dev/null
import { randomInt } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const SERVICE = 'inforuan-gg-webhook-secret';
const ACCOUNT = 'gg-webhook';
const args = process.argv.slice(2);
const read = () => spawnSync('security', ['find-generic-password', '-s', SERVICE, '-a', ACCOUNT, '-w'], { encoding: 'utf8' });
const copy = (v) => spawnSync('pbcopy', [], { input: v }).status === 0;

if (args.includes('--copiar')) {
  const r = read();
  if (r.status !== 0) { console.error('Segredo não encontrado no Keychain. Rode sem --copiar para criar.'); process.exit(1); }
  if (!copy(r.stdout.trim())) { console.error('Falha ao copiar.'); process.exit(1); }
  console.log('Segredo do webhook copiado para a área de transferência (não exibido). Depois de colar: pbcopy < /dev/null');
  process.exit(0);
}

const exists = read().status === 0;
if (exists && !args.includes('--rotacionar')) {
  console.error('Já existe um segredo do webhook no Keychain. Nada foi alterado.');
  console.error('Para copiar de novo: --copiar   |   para trocar de propósito: --rotacionar');
  process.exit(1);
}
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
const secret = Array.from({ length: 48 }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');
spawnSync('security', ['-i'], {
  input: `add-generic-password -U -s ${SERVICE} -a ${ACCOUNT} -l INFORUAN-GG-webhook-secret -w "${secret}"\n`,
  stdio: ['pipe', 'ignore', 'inherit'],
});
const saved = read();
if (saved.status !== 0 || saved.stdout.trim() !== secret) { console.error('Falha ao gravar no Keychain. Nada foi copiado.'); process.exit(1); }
if (!copy(secret)) { console.error('Guardado no Keychain, mas falhou a cópia. Use --copiar.'); process.exit(1); }
console.log(exists ? 'Segredo do webhook TROCADO no Keychain.' : 'Segredo do webhook criado e guardado no Keychain.');
console.log(`  Keychain: serviço "${SERVICE}". O valor NÃO foi exibido e está na área de transferência.`);
console.log('Próximo passo: colar em Supabase → Edge Functions → Secrets, como GG_WEBHOOK_SECRET. Depois: pbcopy < /dev/null');
