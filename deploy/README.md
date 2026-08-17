# deploy/ — Whatomate na AWS EC2 + EasyPanel

Alvo: instância `i-0efb95cd982d8fcd1` (t2.medium, x86_64, Ubuntu 24.04, us-east-1)
com Docker + EasyPanel já em produção, **Postgres num RDS existente** e Redis novo
criado no próprio EasyPanel.

## Arquitetura

```
GitHub Actions  --build--> ghcr.io/lfmmachado/whatomate:latest
                                    |
                        webhook de deploy do EasyPanel (pull + restart)
                                    |
Internet --443/tcp--> Traefik (EasyPanel, TLS) --> app:8080
         --10000-10040/udp--------------------->  mídia WebRTC (direto no container)
                                    |
                        RDS Postgres (externo)  +  Redis (serviço EasyPanel)
```

O Traefik só trata HTTP. A mídia das chamadas **não passa por ele**: o binário
abre portas UDP próprias ([webrtc.go:282](../internal/calling/webrtc.go:282)) e
anuncia o IP público como candidato ICE. Daí as duas exigências abaixo.

## Pré-requisitos na AWS (fazer antes de configurar o EasyPanel)

1. **Elastic IP.** O IP atual (`3.93.191.20`) é auto-atribuído e muda em qualquer
   stop/start. Como ele vai fixo em `calling.public_ip`, trocar de IP quebra as
   chamadas em silêncio. Alocar um EIP e associar à instância.
2. **Security Group**: liberar `UDP 10000-10040` a partir de `0.0.0.0/0`. Não dá
   para restringir por origem — a mídia vem dos servidores da Meta, que não
   publicam faixa fixa. (80 e 443 TCP já devem estar abertos pelo EasyPanel.)
3. **RDS**: o security group do RDS precisa aceitar `5432` vindo do SG da EC2.
4. **DNS**: registro A do subdomínio → Elastic IP.

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

O motivo de não usar a tela padrão de serviço: o range UDP precisa ser publicado
em `mode: host`. No modo ingress (padrão do Swarm) o IPVS faz SNAT nos pacotes, o
container vê um endereço de origem mascarado e o ICE falha — a chamada conecta e
fica muda. E como o Swarm não aceita range na sintaxe longa, são 41 entradas de
porta, uma por vez.

**Imagem**: `ghcr.io/lfmmachado/whatomate:latest` (pacote privado → cadastrar
credencial do GHCR no EasyPanel, ou tornar o pacote público).

**Domínio**: configurar no painel apontando para a porta `8080` do serviço
`whatomate`; o TLS é do EasyPanel.

**File mount**: o conteúdo de [`config.mount.toml`](config.mount.toml) em
`/app/config.toml` (o caminho do host já está referenciado no compose).

### Variáveis de ambiente

Na aba de ambiente do EasyPanel. O compose referencia estas: `WHATOMATE_DOMAIN`,
`WHATOMATE_ENCRYPTION_KEY`, `WHATOMATE_JWT_SECRET`, `RDS_HOST`, `RDS_PASSWORD`,
`META_VERIFY_TOKEN`, `META_APP_ID`, `META_APP_SECRET`, `ELASTIC_IP`,
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
WHATOMATE_SERVER__ALLOWED_ORIGINS=https://SEU.SUBDOMINIO

WHATOMATE_DATABASE__HOST=SEU-RDS.us-east-1.rds.amazonaws.com
WHATOMATE_DATABASE__PORT=5432
WHATOMATE_DATABASE__USER=whatomate
WHATOMATE_DATABASE__PASSWORD=
WHATOMATE_DATABASE__NAME=whatomate
WHATOMATE_DATABASE__SSL_MODE=require  # RDS aceita TLS; não usar disable

WHATOMATE_REDIS__HOST=                # nome do serviço Redis no EasyPanel
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
WHATOMATE_CALLING__UDP_PORT_MIN=10000
WHATOMATE_CALLING__UDP_PORT_MAX=10040
WHATOMATE_CALLING__PUBLIC_IP=               # o Elastic IP

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
curl -sf https://SEU.SUBDOMINIO/ready && echo OK   # checa banco e Redis
docker ps --filter name=whatomate
docker logs -f $(docker ps -qf name=whatomate)
```

Nos logs de uma chamada, os candidatos ICE aparecem com tipo e endereço
([webrtc.go:314](../internal/calling/webrtc.go:314)) — se o `address` do candidato
`host` for `172.31.x.x` em vez do Elastic IP, o `public_ip` não pegou.

## Sincronizar com o upstream

```bash
git fetch upstream && git checkout main && git merge upstream/main && git push origin main
```

O único arquivo do upstream que customizamos é [`docker/Dockerfile`](../docker/Dockerfile)
(voz PT-BR do Piper) — é onde conflito pode aparecer.
