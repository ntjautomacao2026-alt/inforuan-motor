# Matriz comercial e inventário de entregáveis

> Status: **proposta para aprovação**. Nenhuma pasta, produto, checkout ou entregável foi alterado.
> Inventário feito em 2026-09-30 com leitura pública das pastas do Drive e dos dados de pedidos da GGCheckout.

## 0. Regras que valem para tudo

1. **Ninguém perde nada.** As pastas atuais viram **pastas legadas**: continuam com o mesmo conteúdo e o mesmo link, para sempre. Todos os compradores até a data de corte continuam acessando tudo o que acessam hoje.
2. A nova estrutura vale **só para compras depois da data de corte**, com pastas novas (cópias dos arquivos) e um link por entregável.
3. **Taxonomia** (vale para o motor, os relatórios e os experimentos):
   - **Order bump**: oferecido **só no checkout**, na mesma transação.
   - **Upsell**: oferta **pós-compra da mesma linha** (versão maior, complemento ou um bump que não foi comprado).
   - **Cross-sell**: oferta pós-compra de **outra linha**.
   - **Downsell**: alternativa mais barata depois de uma recusa.
   - Bump não comprado e reoferecido depois = **upsell** (mesma linha) ou **cross-sell** (outra linha), **nunca** "bump".
4. Preços abaixo são **hipóteses a testar**, não decisões.

---

## 1. Inventário real

### Finanças 40+ (pasta legada `1vVuq…`, 11 arquivos)
| Subpasta | Arquivo | Papel hoje | Situação |
|---|---|---|---|
| Mapas visuais | Finanças 40+ Mapas Visuais.pdf (50 mapas, 5 etapas) | Principal | ✅ Promessa de 50 cumprida |
| Bônus | Raio-X da Minha Vida Financeira, Organizador Financeiro 40+, Bússola dos Investimentos 40+, Calculadora do Meu Futuro 40+ (planilha) + "IMPORTANTE" | 4 bônus do Completo | ✅ |
| Bônus | Guia do Meu INSS · Guia dos Direitos e Benefícios 40+ | **Vendidos como bump** (138 e 139 vendas) mas estão em "Bônus" | ⚠️ Qualquer comprador recebe |
| Complementares | Como Investir em Ações · Como Investir nos EUA · Declarar Investimentos no IR | Bumps atuais (1.215 / 907 / 967 vendas) | ⚠️ Qualquer comprador recebe |

### Atualiza 40+ (pasta legada `1_ukV…`, 23 arquivos)
| Subpasta | Arquivo | Papel hoje | Situação |
|---|---|---|---|
| Mapas | Ferramentas Digitais (40), Celular (38), Computador (41), WhatsApp (32) = **151 mapas** | Principal | ⚠️ 3 mapas repetidos → ~148 distintos para a promessa "+150" |
| Bônus | Volte ao Mercado 40+, PDF Sem Mistério, E-mail Profissional do Zero, Segurança Digital 40+ | 4 bônus do Completo | ✅ |
| Bônus | Fotos Antigas com IA, Figurinhas, PIX Sem Erro, Celular Novo, Senhas (**1 PNG cada**) | Bumps atuais (465 / 278 / 126 / 294 / 365) | ⚠️ Qualquer comprador recebe; entregável fino |
| Diversos [Instagram, Uber] | 10 PNGs (Backup, Uber, Print, Wi-Fi…) | Não prometido em lugar nenhum | Conteúdo extra sem uso comercial |

### Golpes (pasta `1soVh…`)
- **Pasta vazia** publicamente. Os produtos "É Golpe ou Não É?" (R$ 3,90), "SOS: Caí em um Golpe!" e "Proteja Sua Família" **não têm entregável**.
- 0 vendas até hoje, mas **o checkout está publicado**. Se entrar tráfego, o cliente paga e recebe uma pasta vazia.

### Meu Consultor Financeiro 40+ (R$ 47)
- Entregável: link de um Gem do Gemini. Vendido como upsell da linha Finanças (checkout separado, sem campos).

### 🚨 Pendências de entrega com clientes reais
| Bump vendido | Vendas | Datas | Arquivo |
|---|---|---|---|
| Guia de Como Limpar Seu Nome (Serasa/SPC) | 2 | 26–28/08 | **Não existe na pasta** |
| Guia Pronto para Negociar Dívidas | 2 | 26–28/08 | **Não existe na pasta** |
| Guia de Pix Sem Golpe | 1 | 28/08 | **Não existe na pasta** |

→ **5 clientes pagaram e não receberam.** Ação: o Ruan confirma se os arquivos existem em outro lugar; se sim, envia; se não, oferece o reembolso desses itens ou um substituto. Não depende do motor.

---

## 2. Matriz proposta — linha Finanças 40+

| Oferta | Papel | Promessa | Entregáveis (nova pasta) | Preço | Bump no checkout | Upsell pós-compra | Cross-sell |
|---|---|---|---|---|---|---|---|
| **Finanças Básico** | Entrada | 50 mapas para organizar, sair das dívidas, montar reserva e entender investimentos | Mapas Visuais (50) | R$ 19,90 | Ações · EUA · IR (R$ 12,90) | **Upgrade para o Completo** pela diferença (hip.: R$ 17–19,90) | Atualiza Básico |
| **Finanças Completo** | Versão completa (≈85% das vendas da linha) | 50 mapas + 4 ferramentas práticas | Mapas + Raio-X + Organizador + Bússola + Calculadora | R$ 37 | Ações · EUA · IR (R$ 12,90) | **Meu Consultor Financeiro 40+** (R$ 47, o atual) | Atualiza Completo |
| **Pacote Investidor 40+** | Upsell (para quem não levou bump) | Investir em ações, nos EUA e declarar no IR | Ações + EUA + IR | hip.: R$ 24,90 | — | — | — |
| **Direitos & Aposentadoria 40+** | Upsell / bump de teste | Consultar o INSS e descobrir benefícios esquecidos | INSS + Direitos e Benefícios | hip.: R$ 14,90 | Candidato a 4º bump (teste A/B) | — | — |
| **Meu Consultor Financeiro 40+** | Upsell | Assistente de IA para orçamento, dívidas e metas | Gem do Gemini + instruções de uso | R$ 47 | — | — | — |

## 3. Matriz proposta — linha Atualiza 40+

| Oferta | Papel | Promessa | Entregáveis (nova pasta) | Preço | Bump no checkout | Upsell pós-compra | Cross-sell |
|---|---|---|---|---|---|---|---|
| **Atualiza Básico** | Entrada | +150 mapas para usar celular, computador e WhatsApp | 4 PDFs de mapas (**corrigir os 3 repetidos** antes) | R$ 19,90 | 5 guias (R$ 9,90) | **Upgrade para o Completo** pela diferença | Finanças Básico |
| **Atualiza Completo** | Versão completa (≈89% das vendas da linha) | +150 mapas + 4 bônus | Mapas + 4 bônus | R$ 37 | 5 guias (R$ 9,90) | **Pacote Celular Sem Complicação** (hoje não existe upsell) | Finanças Completo |
| **Pacote Celular Sem Complicação** | Upsell (para quem não levou bump) | Resolver no celular o que mais trava no dia a dia | 5 guias + 10 "Diversos" (Uber, Wi-Fi, Print, Backup…) | hip.: R$ 19,90 | — | — | — |

> "Diversos" (10 PNGs) hoje não é vendido nem prometido. Como incentivo, dá valor ao pacote de upsell sem produzir conteúdo novo.

## 4. Linha Golpes (congelada)
| Oferta | Papel previsto | Situação |
|---|---|---|
| É Golpe ou Não É? (R$ 3,90) | Isca/entrada barata + cross-sell para as duas linhas | **Sem conteúdo** → despublicar o checkout ou produzir o conteúdo antes de qualquer tráfego |
| SOS: Caí em um Golpe! · Proteja Sua Família | Bumps | Sem conteúdo |
| (futuro) Kit Segurança Digital 40+ | Upsell natural para Atualiza | Depende do conteúdo |

## 5. Mapa de cross-sell (pós-compra)

| Comprou | Oferecer (ordem de teste) |
|---|---|
| Finanças (qualquer) | Atualiza Completo → Kit Golpes (quando existir) |
| Atualiza (qualquer) | Finanças Completo → Meu Consultor Financeiro |
| As duas linhas | Consultor (se ainda não tem) → nada (sem fadiga) |

Regras: nunca ofertar para quem teve reembolso ou chargeback; nunca ofertar o que o cliente já recebe (inclusive via pasta legada, porque **todo comprador legado já tem os bumps da própria linha**); no máximo 1 oferta ativa por contato; intervalo mínimo de 3 dias entre ofertas.

> Consequência importante do legado: os ~6 mil compradores atuais **já têm acesso** a todos os bumps e bônus da linha que compraram. Para eles, só fazem sentido **cross-sell** (outra linha) e o **Consultor**. Upsell da mesma linha só para compradores novos.

## 6. Plano de migração (não executar sem autorização)
1. Resolver as 5 entregas pendentes.
2. Criar as novas pastas por entregável (cópias), com nomes corrigidos (`…Estados Unidos.pdf`, `…Mercado 40+.pdf`).
3. Corrigir os 3 mapas repetidos do Atualiza.
4. Definir a data de corte. Pastas legadas intactas.
5. Trocar o link de entrega na GGCheckout **só para novos pedidos**: produto principal e cada bump com o próprio link.
6. Configurar o upsell nativo em teste A/B contra o fluxo atual do Consultor.
7. Ativar cross-sell no motor (depois de a régua de Pix estar estável).
8. V2: área de membros com acesso individual, que acaba com o vazamento por link compartilhado.
