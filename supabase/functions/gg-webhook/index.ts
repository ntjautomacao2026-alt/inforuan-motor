// INFORUAN — Edge Function gg-webhook: entrada dos webhooks da GGCheckout.
// Publicar com verify_jwt = false (a GGCheckout não envia JWT do Supabase; a autenticação é o segredo, em handler.ts).
// Segredo: GG_WEBHOOK_SECRET (Edge Functions → Secrets). SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY são do próprio runtime.
import { handleGgWebhook } from './handler.ts';

const url = Deno.env.get('SUPABASE_URL');
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

Deno.serve((req: Request) =>
  handleGgWebhook(req, {
    secret: Deno.env.get('GG_WEBHOOK_SECRET'),
    log: (line) => console.log(line),
    rpc: async (fn, args) => {
      if (!url || !key) throw new Error('runtime_env_missing');
      const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
        body: JSON.stringify(args),
        signal: AbortSignal.timeout(10_000),
      });
      return { status: r.status, body: await r.json().catch(() => null) };
    },
  }));
