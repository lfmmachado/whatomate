# deploy/ — Whatomate na AWS EC2 + EasyPanel

Alvo: instância `i-0efb95cd982d8fcd1` (t2.medium, x86_64, Ubuntu 24.04, us-east-1)
com Docker + EasyPanel já em produção, **Postgres num RDS existente** e Redis novo
criado no próprio EasyPanel.

## Estado atual (04/10/2026)

O que já está em produção e o que falta. Esta seção existe para que ninguém
precise reconstruir o contexto de memória.

**Funcionando:**

| Peça | Valor / estado |
|---|---|
| App | `https://chat.mooviin.app` — TLS pelo Traefik do EasyPanel |
| CI/CD | push em `main` → Test → Deploy → `ghcr.io/lfmmachado/whatomate` |
| Número oficial | +55 62 98117-3298, verificado e inscrito na Cloud API |
| Phone Number ID | `1367400226457038` |
| WABA de produção | `26223828377295937` (nome de exibição "Mooviin App") |
| App Meta | `MooviinApp` — `28243501641947570` |
| Token | System User `Whatomate` (`61595121330029`), permanente, escopos de messaging + management |
| Webhooks app↔WABA | assinados; campos `messages`, `calls`, `message_template_status_update` |
| Mensagens | fluxo completo validado (recebe, aparece no Chat, responde) |
| Chamadas na Meta | habilitadas no número |
| Whatomate | org com calling ligado, team `Unique`, fluxo IVR `Main Support` |

**Pendente:**

- **coturn não implantado.** O compose deste repositório já traz o serviço, mas o
  painel do EasyPanel ainda roda a versão anterior. Enquanto isso, chamadas
  falham com ICE conectando e DTLS estourando em 15s — áudio mudo. Aplicar
  exige: liberar `3478` tcp+udp e `49160-49200` udp no security group, criar os
  dois arquivos no host com o mesmo segredo, e colar o compose novo.
- **Sem Elastic IP.** O IP `3.93.191.20` é auto-atribuído e muda em stop/start.
- **Nome de exibição em análise** na Meta — limita envio ativo, não recebimento.
- O número de teste `+1 555 630-7921` (WABA `3623352957803820`) continua
  existindo, mas a conta no Whatomate não aponta mais para ele.

## Arquitetura

```
GitHub Actions  --build--> ghcr.io/lfmmachado/whatomate:latest
                                    |
                        webhook de deploy do EasyPanel (pull + restart)
                                    |
Internet --443/tcp--> Traefik (EasyPanel, TLS) --> app:8080   [rede overlay]
                                    |
                        RDS Postgres (externo)  +  Redis (serviço EasyPanel)

Meta --3478 + 49160-49200/udp--> coturn [network_mode: host] <--> app
```

O Traefik só trata HTTP, e a mídia das chamadas não passa por ele.

**A mídia também não passa pelo container do app.** Tentamos isso primeiro,
publicando 41 portas UDP, e não funciona: o ICE conecta mas o DTLS nunca fecha,
e a chamada fica muda. Duas causas concorrem. O container do app precisa estar
em duas redes (a do projeto, para o Redis, e a overlay, para o Traefik), o que
gera dois candidatos `host` mascarados como o mesmo IP público — o ICE pode
fixar no socket errado. E o NAT do Docker não garante que a porta de origem da
saída seja a mesma anunciada no candidato.

Por isso o coturn: ele roda com `network_mode: host`, sem NAT nenhum no
caminho, e o app fala com ele por conexão de saída (`relay_only = true`). O app
deixa de precisar de qualquer porta aberta.

Detalhe que morde: o app aponta para o coturn pelo **IP privado**
(`172.31.21.234`), não pelo público. A AWS não faz hairpin de tráfego da
instância para o próprio IP público. Quem anuncia o público nos candidatos de
relay é o coturn, pela diretiva `external-ip`.

## Pré-requisitos na AWS (fazer antes de configurar o EasyPanel)

1. **Security Group**: liberar `3478` em **TCP e UDP** e `49160-49200` em UDP,
   a partir de `0.0.0.0/0` — são o controle e a mídia do coturn. Não dá para
   restringir por origem: a mídia vem dos servidores da Meta, que não publicam
   faixa fixa. (80 e 443 TCP já devem estar abertos pelo EasyPanel.)
   A faixa `10000-10040` da tentativa anterior pode ser removida.
2. **RDS**: o security group do `wgl-postgres-rds` precisa aceitar `5432` vindo
   do SG da EC2.
3. **DNS**: registro A de `chat.mooviin.app` → `3.93.191.20`.
4. **Elastic IP — pendência conhecida.** Estamos usando o IP auto-atribuído
   (`3.93.191.20`), que **muda em qualquer stop/start da instância**. Ele está
   fixo no `external-ip` do `turnserver.conf` e no registro A, então um restart
   derruba as chamadas em silêncio: mensagens seguem funcionando e o sintoma é
   ligação que conecta muda. Enquanto não houver EIP, todo restart exige editar
   o `turnserver.conf`, reiniciar o coturn e corrigir o DNS.

## Banco no RDS

Conectando como usuário master do RDS:

```sql
CREATE USER whatomate WITH PASSWORD 'SENHA_FORTE';
CREATE DATABASE whatomate OWNER whatomate;
```

As migrations rodam sozinhas: o `CMD` da imagem já inclui `-migrate`, que é
idempotente.

## Estado da máquina (medido em 17/08/2026)

`docker=28.4.0`, `swarm=active`, Traefik 3.6.7. Já rodam ali Chatwoot (+sidekiq),
n8n, Evolution API, ePolítico (api+web), um pgbouncer e um `wgl_redis`.

RAM: 3,8 Gi totais, ~600 Mi disponíveis, **swap zero**. Antes de subir qualquer
coisa, criar 4 GB de swap — o IVR gera áudio invocando `piper`, `ffmpeg` e
`opusenc` como processos filhos, e esses picos acionariam o OOM killer contra os
outros apps:

```bash
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
```

O `deploy.resources.limits.memory` do compose (1 G para o app, 192 M para o
Redis) é a segunda camada dessa proteção: limita o estrago ao próprio serviço.

> `wgl_redis` está escutando em `0.0.0.0:6379`. Não é do Whatomate — mas vale
> conferir se o security group expõe essa porta para a internet.

## Serviço no EasyPanel

Usar o tipo **Compose**, com o conteúdo de
[`easypanel-compose.yml`](easypanel-compose.yml). Ele define o app e o Redis
dedicado.

O tipo Compose é necessário porque o coturn precisa de `network_mode: host`, que
a tela padrão de serviço não oferece. O app em si não publica porta alguma.

**Imagem**: `ghcr.io/lfmmachado/whatomate:latest` (pacote privado → cadastrar
credencial do GHCR no EasyPanel, ou tornar o pacote público).

**Domínio**: configurar no painel apontando para a porta `8080` do serviço
`whatomate`; o TLS é do EasyPanel.

**Arquivos no host** (criados à mão, com os segredos reais):

- `/etc/easypanel/projects/whatomate/config.toml` — de
  [`config.mount.toml`](config.mount.toml), com o segredo do TURN
- `/etc/easypanel/projects/whatomate/turnserver.conf` — de
  [`coturn/turnserver.conf`](coturn/turnserver.conf), com o **mesmo** segredo

Os dois precisam carregar valores idênticos em `secret` e `static-auth-secret`;
se divergirem, o coturn recusa a alocação e a chamada volta a ficar muda.

### Variáveis de ambiente

Na aba de ambiente do EasyPanel. O compose referencia estas: `WHATOMATE_DOMAIN`,
`WHATOMATE_ENCRYPTION_KEY`, `WHATOMATE_JWT_SECRET`, `RDS_HOST`, `RDS_PASSWORD`,
`META_VERIFY_TOKEN`, `META_APP_ID`, `META_APP_SECRET`, `PUBLIC_IP`,
`ADMIN_EMAIL`, `ADMIN_PASSWORD`.

A lista abaixo é a forma expandida, caso você prefira declarar cada `WHATOMATE_*`
diretamente em vez de usar o compose:

O app aceita tudo por env com prefixo `WHATOMATE_` e `__` separando a seção
([config.go:210](../internal/config/config.go:210)). O arquivo é lido primeiro e
as env vars sobrescrevem — por isso os segredos ficam só aqui.

```env
TZ=America/Sao_Paulo

WHATOMATE_APP__ENVIRONMENT=production
WHATOMATE_APP__DEBUG=false
WHATOMATE_APP__ENCRYPTION_KEY=        # openssl rand -base64 32

WHATOMATE_SERVER__HOST=0.0.0.0        # o Traefik alcança pela rede do Docker
WHATOMATE_SERVER__PORT=8080
WHATOMATE_SERVER__ALLOWED_ORIGINS=https://chat.mooviin.app

WHATOMATE_DATABASE__HOST=wgl-postgres-rds.cwzwwdv44095.us-east-1.rds.amazonaws.com
WHATOMATE_DATABASE__PORT=5432
WHATOMATE_DATABASE__USER=whatomate
WHATOMATE_DATABASE__PASSWORD=
WHATOMATE_DATABASE__NAME=whatomate
WHATOMATE_DATABASE__SSL_MODE=require  # RDS aceita TLS; não usar disable

WHATOMATE_REDIS__HOST=whatomate-redis # nome do serviço no compose
WHATOMATE_REDIS__PORT=6379
WHATOMATE_REDIS__PASSWORD=

WHATOMATE_JWT__SECRET=                # openssl rand -base64 32

WHATOMATE_STORAGE__TYPE=local
WHATOMATE_STORAGE__LOCAL_PATH=/app/uploads

WHATOMATE_WHATSAPP__WEBHOOK_VERIFY_TOKEN=   # openssl rand -hex 24; igual no painel da Meta
WHATOMATE_WHATSAPP__API_VERSION=v24.0
WHATOMATE_WHATSAPP__APP_ID=
WHATOMATE_WHATSAPP__APP_SECRET=

WHATOMATE_COOKIE__SECURE=true
WHATOMATE_RATE_LIMIT__ENABLED=true
WHATOMATE_RATE_LIMIT__TRUST_PROXY=true      # atrás do Traefik; sem isso todo IP vira o do proxy

WHATOMATE_TTS__PIPER_BINARY=/usr/local/bin/piper
WHATOMATE_TTS__PIPER_MODEL=/opt/piper/models/pt_BR-faber-medium.onnx

WHATOMATE_CALLING__AUDIO_DIR=/app/audio
WHATOMATE_CALLING__MAX_CALL_DURATION=3600
WHATOMATE_CALLING__TRANSFER_TIMEOUT_SECS=120
WHATOMATE_CALLING__RECORDING_ENABLED=false  # true exige storage S3
WHATOMATE_CALLING__RELAY_ONLY=true          # toda a mídia pelo coturn
WHATOMATE_CALLING__PUBLIC_IP=               # vazio: conflita com relay_only

WHATOMATE_DEFAULT_ADMIN__EMAIL=
WHATOMATE_DEFAULT_ADMIN__PASSWORD=          # trocar no primeiro login
WHATOMATE_DEFAULT_ADMIN__FULL_NAME=Luiz Fernando
```

> ⚠️ As três `DEFAULT_ADMIN` são obrigatórias. A imagem embute o
> `config.example.toml`, que traz `admin@admin.com` / `admin` — não sobrescrever
> isso deixa um login default conhecido no ar.

## CI/CD

[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) dispara quando o
workflow `Test` do upstream passa em `main`, builda `docker/Dockerfile` para
`linux/amd64`, publica no GHCR com as tags `latest` e `<sha>`, e chama o webhook
de deploy do EasyPanel.

Secret necessário: `EASYPANEL_DEPLOY_WEBHOOK` (Settings → Secrets → Actions). Sem
ele o build acontece e o deploy fica manual pelo painel.

Rollback: apontar o serviço para `ghcr.io/lfmmachado/whatomate:<sha-anterior>`.

## Verificação

```bash
curl -sf https://chat.mooviin.app/ready && echo OK   # checa banco e Redis
docker ps --filter name=whatomate
docker logs -f $(docker ps -qf name=whatomate)
```

Nos logs de uma chamada, os candidatos ICE aparecem com tipo e endereço
([webrtc.go:314](../internal/calling/webrtc.go:314)) — se o `address` do candidato
`host` for `172.31.x.x` em vez do IP público, o `public_ip` não pegou.

## Sincronizar com o upstream

```bash
git fetch upstream && git checkout main && git merge upstream/main && git push origin main
```

O único arquivo do upstream que customizamos é [`docker/Dockerfile`](../docker/Dockerfile)
(voz PT-BR do Piper) — é onde conflito pode aparecer.
