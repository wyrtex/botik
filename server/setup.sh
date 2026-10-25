#!/usr/bin/env bash
# Botik server: Ollama + uncensored huihui model + password-protected proxy.
# Usage (Ubuntu/Debian VPS, as root):
#   curl -fsSL https://raw.githubusercontent.com/wyrtex/botik/master/server/setup.sh | sudo DOMAIN=ai.example.com bash
# Options (env vars):
#   DOMAIN=ai.example.com  — HTTPS with a free Let's Encrypt certificate (needs ports 80/443
#                            and a DNS A record pointing to this server)
#   PORT=8080              — plain HTTP port, used when DOMAIN is not set
#   MODEL=huihui_ai/qwen3-abliterated:8b
set -euo pipefail

PORT="${PORT:-8080}"
MODEL="${MODEL:-}"
DOMAIN="${DOMAIN:-}"
CONF_DIR=/etc/botik

if [ "$(id -u)" != 0 ]; then
  echo "Запустите от root: sudo bash setup.sh" >&2
  exit 1
fi

say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

if command -v apt-get >/dev/null; then
  say "Устанавливаю зависимости"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates zstd openssl >/dev/null
fi

IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
if [ -n "$DOMAIN" ]; then
  resolved=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)
  if [ "$resolved" != "$IP" ]; then
    echo >&2
    echo "Домен $DOMAIN указывает на '${resolved:-никуда}', а IP этого сервера — $IP." >&2
    echo "Добавьте в DNS A-запись: $DOMAIN → $IP, подождите 5–30 минут и запустите скрипт снова." >&2
    exit 1
  fi
fi

if ! command -v ollama >/dev/null; then
  say "Устанавливаю Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
fi
# Ollama itself stays on 127.0.0.1 — only the protected proxy is exposed.
systemctl enable --now ollama >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
  sleep 1
done

mem_gb=$(awk '/MemTotal/ {print int($2/1024/1024 + 0.5)}' /proc/meminfo)
if [ -z "$MODEL" ]; then
  if   [ "$mem_gb" -ge 14 ]; then MODEL=huihui_ai/qwen3-abliterated:8b
  elif [ "$mem_gb" -ge 7 ];  then MODEL=huihui_ai/qwen3-abliterated:4b
  else                            MODEL=huihui_ai/qwen3-abliterated:1.7b
  fi
fi
say "Скачиваю модель $MODEL (RAM: ${mem_gb} ГБ)"
ollama pull "$MODEL"

if ! command -v caddy >/dev/null; then
  say "Устанавливаю Caddy (прокси с паролем)"
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Неизвестная архитектура $(uname -m)" >&2; exit 1 ;;
  esac
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${arch}" -o /usr/local/bin/caddy
  chmod +x /usr/local/bin/caddy
fi

mkdir -p "$CONF_DIR"
if [ ! -s "$CONF_DIR/key" ]; then
  openssl rand -hex 24 > "$CONF_DIR/key"
  chmod 600 "$CONF_DIR/key"
fi
KEY=$(cat "$CONF_DIR/key")

if [ -n "$DOMAIN" ]; then
  GLOBAL_OPTS="admin off"
  SITE="$DOMAIN"
  OPEN_PORTS="80 443"
  URL="https://${DOMAIN}/v1"
else
  GLOBAL_OPTS=$'admin off\n\tauto_https off'
  SITE=":${PORT}"
  OPEN_PORTS="$PORT"
  URL="http://${IP}:${PORT}/v1"
fi

cat > "$CONF_DIR/Caddyfile" <<EOF
{
	${GLOBAL_OPTS}
}

${SITE} {
	@unauthorized not header Authorization "Bearer ${KEY}"
	respond @unauthorized "Unauthorized" 401

	reverse_proxy 127.0.0.1:11434 {
		header_up Host 127.0.0.1:11434
		flush_interval -1
	}
}
EOF
chmod 600 "$CONF_DIR/Caddyfile"

cat > /etc/systemd/system/botik-proxy.service <<EOF
[Unit]
Description=Botik proxy for Ollama
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Environment=XDG_DATA_HOME=/var/lib/botik-caddy XDG_CONFIG_HOME=/var/lib/botik-caddy
ExecStart=/usr/local/bin/caddy run --config ${CONF_DIR}/Caddyfile --adapter caddyfile
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable botik-proxy >/dev/null 2>&1
systemctl restart botik-proxy

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  for p in $OPEN_PORTS; do ufw allow "${p}/tcp" >/dev/null; done
fi

say "Проверяю подключение (получение сертификата может занять до минуты)"
status="не отвечает — смотрите: journalctl -u botik-proxy -u ollama -n 50"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 10 -H "Authorization: Bearer ${KEY}" "${URL}/models" >/dev/null 2>&1; then
    status="работает ✓"
    break
  fi
  sleep 3
done

cat <<EOF

========================================================
 Сервер: ${status}

 В приложении Botik: Настройки → Добавить сервер → Свой

   Адрес API:  ${URL}
   API-ключ:   ${KEY}
   Модель:     ${MODEL}

 Другая модель:  ollama pull huihui_ai/<имя>
 Показать ключ:  cat ${CONF_DIR}/key
========================================================
EOF
