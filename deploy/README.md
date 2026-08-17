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

## Serviço no EasyPanel

**Imagem**: `ghcr.io/lfmmachado/whatomate:latest` (pacote privado → cadastrar
credencial do GHCR no EasyPanel, ou tornar o pacote público).

**Domínio**: o subdomínio, porta interna `8080`, TLS pelo EasyPanel.

**Portas publicadas** (além do HTTP): `10000-10040` UDP, **modo host**. Publicar
range em modo ingress do Swarm cria uma regra de iptables por porta e degrada;
host mode entrega o pacote direto no container.

**Volumes**: `/app/uploads` e `/app/audio` persistentes — o segundo guarda os
áudios de IVR gerados pelo TTS.

**File mount**: o conteúdo de [`config.mount.toml`](config.mount.toml) em
`/app/config.toml`.

### Variáveis de ambiente

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
