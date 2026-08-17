#!/usr/bin/env bash
# Provisionamento da VPS Hostinger (Ubuntu 24.04) — Fase 2 do plano.
# Rodar como root, uma única vez:  bash provision-vps.sh
# Não cria o config.toml nem gera segredos: isso é feito manualmente depois.
set -euo pipefail

DEPLOY_USER=deploy
APP_DIR=/opt/whatomate
PIPER_VOICE=pt_BR-faber-medium

echo "==> 1. Usuário de deploy"
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
	adduser --disabled-password --gecos "" "$DEPLOY_USER"
	usermod -aG sudo "$DEPLOY_USER"
fi
mkdir -p "/home/$DEPLOY_USER/.ssh"
chmod 700 "/home/$DEPLOY_USER/.ssh"
[ -f /root/.ssh/authorized_keys ] && cp /root/.ssh/authorized_keys "/home/$DEPLOY_USER/.ssh/"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"

echo "==> 2. Endurecimento do SSH (sem senha) + updates automáticos"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh || systemctl reload sshd
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> 3. Firewall"
DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 10000:10100/udp # mídia WebRTC das chamadas
ufw --force enable
# LEMBRETE: o firewall do painel da Hostinger é independente — liberar as mesmas portas lá.

echo "==> 4. Runtime: Postgres, Redis, Caddy, TTS"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
	postgresql redis-server espeak-ng opus-tools curl wget gnupg debian-keyring debian-archive-keyring apt-transport-https

if ! command -v caddy >/dev/null 2>&1; then
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
		gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' |
		tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
	apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
fi
systemctl enable --now postgresql redis-server caddy

echo "==> 5. Banco de dados"
DB_PASS=$(openssl rand -base64 24 | tr -d '/+=')
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='whatomate'" | grep -q 1; then
	sudo -u postgres psql -c "CREATE USER whatomate WITH PASSWORD '${DB_PASS}';"
	sudo -u postgres psql -c "CREATE DATABASE whatomate OWNER whatomate;"
	echo "-------------------------------------------------------------"
	echo "SENHA DO POSTGRES (copiar para o config.toml e para o cofre):"
	echo "  ${DB_PASS}"
	echo "-------------------------------------------------------------"
else
	echo "usuário whatomate já existe — senha preservada"
fi

echo "==> 6. Piper TTS (voz PT-BR para o IVR)"
if ! command -v piper >/dev/null 2>&1; then
	cd /tmp
	wget -q https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz
	tar xf piper_linux_x86_64.tar.gz
	mv piper/piper /usr/local/bin/
	mv piper/*.so* /usr/local/lib/ 2>/dev/null || true
	ldconfig
fi
mkdir -p /opt/piper/models
BASE=https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium
[ -f "/opt/piper/models/${PIPER_VOICE}.onnx" ] ||
	wget -q "${BASE}/${PIPER_VOICE}.onnx" -O "/opt/piper/models/${PIPER_VOICE}.onnx"
[ -f "/opt/piper/models/${PIPER_VOICE}.onnx.json" ] ||
	wget -q "${BASE}/${PIPER_VOICE}.onnx.json" -O "/opt/piper/models/${PIPER_VOICE}.onnx.json"

echo "==> 7. Estrutura da aplicação"
mkdir -p "$APP_DIR"/{audio,uploads,releases}
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"

echo "==> 8. systemd + sudoers do CI"
install -m 0644 "$(dirname "$0")/whatomate.service" /etc/systemd/system/whatomate.service
cat >/etc/sudoers.d/whatomate-deploy <<EOF
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart whatomate, /usr/bin/systemctl status whatomate, /usr/bin/systemctl is-active whatomate
EOF
chmod 0440 /etc/sudoers.d/whatomate-deploy
visudo -c
systemctl daemon-reload
systemctl enable whatomate # ainda não inicia: falta o binário e o config.toml

echo "==> 9. Backup diário do Postgres (rotação de 7 dias)"
cat >/etc/cron.d/whatomate-backup <<EOF
0 3 * * * postgres pg_dump whatomate | gzip > ${APP_DIR}/backup-\$(date +\%u).sql.gz
EOF

cat <<'FIM'

==> Provisionamento concluído. Falta fazer à mão:
  1. Criar /opt/whatomate/config.toml a partir de deploy/config.production.example.toml
     (gerar encryption_key e jwt.secret com: openssl rand -base64 32)
  2. Ajustar o domínio no /etc/caddy/Caddyfile (copiar de deploy/Caddyfile) e: systemctl reload caddy
  3. Gerar a chave SSH do CI no seu Mac e colar a pública em /home/deploy/.ssh/authorized_keys
  4. Liberar 80/443/tcp e 10000-10100/udp também no firewall do painel da Hostinger
FIM
