# Referência — o que aprendemos implantando este fork

Registro das decisões, descobertas e armadilhas da implantação do Whatomate na
infraestrutura da Mooviin. Escrito para que retomar o projeto meses depois não
dependa de memória nem de reler conversas.

Cada afirmação não óbvia vem com a referência ao código que a sustenta.

---

## 1. Panorama

Fork de [shridarpatil/whatomate](https://github.com/shridarpatil/whatomate)
(Go + Vue 3, binário único, AGPL-3.0) rodando numa EC2 que já hospedava Chatwoot,
n8n, Evolution API e ePolítico, sob Docker + EasyPanel.

**Customização própria do fork:** a voz PT-BR do Piper no `docker/Dockerfile`.
A imagem do upstream só traz `en_US-lessac-medium`, e sem a `pt_BR-faber-medium`
o IVR não fala português. É o único arquivo compartilhado que divergimos, e
portanto o único ponto provável de conflito ao sincronizar com o upstream.

---

## 2. Meta / WhatsApp Cloud API

### A migração do número

O número saiu do app WhatsApp Business e foi registrado na Cloud API. O histórico
de conversas do app **não migra** — é preciso exportar antes, se importar.

### Normalização de número brasileiro

A Meta registra celulares brasileiros no **formato antigo, sem o nono dígito**.
Digitamos `62 98117-3298` e o painel exibe `+55 62 8117-3298`. O mesmo vale para
o `wa_id` que chega nos webhooks.

Isso tem consequência prática: no **número de teste**, a lista de destinatários
compara literalmente, então era preciso cadastrar as duas formas. No número de
produção não há lista, e o problema desaparece.

O projeto não normaliza isso — `contactutil` só remove o `+`
([contactutil.go:20](../internal/contactutil/contactutil.go:20)).

### Quatro identificadores que se confundem

| Identificador | O que é |
|---|---|
| **WABA ID** | a conta do WhatsApp Business; agrupa números e templates |
| **Phone Number ID** | um número dentro do WABA |
| **App ID** | o app do developers.facebook.com, que gera o token |
| **Business Portfolio ID** | o portfólio no Business Manager, acima de tudo |

A assinatura de webhooks acontece no nível do **WABA**, não do número.

### O app precisa estar inscrito no WABA

Configurar a URL do webhook **não basta**. O app precisa assinar os eventos do
WABA, e os campos (`messages`, `calls`, `message_template_status_update`)
precisam estar marcados. Sem isso a verificação do webhook passa — ela é só uma
chamada de validação — e nenhum evento chega depois.

Verificável por API, que não deixa dúvida sobre em qual WABA a inscrição está:

```bash
curl -s "https://graph.facebook.com/v24.0/WABA_ID/subscribed_apps" -H "Authorization: Bearer TOKEN"
```

Um WABA criado pelo console costuma vir com o `WA DevX Webhook Events 1P App`, da
própria Meta, já inscrito. Ver só ele na lista significa que **o seu app não
está**.

### Token: System User, não token temporário

O token da tela de configuração expira em 24 horas. Para produção, crie um
**System User** com papel de Administrador e atribua **dois ativos**: a conta do
WhatsApp **e o app**. Atribuir só a conta faz a tela de gerar token dizer
"Nenhuma permissão disponível" — os dois ativos se chamam quase igual
(`Mooviin App` é o WABA, `MooviinApp` é o app), e é fácil atribuir o errado.

Escopos: `whatsapp_business_messaging` e `whatsapp_business_management`.
Expiração **Nunca** para integração servidor-a-servidor, revogável a qualquer
momento em "Anular tokens".

### Onde o App Secret é lido

Por **conta**, do banco, não da configuração global
([webhook.go:186](../internal/handlers/webhook.go:186)). Se ficar vazio, o app
**pula** a validação de assinatura em vez de recusar o evento
([webhook.go:184](../internal/handlers/webhook.go:184)) — funciona, mas qualquer
um que descubra a URL consegue injetar eventos falsos.

Já o **verify token** é conferido primeiro contra a configuração global
([webhook.go:33](../internal/handlers/webhook.go:33)) e depois contra o das
contas, então o webhook pode ser configurado antes de existir qualquer conta.

### Chamadas

Vêm **desabilitadas por padrão**, mesmo em número de teste. Habilita-se em
WhatsApp Manager → número → Mais → **Configurações de ligação** → "Permitir
ligações de voz", ou por API (`POST /{PHONE_NUMBER_ID}/settings`).

Receber chamadas é **gratuito e não exige tier**. Só chamadas **de saída**
exigem tier ≥ 2.000 e são cobradas por pulso de 6 segundos.

### Cache do cliente após excluir a conta do app

Ao excluir a conta do WhatsApp Business para liberar o número, os celulares que
tinham aquele contato guardam "não está mais no WhatsApp" e **recusam chamadas**
mesmo depois do número voltar pela API. Testar de um aparelho que nunca teve o
contato salvo separa isso de um problema real.

---

## 3. Infraestrutura

### EasyPanel não alimenta a interpolação do compose

`${VAR}` no compose é resolvido **na leitura do arquivo**, pelo docker compose.
A aba de ambiente do painel injeta variáveis **dentro do container**, que é
depois. Pior: a variável declarada vazia no compose **sobrescreve** a do painel.

A solução é o interruptor **"Create .env file"** na aba de ambiente. Sem ele,
nada de `${...}` funciona e o app sobe com segredos vazios — o sintoma foi
`JWT secret must be at least 32 characters in production` em loop.

### `pull_policy: always` é obrigatório

Com a tag `latest`, o Docker reaproveita a imagem em cache e o deploy do painel
**não troca o container**, sem avisar. Passamos por isso achando que o build não
tinha saído. A prova é o hostname do container: se não mudou, não houve troca.

### O app precisa estar na rede do Traefik

O compose cria uma rede isolada por projeto. Sem declarar a rede `easypanel`, o
Traefik resolve o nome do container e não alcança ninguém — todo request vira
**502**, com DNS e TLS perfeitos.

E o alias importa: o EasyPanel monta o destino como
`<projeto>_<serviço>_<sub-serviço>`, com **underscores**, enquanto os aliases que
o compose cria usam hífen. Daí o alias explícito `mooviin_whatomate_whatomate`.

Antes de preencher o sub-serviço no painel, o destino sai como
`..._undefined` — sinal de que o campo ficou em branco.

### Serviços do tipo Compose aceitam múltiplos serviços

Três no nosso caso: `whatomate`, `coturn` e `whatomate-redis`. Como o plano free
obriga a reaproveitar um projeto, os nomes de serviço e volume são prefixados
para não colidir com o Chatwoot, que vive no mesmo projeto.

### `mode: host` em portas é campo exclusivo do Swarm

O EasyPanel roda `docker compose`, que **ignora** esse campo. A proteção que
supúnhamos ter contra o SNAT do ingress nunca esteve em vigor.

---

## 4. Chamadas: por que a mídia precisa de um relay

### O problema

Com o app numa rede bridge/overlay, o ICE conectava mas o **DTLS nunca fechava**:
`Peer connection state` ficava em `connecting` até o timeout de 15 segundos
([webrtc.go:165](../internal/calling/webrtc.go:165)), e a chamada ficava muda.

Duas causas concorrem. O container precisa de **duas interfaces** — a rede do
projeto, para o Redis, e a overlay, para o Traefik —, o que gera dois candidatos
`host` mascarados como o mesmo IP público, e o ICE pode fixar no socket errado.
E o NAT do Docker não garante preservar a porta de origem na saída, então a Meta
recebe mídia de uma porta que não corresponde ao candidato anunciado.

### A solução

**coturn com `network_mode: host`** — zero NAT no caminho da mídia — e
`relay_only = true` no app, que passa a só usar candidatos de relay
([webrtc.go:244](../internal/calling/webrtc.go:244)). O app deixa de precisar de
porta aberta: ele faz conexão de saída para o relay.

Sinal de sucesso nos logs: candidatos `type=relay` em vez de `type=host`, e
`Peer connection state` chegando a `connected`.

### O IP privado no `ice_servers`, e por que

O app aponta para `turn:172.31.21.234:3478`, o IP **privado** da EC2. A AWS não
faz hairpin de tráfego da instância para o próprio IP público, então apontar para
o público simplesmente não conectaria. Quem anuncia o público nos candidatos de
relay é o coturn, pela flag `--external-ip <público>/<privado>`.

### Mas o navegador também recebe essa lista

Esta foi a armadilha mais cara. O endpoint `GET /api/calls/ice-servers` serve
**a mesma lista** ao frontend ([outgoing_calls.go:193](../internal/handlers/outgoing_calls.go:193)),
que a usa no `RTCPeerConnection` ([calling.ts:214](../frontend/src/stores/calling.ts:214)).

O navegador do agente está fora da VPC e não alcança o IP privado. Sem nenhum
STUN, ele gera **apenas candidatos da LAN**. O servidor então cria a permissão
TURN para esse endereço privado, e o coturn **descarta** os pacotes que chegam do
IP público real do agente. A chamada conecta e fica **muda dos dois lados**.

A correção é acrescentar um **STUN público** à lista. O servidor ignora (está em
relay_only) e o navegador o usa para descobrir o próprio endereço.

### Faixa de portas

O relay usa `10001-10040`, faixa que já estava liberada no security group
`sg-83e445e6`. A porta de controle `3478` **não precisa** estar aberta: quem fala
com o coturn é o app, na mesma máquina, e esse tráfego não atravessa o security
group.

---

## 5. Roteamento de chamadas no Whatomate

### Papel no time: `manager` não recebe chamada

A lista de agentes elegíveis filtra `role = agent`
([cache.go:47](../internal/assignment/cache.go:47)). Um membro `manager` é
**ignorado**, e o log diz `No agents online for transfer` mesmo com a pessoa
logada e disponível.

E a interface **não permite editar** o papel de quem já é membro
([TeamDetailView.vue:359](../frontend/src/views/settings/TeamDetailView.vue:359)):
é preciso remover e readicionar como Agent. O cache do time no Redis é
invalidado automaticamente nessa operação ([teams.go:254](../internal/handlers/teams.go:254)).

> Ser administrador da organização **não** substitui o papel no time. O log
> mostra `has_full_access=true` para o admin, o que engana.

### As três condições para um agente receber transferência

1. `is_available = true` — o status Available/Away no menu do usuário
2. `is_active = true`
3. Conexão **WebSocket ativa** ([assigner.go:150](../internal/assignment/assigner.go:150) e `FilterOnlineUsers`)

Mais o papel `agent`, acima.

### Deploy derruba as sessões

Todo redeploy mata as conexões WebSocket, e o frontend **não reconecta sozinho**
— não responde a `online` nem a `visibilitychange`. O agente precisa recarregar a
página, senão fica invisível para o roteamento. Convém deployar fora do horário
de atendimento, ou avisar a equipe para recarregar.

### Nó de Transfer sem saída é terminal

Sem aresta de saída, a ligação morre em silêncio quando ninguém atende
([ivr.go:452](../internal/calling/ivr.go:452)). Com uma aresta, o motor espera o
desfecho e continua o fluxo.

Desfechos: **`completed`** (saída 1), **`no_answer`** (saída 2) e **`abandoned`**
(chamador desligou). O `TransferNode` nomeia as saídas
([TransferNode.vue:21](../frontend/src/components/calling/nodes/TransferNode.vue:21)),
mas o canvas as rotula como "1" e "2".

Fluxo atual do `Main Support`:

```
Greeting → Transfer ──1 completed──→ (encerra)
                     └─2 no_answer─→ "Sem atendente" (TTS) → Hangup
```

---

## 6. CI/CD

`push em main` → workflow `Test` (do upstream) → nosso `Deploy` via
`workflow_run` → imagem no GHCR com as tags `latest` e `<sha>`.

Detalhes que custaram tempo:

- O contexto `secrets` do GitHub Actions **não é acessível em `if:` de step** —
  precisa passar por uma env var intermediária.
- Workflows herdados do upstream que não funcionam no fork (`Build develop
  image`, `Release`, `Deploy Docs`) foram **desabilitados pela API**, não
  apagados — assim o `git merge upstream/main` segue sem conflito.
- O pacote no GHCR herda a visibilidade do repositório. Sendo público, o
  EasyPanel puxa sem credencial.

---

## 7. Custos

WhatsApp Manager → **Insights** → abas **Preços das mensagens** e **Preços das
ligações**, com filtro por número, país e período, e exportação para planilha.
Os valores ali são aproximados; a fatura real está em Business Manager →
Faturamento.

O que **não** gera custo: receber mensagens, responder dentro da janela de 24
horas (conversa de serviço) e **receber chamadas**.

O que gera: templates de marketing e utilidade disparados ativamente, e
**chamadas iniciadas pela empresa**, cobradas por pulso de 6 segundos.
