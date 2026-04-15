#!/usr/bin/env bash
# =============================================================================
# ДОМАШНИЙ СЕРВЕР — подключение к VPS через WireGuard
#
# Использование:
#   sudo bash client-setup.sh gen-key   # сгенерировать ключи и показать pubkey
#   sudo bash client-setup.sh apply     # применить wg-client.env и поднять туннель
#   sudo bash client-setup.sh status    # показать статус
#   sudo bash client-setup.sh           # алиас для apply
#
# Поток настройки:
#   1. На клиенте: sudo bash client-setup.sh gen-key
#   2. На VPS:     sudo bash vps-setup.sh add-peer
#   3. Сохранить выданные add-peer данные в wg-client.env рядом со скриптом
#   4. На клиенте: sudo bash client-setup.sh apply
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
LOCAL_PUBKEY_FILE="$(dirname "$0")/client_public.key"
LOCAL_APPLY_TEMPLATE="$(dirname "$0")/wg-client.env.example"

[[ $EUID -ne 0 ]] && error "Запусти скрипт с правами root: sudo bash $0"

install_dependencies() {
    header "Установка WireGuard"
    apt-get update -qq
    apt-get install -y -qq wireguard wireguard-tools iproute2 curl iputils-ping
    success "WireGuard установлен"
}

generate_keys() {
    header "Генерация ключей"

    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    if [[ ! -f "${WG_DIR}/client_private.key" || ! -f "${WG_DIR}/client_public.key" ]]; then
        wg genkey | tee "${WG_DIR}/client_private.key" | wg pubkey > "${WG_DIR}/client_public.key"
        chmod 600 "${WG_DIR}/client_private.key"
        success "Ключи сгенерированы"
    else
        warn "Ключи уже существуют, использую существующие"
    fi

    CLIENT_PRIVKEY=$(cat "${WG_DIR}/client_private.key")
    CLIENT_PUBKEY=$(cat "${WG_DIR}/client_public.key")

    echo "$CLIENT_PUBKEY" > "$LOCAL_PUBKEY_FILE"
    info "Публичный ключ сохранён в: $LOCAL_PUBKEY_FILE"
}

print_next_step_help() {
    cat <<EOT

${BOLD}Публичный ключ этого сервера:${NC}
${GREEN}${CLIENT_PUBKEY}${NC}

${YELLOW}Следующий шаг:${NC}
  1. На VPS выполни: sudo bash vps-setup.sh add-peer
  2. Вставь этот публичный ключ, когда скрипт попросит
  3. Сохрани выданные значения в файл: $ENV_FILE
  4. Затем на клиенте выполни: sudo bash $(basename "$0") apply

${BOLD}Шаблон wg-client.env:${NC}
VPS_PUBLIC_KEY=...
VPS_ENDPOINT=1.2.3.4:51820
CLIENT_WG_IP=10.77.0.2
PUBLIC_IP=5.6.7.8
EOT
}

write_env_example() {
    cat > "$LOCAL_APPLY_TEMPLATE" <<'EOT'
# Конфиг для client-setup.sh apply
# Эти данные печатает команда: sudo bash vps-setup.sh add-peer

VPS_PUBLIC_KEY=
VPS_ENDPOINT=1.2.3.4:51820
CLIENT_WG_IP=10.77.0.2
PUBLIC_IP=5.6.7.8
EOT
    info "Шаблон сохранён в: $LOCAL_APPLY_TEMPLATE"
}

load_env() {
    header "Конфигурация подключения"

    if [[ ! -f "$ENV_FILE" ]]; then
        warn "Файл wg-client.env не найден: $ENV_FILE"
        warn "Сначала сгенерируй/проверь публичный ключ и добавь пир на VPS"
        write_env_example
        print_next_step_help
        exit 0
    fi

    info "Найден файл конфигурации: $ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    success "Загружено из файла"

    for var in VPS_PUBLIC_KEY VPS_ENDPOINT CLIENT_WG_IP PUBLIC_IP; do
        [[ -z "${!var:-}" ]] && error "Переменная $var не задана в $ENV_FILE"
    done

    VPS_WG_IP="${CLIENT_WG_IP%.*}.1"
}

write_wg_config() {
    header "Настройка WireGuard"

    local default_gw default_iface endpoint_host
    default_gw=$(ip route | awk '/^default/ {print $3; exit}')
    default_iface=$(ip route | awk '/^default/ {print $5; exit}')
    endpoint_host="${VPS_ENDPOINT%%:*}"

    [[ -z "$default_gw" || -z "$default_iface" ]] && error "Не удалось определить основной шлюз"

    info "Основной шлюз: $default_gw (через $default_iface)"

    cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
Address    = ${CLIENT_WG_IP}/24
PrivateKey = ${CLIENT_PRIVKEY}
PostUp = ip rule add from ${CLIENT_WG_IP} lookup 77 priority 77; ip route add default via ${VPS_WG_IP} table 77; ip route replace ${endpoint_host}/32 via ${default_gw} dev ${default_iface}
PostDown = ip rule del from ${CLIENT_WG_IP} lookup 77 priority 77; ip route del default via ${VPS_WG_IP} table 77 2>/dev/null || true; ip route del ${endpoint_host}/32 via ${default_gw} dev ${default_iface} 2>/dev/null || true

[Peer]
PublicKey  = ${VPS_PUBLIC_KEY}
Endpoint   = ${VPS_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chmod 600 "${WG_DIR}/${WG_IFACE}.conf"
    success "Конфиг записан: ${WG_DIR}/${WG_IFACE}.conf"
}

bring_up_tunnel() {
    header "Запуск туннеля"

    systemctl enable "wg-quick@${WG_IFACE}" --quiet
    systemctl restart "wg-quick@${WG_IFACE}"

    sleep 2
    if systemctl is-active "wg-quick@${WG_IFACE}" &>/dev/null; then
        success "WireGuard активен"
    else
        error "WireGuard не запустился. Проверь: journalctl -u wg-quick@${WG_IFACE}"
    fi
}

check_connectivity() {
    header "Проверка связности"

    if ping -c3 -W2 "$VPS_WG_IP" &>/dev/null; then
        success "VPS доступен через туннель (${VPS_WG_IP})"
    else
        warn "VPS не отвечает на ping. Проверь, что на VPS пир добавлен и активен"
        warn "Команды для проверки на VPS: sudo bash vps-setup.sh list && sudo bash vps-setup.sh status"
    fi
}

show_status() {
    header "Статус клиента"
    if systemctl is-active "wg-quick@${WG_IFACE}" &>/dev/null; then
        success "Сервис wg-quick@${WG_IFACE} активен"
    else
        warn "Сервис wg-quick@${WG_IFACE} не активен"
    fi
    echo ""
    wg show "$WG_IFACE" 2>/dev/null || warn "Интерфейс ${WG_IFACE} ещё не поднят"
    echo ""
    [[ -f "$LOCAL_PUBKEY_FILE" ]] && { echo -e "${BOLD}client_public.key:${NC}"; cat "$LOCAL_PUBKEY_FILE"; }
}

cmd_gen_key() {
    install_dependencies
    generate_keys
    write_env_example
    print_next_step_help
}

cmd_apply() {
    install_dependencies
    generate_keys
    load_env
    write_wg_config
    bring_up_tunnel
    check_connectivity

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Публичный ключ этого сервера:${NC}"
    echo -e "${GREEN}${CLIENT_PUBKEY}${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    success "Готово. Туннель активен и настроен на автостарт."
}

case "${1:-apply}" in
    gen-key) cmd_gen_key ;;
    apply)   cmd_apply ;;
    status)  show_status ;;
    *)
        echo -e "${BOLD}Использование:${NC} sudo bash $0 [gen-key|apply|status]"
        exit 1
        ;;
esac
