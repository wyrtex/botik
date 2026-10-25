#!/usr/bin/env bash
# Botik server: Ollama + uncensored huihui model + password-protected proxy.
# Usage (Ubuntu/Debian VPS, as root):
#   curl -fsSL https://raw.githubusercontent.com/wyrtex/botik/master/server/setup.sh | sudo bash
# Options (env vars): MODEL=huihui_ai/qwen3-abliterated:8b PORT=8080
set -euo pipefail

PORT="${PORT:-8080}"
MODEL="${MODEL:-}"
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

cat > "$CONF_DIR/Caddyfile" <<EOF
{
	admin off
	auto_https off
}

:${PORT} {
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
ExecStart=/usr/local/bin/caddy run --config ${CONF_DIR}/Caddyfile --adapter caddyfile
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable botik-proxy >/dev/null 2>&1
systemctl restart botik-proxy

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null
fi

sleep 2
IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
if curl -fsS -H "Authorization: Bearer ${KEY}" "http://127.0.0.1:${PORT}/v1/models" >/dev/null; then
  status="работает ✓"
else
  status="не отвечает — смотрите: journalctl -u botik-proxy -u ollama -n 50"
fi

cat <<EOF

========================================================
 Сервер: ${status}

 В приложении Botik: Настройки → Добавить сервер → Свой

   Адрес API:  http://${IP}:${PORT}/v1
   API-ключ:   ${KEY}
   Модель:     ${MODEL}

 Другая модель:  ollama pull huihui_ai/<имя>
 Показать ключ:  cat ${CONF_DIR}/key
========================================================
EOF
