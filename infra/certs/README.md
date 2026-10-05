# Certificados públicos

- `supabase-prod-ca-2021.crt`: CA pública do Supabase ("Supabase Root 2021 CA"), baixada do dashboard
  (Project Settings → Database → SSL Configuration) em 05/10/2026. Não é segredo.
  SHA-256: `80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA`
  (igual à raiz apresentada por `aws-0-us-west-2.pooler.supabase.com`). Válida até 26/04/2031.
  Usada para verificar o certificado do pooler (`*.pooler.supabase.com`) em vez de desligar a verificação.
