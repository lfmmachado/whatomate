# deploy/ — Whatomate da Mooviin

Implantação do fork numa EC2 com Docker + EasyPanel, Postgres num RDS existente,
e chamadas WhatsApp com mídia relayada por coturn.

**Está tudo funcionando**: mensagens e chamadas, com IVR em português,
transferência para agente e áudio nos dois sentidos.

Para *por que* cada decisão foi tomada e as armadilhas que custaram caro, veja
[`REFERENCIA.md`](REFERENCIA.md). Este arquivo é o operacional.

## Identificadores

| | |
|---|---|
| App | `https://chat.mooviin.app` |
| Número oficial | +55 62 98117-3298 (a Meta exibe `+55 62 8117-3298`) |
| Phone Number ID | `1367400226457038` |
| WABA de produção | `26223828377295937` |
| App Meta | `MooviinApp` — `28243501641947570` |
| System User | `Whatomate` — `61595121330029`, token sem expiração |
| EC2 | `i-0efb95cd982d8fcd1` — t2.medium, us-east-1, `3.93.191.20` |
| RDS | `wgl-postgres-rds.cwzwwdv44095.us-east-1.rds.amazonaws.com` |
| Security group | `sg-83e445e6` (default) |

## Arquitetura

```
GitHub Actions ──build──> ghcr.io/lfmmachado/whatomate:latest
                                   │
Internet ──443/tcp──> Traefik (EasyPanel, TLS) ──> whatomate:8080   [rede easypanel]
                                   │
                    RDS Postgres (externo) + whatomate-redis

Meta ──10001-10040/udp──> coturn [network_mode: host] <──relay── whatomate
```

A mídia das chamadas **não passa pelo Traefik nem pelo container do app**: ela
vai pelo coturn, que roda em rede host para não ter NAT do Docker no caminho. O
app fala com o relay por conexão de saída (`relay_only = true`).

## Instalação do zero

### 1. AWS

No security group da instância, entrada a partir de `0.0.0.0/0`:

| Porta | Protocolo | Para quê |
|---|---|---|
| 80, 443 | TCP | Traefik |
| 10001-10040 | UDP | mídia relayada pelo coturn |

A porta `3478` do coturn **não** precisa ser exposta: quem fala com ela é o app,
na mesma máquina.

No security group do RDS, liberar `5432` vindo do SG da EC2. E um registro A de
`chat.mooviin.app` apontando para o IP público, **sem proxy** (na Cloudflare,
nuvem cinza — o proxy não encaminha UDP e quebraria a mídia).

### 2. Swap

A instância tem 3,8 Gi e o IVR gera áudio invocando `piper`, `ffmpeg` e
`opusenc`. Sem swap, esses picos acionam o OOM killer contra os outros apps da
máquina.

```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
```

### 3. Banco no RDS

Como usuário master. O `GRANT` é necessário no PostgreSQL 16+: criar um banco com
outro dono exige ser membro desse papel.

```sql
CREATE USER whatomate WITH PASSWORD 'SENHA_FORTE';
GRANT whatomate TO CURRENT_USER;
CREATE DATABASE whatomate OWNER whatomate;
```

As migrations rodam sozinhas no boot (`-migrate` é idempotente).

### 4. Serviço no EasyPanel

Tipo **Compose**, com o conteúdo de [`easypanel-compose.yml`](easypanel-compose.yml).

Na aba **Environment**, cole as variáveis de
[`easypanel.env.example`](easypanel.env.example) preenchidas, e **ligue o
interruptor `Create .env file`**. Sem ele o docker compose não resolve os
`${...}` e o app sobe com segredos vazios.

Em **Domains**, aponte `chat.mooviin.app` para o serviço `whatomate`, porta
`8080`, com TLS.

Gere o segredo do TURN com `openssl rand -hex 32`. Ele vai na variável
`TURN_SECRET` e é usado nos dois lados (app e coturn) pela interpolação.

### 5. Meta

No app do developers.facebook.com, produto WhatsApp:

- **Webhook**: `https://chat.mooviin.app/api/webhook` com o verify token
- **Campos**: `messages`, `calls`, `message_template_status_update`
- **Assinar webhooks** no WABA (é um passo separado de salvar a URL)
- **Chamadas**: WhatsApp Manager → número → Mais → Configurações de ligação →
  "Permitir ligações de voz"

No Whatomate, Settings → Accounts → Add Account com App ID, App Secret, Phone
Number ID, WABA ID e Access Token, marcando como default de entrada e saída.

### 6. Time e IVR

Settings → Teams → criar o time e adicionar as pessoas **como Agent**. Membros
com papel `manager` não recebem chamada.

Calling → IVR Flows → fluxo marcado como *Active* e *Incoming Call Start*, com o
nó de Transfer tendo uma saída em `no_answer` — sem ela a ligação morre em
silêncio quando ninguém atende.

## Operação

### Deploy

Push em `main` → o workflow `Test` do upstream roda → nosso `Deploy` builda e
publica no GHCR. Depois, **Deploy** no painel do EasyPanel para puxar a imagem.

> Todo deploy derruba as sessões WebSocket e o frontend não reconecta sozinho.
> Os agentes precisam recarregar a página, senão ficam invisíveis para o
> roteamento de chamadas. Prefira deployar fora do horário de atendimento.

### Verificação

```bash
curl -sS https://chat.mooviin.app/ready
```

`/ready` valida banco e Redis de verdade; `/health` só diz que o processo subiu.

Para confirmar que a imagem nova entrou mesmo, compare o hostname do container
antes e depois — se não mudou, o deploy não trocou nada.

### Diagnóstico de chamada

```bash
docker logs -f $(docker ps -qf name=whatomate-whatomate) 2>&1 | grep -iE "ICE|peer connection|transfer"
```

O que procurar:

| Sinal | Significado |
|---|---|
| `type=relay` nos candidatos | o coturn está sendo usado, como esperado |
| `type=host` | relay_only não pegou — a mídia vai falhar |
| `Peer connection state=connected` | DTLS fechou, áudio deve fluir |
| `No agents online for transfer` | ninguém elegível: ver papel `agent`, status e WebSocket |

### Rollback

Aponte o serviço para `ghcr.io/lfmmachado/whatomate:<sha-anterior>` no compose e
faça deploy.

### Sincronizar com o upstream

```bash
git fetch upstream && git checkout main && git merge upstream/main && git push origin main
```

O único arquivo compartilhado que customizamos é
[`docker/Dockerfile`](../docker/Dockerfile), por causa da voz PT-BR do Piper — é
onde conflito pode aparecer.

## Pendências

- **Sem Elastic IP.** O `3.93.191.20` é auto-atribuído e muda em qualquer
  stop/start da instância. Ele está fixo no `--external-ip` do coturn e no
  registro A. Um restart derruba as chamadas em silêncio: mensagens continuam
  funcionando e o único sintoma é ligação que conecta muda. Alocar um EIP
  encerra o assunto.
- **Nome de exibição em análise** na Meta, o que limita envio ativo até aprovar.
- **`t2.medium` tem créditos de CPU burstable.** Ponte WebRTC é CPU contínua; em
  chamada longa o crédito pode esgotar e o áudio picotar. Monitorar
  `CPUCreditBalance`; `t3.medium` com unlimited resolve.
- **Healthcheck simplificado.** Testa só a porta via `/dev/tcp`, porque a imagem
  não tinha `curl` quando foi escrito. A imagem atual já tem — dá para voltar à
  checagem completa em `/ready`, cuja linha está pronta em comentário no compose.
- **Backup do Postgres** não foi configurado nesta implantação. O RDS tem
  snapshot automático, mas vale confirmar a janela e testar um restore.
- **`wgl_redis`** (de outro app na mesma máquina) escuta em `0.0.0.0:6379`. Não é
  deste projeto, mas vale conferir se o security group expõe essa porta.
