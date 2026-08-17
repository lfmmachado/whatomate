# deploy/ — infraestrutura do fork

Arquivos de referência para rodar o Whatomate numa VPS Hostinger (Ubuntu 24.04)
com deploy contínuo pelo GitHub Actions.

| Arquivo | Onde vai na VPS |
|---|---|
| `provision-vps.sh` | roda uma vez como root (Fase 2) |
| `whatomate.service` | `/etc/systemd/system/whatomate.service` |
| `Caddyfile` | `/etc/caddy/Caddyfile` (trocar o domínio) |
| `config.production.example.toml` | vira `/opt/whatomate/config.toml` — **nunca commitar o preenchido** |

## Arquitetura

```
GitHub Actions (build do binário)  --scp-->  /opt/whatomate/releases/whatomate-<sha>
                                              |
                                       install -m 0755 -> /opt/whatomate/whatomate
                                              |
                          systemd (whatomate.service, usuário deploy, -migrate)
                                              |
Internet --443/tcp--> Caddy (TLS) --> 127.0.0.1:8080 --> Postgres + Redis (locais)
         --10000-10100/udp------------> mídia WebRTC das chamadas (direto no binário)
```

## Ordem de execução

1. **VPS + DNS**: criar a VPS, apontar `crm.SEUDOMINIO.com.br` (registro A) para o IP
   e esperar propagar — o Caddy precisa disso para emitir o certificado.
2. **Provisionar**: copiar esta pasta para a VPS e rodar como root:
   ```bash
   scp -r deploy root@IP:/root/ && ssh root@IP 'bash /root/deploy/provision-vps.sh'
   ```
   Anotar a senha do Postgres impressa no final.
3. **Config**: criar `/opt/whatomate/config.toml` a partir de
   `config.production.example.toml`, gerando os segredos:
   ```bash
   openssl rand -base64 32   # encryption_key
   openssl rand -base64 32   # jwt.secret
   openssl rand -hex 24      # whatsapp.webhook_verify_token
   ```
4. **Caddy**: copiar o `Caddyfile` com o domínio real e `systemctl reload caddy`.
5. **Chave do CI**: no Mac, `ssh-keygen -t ed25519 -f ~/.ssh/gh-actions-whatomate -C gh-actions`;
   colar a `.pub` em `/home/deploy/.ssh/authorized_keys`.
6. **Secrets no GitHub** (Settings → Secrets and variables → Actions):
   `VPS_HOST`, `VPS_USER` (= `deploy`), `VPS_SSH_KEY` (chave privada inteira).
7. **Primeiro deploy**: Actions → *Deploy* → *Run workflow* (`workflow_dispatch`).
   Depois disso, todo push em `main` que passar no workflow *Test* faz deploy sozinho.

## Segredos que vão para o cofre

`encryption_key` (perder = perder os tokens Meta salvos), `jwt.secret`, senha do
Postgres, `webhook_verify_token`, token permanente da Meta, PIN de duas etapas do
número, chave SSH do CI.

## Operação

```bash
journalctl -u whatomate -f          # logs
systemctl status whatomate          # estado
ls -lt /opt/whatomate/releases      # releases disponíveis (5 últimas)
```

Rollback manual:
```bash
cd /opt/whatomate && sudo cp -f whatomate.previous whatomate && sudo systemctl restart whatomate
```

## Sincronizar com o upstream

```bash
git fetch upstream
git checkout main && git merge upstream/main
git push origin main
```
