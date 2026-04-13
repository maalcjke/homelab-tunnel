#!/usr/bin/env bash
# =============================================================================
# ДОМАШНИЙ СЕРВЕР — подключение к VPS через WireGuard
# Использование: sudo bash client-setup.sh
#
# Скрипт ищет файл wg-client.env в той же директории.
# Если файла нет — спрашивает данные интерактивно.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
ENV_FILE="$(dirname "$0")/wg-client.env"

[[ $EUID -ne 0 ]] && error "Запусти скрипт с правами root: sudo bash $0"

# ─────────────────────────────────────────────
# Загрузить или запросить конфигурацию
# ─────────────────────────────────────────────

header "Конфигурация подключения"

if [[ -f "$ENV_FILE" ]]; then
    info "Найден файл конфигурации: $ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    success "Загружено из файла"
else
    warn "Файл wg-client.env не найден — введи данные вручную"
    warn "(Эти данные выдаёт vps-setup.sh после команды add-peer)"
    echo ""
    read -rp "VPS публичный ключ (VPS_PUBLIC_KEY): "  VPS_PUBLIC_KEY
    read -rp "VPS адрес и порт (VPS_ENDPOINT, напр. 1.2.3.4:51820): " VPS_ENDPOINT
    read -rp "WireGuard IP этого сервера (CLIENT_WG_IP, напр. 10.77.0.2): " CLIENT_WG_IP
    read -rp "Публичный IP который проброшен на этот сервер (PUBLIC_IP): " PUBLIC_IP
fi

# Проверить что всё заполнено
for var in VPS_PUBLIC_KEY VPS_ENDPOINT CLIENT_WG_IP PUBLIC_IP; do
    [[ -z "${!var:-}" ]] && error "Переменная $var не задана"
done

VPS_WG_IP="${CLIENT_WG_IP%.*}.1"   # VPS всегда .1 в подсети

# ─────────────────────────────────────────────
# Установка зависимостей
# ─────────────────────────────────────────────

header "Установка WireGuard"

apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools iproute2 curl

success "WireGuard установлен"

# ─────────────────────────────────────────────
# Генерация ключей клиента
# ─────────────────────────────────────────────

header "Генерация ключей"

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

if [[ ! -f "${WG_DIR}/client_private.key" ]]; then
    wg genkey | tee "${WG_DIR}/client_private.key" \
        | wg pubkey > "${WG_DIR}/client_public.key"
    chmod 600 "${WG_DIR}/client_private.key"
    success "Ключи сгенерированы"
else
    warn "Ключи уже существуют, использую существующие"
fi

CLIENT_PRIVKEY=$(cat "${WG_DIR}/client_private.key")
CLIENT_PUBKEY=$(cat "${WG_DIR}/client_public.key")

# ─────────────────────────────────────────────
# Создать WireGuard конфиг
# ─────────────────────────────────────────────

header "Настройка WireGuard"

# Определить основной интерфейс и шлюз (для восстановления роутинга)
DEFAULT_GW=$(ip route | awk '/^default/ {print $3; exit}')
DEFAULT_IFACE=$(ip route | awk '/^default/ {print $5; exit}')

info "Основной шлюз: $DEFAULT_GW (через $DEFAULT_IFACE)"

cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
Address    = ${CLIENT_WG_IP}/24
PrivateKey = ${CLIENT_PRIVKEY}

# Когда туннель поднимается — добавляем маршрут:
# трафик с проброшенного публичного IP идёт через туннель,
# остальное (включая сам WG handshake) идёт напрямую
PostUp   = ip rule add from ${PUBLIC_IP} lookup 77 priority 77; \
           ip route add default via ${VPS_WG_IP} table 77; \
           ip route add ${VPS_ENDPOINT%%:*}/32 via ${DEFAULT_GW} dev ${DEFAULT_IFACE}
PostDown = ip rule del from ${PUBLIC_IP} lookup 77 priority 77; \
           ip route del default via ${VPS_WG_IP} table 77; \
           ip route del ${VPS_ENDPOINT%%:*}/32 via ${DEFAULT_GW} dev ${DEFAULT_IFACE} 2>/dev/null || true

[Peer]
PublicKey  = ${VPS_PUBLIC_KEY}
Endpoint   = ${VPS_ENDPOINT}
# Разрешаем трафик только из подсети туннеля (не весь интернет через VPS)
AllowedIPs = ${VPS_WG_IP}/32, 10.77.0.0/24
# Keepalive чтобы туннель не падал за NAT
PersistentKeepalive = 25
EOF

chmod 600 "${WG_DIR}/${WG_IFACE}.conf"
success "Конфиг записан: ${WG_DIR}/${WG_IFACE}.conf"

# ─────────────────────────────────────────────
# Запустить и включить автостарт
# ─────────────────────────────────────────────

header "Запуск туннеля"

systemctl enable wg-quick@${WG_IFACE} --quiet
systemctl restart wg-quick@${WG_IFACE}

# Подождать секунду и проверить
sleep 2
if systemctl is-active wg-quick@${WG_IFACE} &>/dev/null; then
    success "WireGuard активен"
else
    error "WireGuard не запустился. Проверь: journalctl -u wg-quick@${WG_IFACE}"
fi

# ─────────────────────────────────────────────
# Проверить связность с VPS
# ─────────────────────────────────────────────

header "Проверка связности"

if ping -c3 -W2 "$VPS_WG_IP" &>/dev/null; then
    success "VPS доступен через туннель (${VPS_WG_IP})"
else
    warn "VPS не отвечает на ping. Возможно пир ещё не добавлен на VPS."
    warn "Убедись что на VPS выполнен: sudo bash vps-setup.sh add-peer"
fi

# ─────────────────────────────────────────────
# Итог
# ─────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Публичный ключ этого сервера:${NC}"
echo -e "${GREEN}${CLIENT_PUBKEY}${NC}"
echo ""
echo -e "${YELLOW}Если ты ещё не добавил этот сервер на VPS:${NC}"
echo -e "  1. Скопируй ключ выше"
echo -e "  2. На VPS выполни: sudo bash vps-setup.sh add-peer"
echo -e "  3. Введи этот ключ когда скрипт попросит"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Сохранить публичный ключ в файл рядом со скриптом для удобства
echo "$CLIENT_PUBKEY" > "$(dirname "$0")/client_public.key"
info "Публичный ключ сохранён в: $(dirname "$0")/client_public.key"

success "Готово. Туннель активен и настроен на автостарт."
