#!/usr/bin/env bash
#==============================================================================
# OpenClaw Provisioning Script — Hetzner Minimal VDS
# z.ai (GLM4.7) + OpenRouter Fallbacks Configuration
#==============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

#==============================================================================
# КОНФИГУРАЦИЯ ПРОЕКТА
#==============================================================================

ZAI_KEY="${ZAI_API_KEY:-}"
OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"

# Основной провайдер
PRIMARY_PROVIDER="z.ai"
PRIMARY_MODEL="glm4.7"

# Резервный провайдер (OpenRouter)
FALLBACK_PROVIDER="openrouter"
FALLBACK_MODELS="google/gemini-2.5-flash,moonshotai/kimi-k2.5"

OC_USER="openclaw"
OC_DIR="/home/$OC_USER/openclaw"
GATEWAY_PORT=18789

#==============================================================================
# ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ
#==============================================================================

echo -e "\n${CYAN}==============================================${NC}"
echo -e "${GREEN}  Установка OpenClaw (z.ai + OpenRouter)      ${NC}"
echo -e "${CYAN}==============================================${NC}\n"

if [ -z "$ZAI_KEY" ]; then
    err "ZAI_API_KEY не задан.\nЗапустите: export ZAI_API_KEY=\"ваш-ключ\""
fi
if [ -z "$OPENROUTER_KEY" ]; then
    err "OPENROUTER_API_KEY не задан.\nЗапустите: export OPENROUTER_API_KEY=\"ваш-ключ\""
fi
if ! command -v apt &>/dev/null; then
    err "Этот скрипт работает только на Ubuntu/Debian."
fi

#==============================================================================
# ФАЗА 1: Обновление системы (и защита от зависания ядра Hetzner)
#==============================================================================

if [ -f /tmp/.openclaw-setup-rebooted ]; then
    log "Возобновление установки после перезагрузки..."
    rm -f /tmp/.openclaw-setup-rebooted
    SCRIPT_PATH=$(readlink -f "$0")
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
else
    log "Обновление системных пакетов..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq

    if [ -f /var/run/reboot-required ]; then
        warn "Ядро обновлено — требуется перезагрузка."
        touch /tmp/.openclaw-setup-rebooted
        SCRIPT_PATH=$(readlink -f "$0")
        CRON_LINE="@reboot ZAI_API_KEY=\"$ZAI_KEY\" OPENROUTER_API_KEY=\"$OPENROUTER_KEY\" bash $SCRIPT_PATH"
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_LINE") | crontab -

        log "Перезагрузка через 3 секунды. Скрипт продолжит работу автоматически..."
        sleep 3
        reboot
        exit 0
    fi
fi

#==============================================================================
# ФАЗА 2: Установка зависимостей
#==============================================================================

log "Установка зависимостей (включая dbus-user-session)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git build-essential ufw jq unzip dbus-user-session nodejs npm

#==============================================================================
# ФАЗА 3: Настройка пользователя openclaw
#==============================================================================

if id "$OC_USER" &>/dev/null; then
    info "Пользователь '$OC_USER' уже существует."
else
    log "Создание пользователя '$OC_USER'..."
    useradd -m -s /bin/bash "$OC_USER"
    usermod -aG sudo "$OC_USER"
    echo "$OC_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$OC_USER
    chmod 440 /etc/sudoers.d/$OC_USER
fi

loginctl enable-linger "$OC_USER"
log "Linger включен для $OC_USER (нужно для systemd)."

# Копирование SSH ключей рута к пользователю
if [ -d /root/.ssh ]; then
    OC_SSH_DIR="/home/$OC_USER/.ssh"
    mkdir -p "$OC_SSH_DIR"
    cp /root/.ssh/authorized_keys "$OC_SSH_DIR/" 2>/dev/null || true
    chown -R "$OC_USER:$OC_USER" "$OC_SSH_DIR"
    chmod 700 "$OC_SSH_DIR"
    chmod 600 "$OC_SSH_DIR/authorized_keys" 2>/dev/null || true
fi

#==============================================================================
# ФАЗА 4: Настройка файрвола (UFW)
#==============================================================================

log "Настройка UFW..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow ssh >/dev/null
ufw allow $GATEWAY_PORT/tcp >/dev/null
ufw --force enable >/dev/null
log "Порт $GATEWAY_PORT и SSH открыты."

#==============================================================================
# ФАЗА 5: Установка и настройка OpenClaw
#==============================================================================

log "Клонирование репозитория OpenClaw..."
sudo -u "$OC_USER" bash -c "
    if [ ! -d '$OC_DIR' ]; then
        git clone https://github.com/mortalezz/openclaw.git '$OC_DIR'
    fi
    cd '$OC_DIR'
    npm install
"

log "Создание файла .env..."
cat <<EOF > "$OC_DIR/.env"
# Настройки порта
PORT=$GATEWAY_PORT

# Основной провайдер
PRIMARY_PROVIDER=$PRIMARY_PROVIDER
PRIMARY_MODEL=$PRIMARY_MODEL
ZAI_API_KEY=$ZAI_KEY

# Резервный провайдер
FALLBACK_PROVIDER=$FALLBACK_PROVIDER
FALLBACK_MODELS=$FALLBACK_MODELS
OPENROUTER_API_KEY=$OPENROUTER_KEY

LOG_LEVEL=info
EOF
chown "$OC_USER:$OC_USER" "$OC_DIR/.env"

#==============================================================================
# ФАЗА 6: Настройка Systemd сервиса
#==============================================================================

log "Настройка сервиса systemd..."
SERVICE_PATH="/etc/systemd/system/openclaw.service"

cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=OpenClaw AI Gateway
After=network.target

[Service]
Type=simple
User=$OC_USER
WorkingDirectory=$OC_DIR
ExecStart=/usr/bin/npm start
Restart=on-failure
RestartSec=5
EnvironmentFile=$OC_DIR/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw
systemctl restart openclaw

#==============================================================================
# ФИНАЛ
#==============================================================================

echo -e "\n${GREEN}=================================================${NC}"
echo -e "${GREEN} Установка OpenClaw успешно завершена! ${NC}"
echo -e " Основная модель: ${CYAN}z.ai ($PRIMARY_MODEL)${NC}"
echo -e " Резерв: ${YELLOW}OpenRouter${NC}"
echo -e " Порт Gateway: ${CYAN}$GATEWAY_PORT${NC}"
echo -e ""
echo -e " Для просмотра логов выполните:"
echo -e "   journalctl -u openclaw -f"
echo -e "${GREEN}=================================================${NC}\n"
