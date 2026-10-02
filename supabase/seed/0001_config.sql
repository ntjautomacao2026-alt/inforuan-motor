-- INFORUAN — configuração inicial (idempotente).
-- NADA aqui ativa envio: a régua nasce inativa e a instância nasce pausada.
-- Sem credenciais. Links de acesso aos produtos ficam em 0002_catalog_links.local.sql (não versionar).

insert into workspaces(slug, name) values ('inforuan', 'INFORUAN — Ruan') on conflict (slug) do nothing;

-- ─── Settings ────────────────────────────────────────────────────────────────
insert into settings(workspace_id, key, value)
select ws.id, s.key, s.value::jsonb from workspaces ws,
  (values
    ('timezone',            '"America/Sao_Paulo"'),
    ('send_window',         '{"start":"08:00","end":"21:00"}'),       -- passos com respect_send_window
    ('handoff_hours',       '{"start":"09:00","end":"20:00"}'),
    ('human_mode_hours',    '12'),                                     -- validade do modo humano
    ('internal_test_phones','[]'),                                     -- ex.: ["+5511999999999"] — só contatos internos
    ('ai',                  '{"model":"claude-opus-5-5","effort":"low","debounce_seconds":20,"max_reply_chars":700}')
  ) as s(key, value)
where ws.slug = 'inforuan'
on conflict (workspace_id, key) do nothing;

-- ─── Catálogo (espelho da GGCheckout em 30/09/2026) ──────────────────────────
insert into catalog_products(workspace_id, external_product_id, title, line)
select ws.id, p.id, p.title, p.line from workspaces ws,
  (values
    ('K26nrfhXUfA1b2qm0e3C', 'Finanças 40+ — Kit Completo', 'financas'),
    ('Ah2H4Jg0FoogyQTf0zCb', 'Finanças 40+ — Kit Básico', 'financas'),
    ('EuwGEZ2vDJI3ACa8j4uE', 'Kit Completo Atualiza 40+', 'atualiza'),
    ('SOTLn9fbenLOlr4LBumC', 'Kit Básico Atualiza 40+', 'atualiza'),
    ('2PvFfjNEUkPGLYHMoNgR', 'Meu Consultor Financeiro 40+', 'consultor')
  ) as p(id, title, line)
where ws.slug = 'inforuan'
on conflict (workspace_id, external_product_id) do nothing;

-- public_url = link público do checkout (copiar do painel). NULL → passos com link são pulados + alerta.
insert into catalog_checkouts(workspace_id, external_checkout_id, external_product_id, title, is_internal_test)
select ws.id, c.id, c.pid, c.title, c.internal from workspaces ws,
  (values
    ('pd7XKWVRDxluGm33qNJP', 'K26nrfhXUfA1b2qm0e3C', 'Finanças 40+ — Kit Completo', false),
    ('KajYetYQ6PmN56pByICR', 'Ah2H4Jg0FoogyQTf0zCb', 'Finanças 40+ — Kit Básico', false),
    ('dDTs0BWHlGqWRdqhQakS', 'EuwGEZ2vDJI3ACa8j4uE', 'Kit Completo Atualiza 40+', false),
    ('JoJUs3L32gGJWisyTvJA', 'SOTLn9fbenLOlr4LBumC', 'Kit Básico Atualiza 40+', false),
    ('sBcjPZXfMUaQxgqfH8Ir', '2PvFfjNEUkPGLYHMoNgR', 'Meu Consultor Financeiro 40+', false),
    ('q0EbnyHD8PgIraUBZTTl', 'EuwGEZ2vDJI3ACa8j4uE', '[TESTE E2E — NÃO PUBLICAR] Kit Completo Atualiza 40+', true)
  ) as c(id, pid, title, internal)
where ws.slug = 'inforuan'
on conflict (workspace_id, external_checkout_id) do nothing;

-- ─── Holdout da régua de Pix (aprovado: 10%) ─────────────────────────────────
insert into experiments(workspace_id, key, status, holdout_pct, salt, window_hours, eligibility_offset_minutes)
select ws.id, 'recovery_pix_v1', 'running', 10, gen_random_uuid()::text, 72, 6
from workspaces ws where ws.slug = 'inforuan'
on conflict (workspace_id, key) do nothing;

-- ─── Régua de Pix (INATIVA até autorização) ──────────────────────────────────
insert into sequences(workspace_id, key, purpose, active, version, experiment_key)
select ws.id, 'recovery_pix', 'recovery', false, 1, 'recovery_pix_v1'
from workspaces ws where ws.slug = 'inforuan'
on conflict (workspace_id, key) do nothing;

insert into sequence_steps(sequence_id, position, delay_minutes, template_key, respect_send_window, requires_checkout_url)
select s.id, st.pos, st.delay, st.tpl, st.win, st.url
from sequences s join workspaces ws on ws.id = s.workspace_id,
  (values
    (1,    6, 'pix_ativo',        false, false),  -- Pix ainda válido (vale 15 min)
    (2,   20, 'pix_novo_link',    false, true),   -- expirou → novo link
    (3,  180, 'pix_lembrete_3h',  true,  true),
    (4, 1440, 'pix_ultimo_24h',   true,  true)
  ) as st(pos, delay, tpl, win, url)
where ws.slug = 'inforuan' and s.key = 'recovery_pix'
on conflict (sequence_id, position) do nothing;

-- ─── Templates (RASCUNHOS — aguardam aprovação do Ruan) ──────────────────────
-- Escritos já compatíveis com a futura migração p/ Cloud API (variáveis nomeadas → parâmetros).
insert into message_templates(workspace_id, key, version, purpose, ttl_minutes, required_vars, body_text, meta_category)
select ws.id, t.key, 1, t.purpose, t.ttl, t.vars, t.body, t.cat from workspaces ws,
  (values
    ('pix_ativo', 'recovery', 8, array['nome','produto','pix_code'], 'utility',
     E'Oi, {{nome}}! Vi que você gerou o Pix do *{{produto}}* e ele ainda está ativo por alguns minutos.\n\nPara concluir, copie o código abaixo e cole no app do seu banco, em *Pix Copia e Cola*:\n\n{{pix_code}}\n\nSe tiver qualquer dúvida, é só responder aqui.'),
    ('pix_novo_link', 'recovery', 60, array['nome','produto','checkout_url'], 'utility',
     E'{{nome}}, o Pix do *{{produto}}* expirou (ele vale só 15 minutos).\n\nSe ainda quiser garantir, é só gerar um novo por aqui: {{checkout_url}}\n\nSe travou em alguma etapa, me conta que eu te ajudo.'),
    ('pix_lembrete_3h', 'recovery', 360, array['nome','produto','checkout_url'], 'marketing',
     E'Oi, {{nome}}! Seu pedido do *{{produto}}* não foi concluído.\n\nSe quiser, o link continua disponível: {{checkout_url}}\n\nFicou alguma dúvida sobre o conteúdo? Pode perguntar aqui.\n(Para não receber mais lembretes, responda PARAR.)'),
    ('pix_ultimo_24h', 'recovery', 720, array['nome','produto','checkout_url'], 'marketing',
     E'{{nome}}, este é o último lembrete sobre o *{{produto}}*: {{checkout_url}}\n\nSe não fizer mais sentido para você, tudo bem. Obrigado pelo interesse!'),
    ('pos_compra_acesso', 'post_purchase', 1440, array['nome','produto','link_acesso'], 'utility',
     E'Oi, {{nome}}! Seu pagamento do *{{produto}}* foi confirmado. 🎉\n\nSeu acesso: {{link_acesso}}\n\nComo abrir no celular: toque no link → ele abre no Google Drive → toque no arquivo → no menu (⋮) escolha *Baixar* para guardar no seu celular.\n\nVocê também recebeu o acesso por e-mail (confira a caixa de spam). Qualquer dificuldade, é só responder aqui.'),
    ('ia_resposta', 'support', 30, array['texto'], 'service', E'{{texto}}'),
    ('handoff_aberto', 'handoff_notice', 30, array[]::text[], 'service',
     E'Vou chamar alguém da nossa equipe para te ajudar com isso. Em instantes você recebe uma resposta por aqui. 🙂'),
    ('handoff_fila', 'handoff_notice', 120, array[]::text[], 'service',
     E'Nosso atendimento humano funciona das 9h às 20h. Já registrei sua mensagem e alguém da equipe te responde a partir das 9h. 🙂'),
    ('opt_out_confirmacao', 'support', 30, array[]::text[], 'service',
     E'Tudo certo, não vou mais enviar mensagens automáticas. Se precisar de ajuda com a sua compra, é só escrever aqui.')
  ) as t(key, purpose, ttl, vars, cat, body)
where ws.slug = 'inforuan'
on conflict (workspace_id, key, version) do nothing;

-- ─── Instância de envio ──────────────────────────────────────────────────────
-- NÃO criada: o provedor de WhatsApp ainda não foi decidido. Sem instância, nada sai da fila.
-- Quando decidir, inserir em provider_instances com paused = true e liberar via unpause_instance().
