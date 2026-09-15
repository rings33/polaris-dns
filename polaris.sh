#!/usr/bin/env bash
set -u -o pipefail

CONF_FILE="${POLARIS_CONF:-${DNS_CONF:-/etc/polaris/polaris.conf}}"
LOG_FILE="${POLARIS_LOG:-${DNS_LOG:-/var/log/polaris.log}}"
STATE_FILE="${POLARIS_STATE:-${DNS_STATE:-/var/lib/polaris/current-provider}}"

declare -A P_V4=(
  [cloudflare]="1.1.1.1 1.0.0.1"
  [google]="8.8.8.8 8.8.4.4"
  [quad9]="9.9.9.9 149.112.112.112"
  [adguard]="94.140.14.14 94.140.15.15"
  [opendns]="208.67.222.222 208.67.220.220"
  [umbrella]="208.67.222.123 208.67.220.123"
  [controld]="76.76.2.0 76.76.10.0"
)
declare -A P_V6=(
  [cloudflare]="2606:4700:4700::1111 2606:4700:4700::1001"
  [google]="2001:4860:4860::8888 2001:4860:4860::8844"
  [quad9]="2620:fe::fe 2620:fe::9"
  [adguard]="2a10:50c0::ad1:ff 2a10:50c0::ad2:ff"
  [opendns]="2620:119:35::35 2620:119:53::53"
  [umbrella]="2620:119:35::123 2620:119:53::123"
  [controld]="2606:1a40:: 2606:1a40:1::"
)
declare -A P_DESC=(
  [cloudflare]="Cloudflare (privacidade)"
  [google]="Google (estavel)"
  [quad9]="Quad9 (seguranca/malware)"
  [adguard]="AdGuard (bloqueia anuncios)"
  [opendns]="OpenDNS (Cisco)"
  [umbrella]="Cisco Umbrella (bloqueia malware/adulto)"
  [controld]="Control D (sem filtros)"
)

MODE="rotate"
DEFAULT_PROVIDER="cloudflare"
CUSTOM_NAME="custom"
CUSTOM_IPV4=""
CUSTOM_IPV6=""
SLOW_MS="150"
SWITCH_MARGIN_PCT="20"
NOTIFY_USER="satuan"
TEST_DOMAIN="example.com"

load_conf() {
  if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
    if [ -n "$CUSTOM_IPV4" ]; then
      P_V4["$CUSTOM_NAME"]="$CUSTOM_IPV4"
      P_V6["$CUSTOM_NAME"]="${CUSTOM_IPV6:-}"
      P_DESC["$CUSTOM_NAME"]="Custom ($CUSTOM_NAME)"
    fi
  fi
}

providers() {
  local k
  for k in "${!P_V4[@]}"; do echo "$k"; done | sort
}

provider_exists() {
  [ -n "${P_V4[$1]:-}" ]
}

latency_ms() {
  local ip="$1" t out
  if command -v dig >/dev/null 2>&1; then
    t=$(dig "@$ip" "$TEST_DOMAIN" +tries=1 +time=2 +comments 2>/dev/null \
        | awk '/Query time:/{print $4}')
    case "$t" in ''|*[!0-9]*) return 1 ;; esac
    echo "$t"
    return 0
  fi
  out=$(ping -c 1 -W 2 "$ip" 2>/dev/null \
        | grep -oE 'time=[0-9.,]+' | head -n1 | cut -d= -f2 | tr ',' '.')
  case "$out" in ''|*[!0-9.]*) return 1 ;; esac
  LC_ALL=C printf '%.0f\n' "$out"
}

first_ip_latency() {
  local p="$1" ms ip
  ip=${P_V4[$p]%% *}
  [ -n "$ip" ] || return 1
  ms=$(latency_ms "$ip") || return 1
  echo "$ms"
}

measure_all() {
  local p ms
  for p in $(providers); do
    if ms=$(first_ip_latency "$p"); then
      printf '%s %s\n' "$ms" "$p"
    else
      printf '999999 %s\n' "$p"
    fi
  done | sort -n
}

current_provider() {
  if [ -r "$STATE_FILE" ]; then
    cat "$STATE_FILE" 2>/dev/null
  else
    echo "$DEFAULT_PROVIDER"
  fi
}

# pick_target [ranking]
# ranking = saida de measure_all (evita medir duas vezes no mesmo ciclo)
pick_target() {
  local ranked best bm bp cur cm dm need
  ranked="${1:-$(measure_all)}"
  best=$(printf '%s\n' "$ranked" | head -n1)
  bm=${best%% *}
  bp=${best#* }
  cur=$(current_provider)

  if [ "$MODE" = "fixed" ]; then
    if dm=$(first_ip_latency "$DEFAULT_PROVIDER") && [ "$dm" -le "$SLOW_MS" ]; then
      echo "$DEFAULT_PROVIDER"
      return 0
    fi
    echo "$bp"
    return 0
  fi

  if cm=$(first_ip_latency "$cur") && [ "$cm" -le "$SLOW_MS" ]; then
    need=$(( cm * (100 - SWITCH_MARGIN_PCT) / 100 ))
    if [ "$bm" -lt "$need" ]; then
      echo "$bp"
    else
      echo "$cur"
    fi
  else
    echo "$bp"
  fi
}

# Uma linha por conexao ativa, formato NAME:TYPE:DEVICE
active_conns() {
  nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null \
    | awk -F: '$(NF-1)=="802-11-wireless" || $(NF-1)=="ethernet" {print}'
}

# Divide NAME:TYPE:DEVICE respeitando ':' dentro do nome da conexao
conn_fields() {
  local line="$1" rest type
  DEV="${line##*:}"
  rest="${line%:*}"
  type="${rest##*:}"
  NAME="${rest%:*}"
  CONN_TYPE="$type"
}

link_has_foreign_dns() {
  local dev="$1" v4="$2" v6="$3" out tok
  out=$(resolvectl dns "$dev" 2>/dev/null)
  out=${out#*: }
  for tok in $out; do
    [ -n "$tok" ] || continue
    case " $v4 $v6 " in
      *" $tok "*) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

apply_dns() {
  local p="$1" v4 v6 line ok=0
  provider_exists "$p" || return 1
  v4=${P_V4[$p]}
  v6=${P_V6[$p]:-}
  while IFS= read -r line; do
    conn_fields "$line"
    [ -n "$NAME" ] || continue
    if nmcli connection modify "$NAME" ipv4.dns "$v4" ipv6.dns "$v6" \
         ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes 2>/dev/null; then
      if nmcli device reapply "$DEV" >/dev/null 2>&1 || nmcli connection up "$NAME" >/dev/null 2>&1; then
        sleep 1
        if link_has_foreign_dns "$DEV" "$v4" "$v6"; then
          if nmcli connection up "$NAME" >/dev/null 2>&1; then
            sleep 2
            log_write "reativacao completa em conexao=$NAME dispositivo=$DEV (sobras de DNS do roteador removidas)"
          fi
        fi
        ok=1
        log_write "aplicado provedor=$p conexao=$NAME dispositivo=$DEV dns4=$v4 dns6=$v6"
      fi
    fi
  done < <(active_conns)
  [ "$ok" -eq 1 ] || return 1
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  echo "$p" > "$STATE_FILE" 2>/dev/null
  return 0
}

restore_auto_dns() {
  local line rc=1
  while IFS= read -r line; do
    conn_fields "$line"
    [ -n "$NAME" ] || continue
    if nmcli connection modify "$NAME" ipv4.dns "" ipv6.dns "" \
         ipv4.ignore-auto-dns no ipv6.ignore-auto-dns no 2>/dev/null; then
      nmcli device reapply "$DEV" >/dev/null 2>&1 || nmcli connection up "$NAME" >/dev/null 2>&1
      rc=0
    fi
  done < <(active_conns)
  rm -f "$STATE_FILE" 2>/dev/null
  log_write "dns restaurado para automatico (dhcp)"
  return $rc
}

log_write() {
  local msg="$1"
  {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE" 2>/dev/null
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 500 ]; then
      tail -n 400 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null \
        && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
    fi
  } 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg"
}

notify_user() {
  local msg="$1" uid sock
  [ -z "$NOTIFY_USER" ] && return 0
  uid=$(id -u "$NOTIFY_USER" 2>/dev/null) || return 0
  sock="/run/user/$uid/bus"
  [ -S "$sock" ] || return 0
  XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=$sock" \
    notify-send -a "Polaris DNS" "Polaris DNS" "$msg" 2>/dev/null &
}

cmd_cycle() {
  load_conf
  local prev target summary top3 ranked
  prev=$(current_provider)
  ranked=$(measure_all)
  target=$(pick_target "$ranked")
  if ! apply_dns "$target"; then
    log_write "ERRO falha ao aplicar provedor=$target"
    exit 1
  fi
  if [ "$target" != "$prev" ]; then
    notify_user "DNS alterado: ${prev} -> ${target} (${P_DESC[$target]:-})"
  fi
  top3=$(printf '%s\n' "$ranked" | head -n3 | awk '{printf "%s=%sms ", $2, $1}')
  log_write "ciclo modo=$MODE ativo=$target anterior=$prev latencias=$top3"
}

cmd_test() {
  load_conf
  local cur bp best_ms ms p ranked mark
  cur=$(current_provider)
  ranked=$(measure_all)
  read -r best_ms bp _ < <(printf '%s\n' "$ranked" | head -n1)
  printf '%-12s %10s  %s\n' "PROVEDOR" "LATENCIA" "DESCRICAO"
  printf '%-12s %10s  %s\n' "--------" "--------" "---------"
  while read -r ms p; do
    mark=" "
    [ "$p" = "$cur" ] && mark="*"
    [ "$p" = "$bp" ] && mark="$mark+"
    if [ "$ms" = "999999" ]; then
      printf '%-12s %10s  %s\n' "${mark}${p}" "FALHOU" "${P_DESC[$p]:-}"
    else
      printf '%-12s %8sms  %s\n' "${mark}${p}" "$ms" "${P_DESC[$p]:-}"
    fi
  done < <(printf '%s\n' "$ranked")
  printf '\n* atual   + mais rapido\n'
}

fmt_duration() {
  local s="$1" h m
  [ "$s" -lt 0 ] && s=0
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
  if [ "$h" -gt 0 ]; then
    printf '%dh %02dmin' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dmin %02ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

cmd_status() {
  load_conf
  local cur cur_ms dev servers n_prov state next next_h rem line name type
  cur=$(current_provider)
  n_prov=$(providers | wc -l)
  cur_ms=$(first_ip_latency "$cur" 2>/dev/null || true)

  echo "======================================================="
  echo "              P O L A R I S  ·  PAINEL                   "
  echo "======================================================="

  # Timer / renovacao
  state=$(systemctl is-active dns.timer 2>/dev/null || true)
  if [ "$state" = "active" ]; then
    next=$(systemctl show dns.timer -p NextElapseUSecRealtime --value 2>/dev/null)
    if [ -n "$next" ] && [ "$next" != "n/a" ]; then
      rem=$(( $(date -d "$next" +%s 2>/dev/null || echo 0) - $(date +%s) ))
    else
      rem=-1
    fi
    printf '  %-14s ATIVO (renovacao automatica a cada 30 min)\n' "Servico:"
    if [ "$rem" -ge 0 ]; then
      printf '  %-14s em %s (%s)\n' "Renovacao:" "$(fmt_duration "$rem")" "$(date -d "$next" '+%H:%M:%S' 2>/dev/null)"
    else
      printf '  %-14s agendada\n' "Renovacao:"
    fi
  else
    printf '  %-14s PARADO (use: dns start)\n' "Servico:"
    printf '  %-14s sem renovacao automatica\n' "Renovacao:"
  fi

  # Modo e provedor atual
  if [ "$MODE" = "fixed" ]; then
    printf '  %-14s fixo (failover se ficar lento/fora)\n' "Modo:"
  else
    printf '  %-14s rotativo (sempre aplica o mais rapido)\n' "Modo:"
  fi
  printf '  %-14s %s — %s\n' "Provedor:" "$cur" "${P_DESC[$cur]:-}"
  if [ -n "${P_V4[$cur]:-}" ]; then
    printf '  %-14s %s\n' "IPv4:" "$(echo "${P_V4[$cur]}" | sed 's/ /, /g')"
    [ -n "${P_V6[$cur]:-}" ] && printf '  %-14s %s\n' "IPv6:" "$(echo "${P_V6[$cur]}" | sed 's/ /, /g')"
  fi
  case "$cur_ms" in ''|*[!0-9]*) printf '  %-14s indisponivel\n' "Latencia:" ;;
    *) printf '  %-14s %sms\n' "Latencia:" "$cur_ms" ;; esac
  printf '  %-14s %s cadastrados\n' "Provedores:" "$n_prov"

  echo "-------------------------------------------------------"
  echo "  Conexoes ativas"
  while IFS= read -r line; do
    conn_fields "$line"
    printf '    • %s [%s] via %s\n' "$NAME" "$CONN_TYPE" "$DEV"
    servers=$(resolvectl status "$DEV" 2>/dev/null \
      | grep 'DNS Servers' | head -n1 | sed 's/.*Servers: //')
    [ -n "$servers" ] && printf '      DNS em uso: %s\n' "$servers"
  done < <(active_conns)

  echo "-------------------------------------------------------"
  if [ -r "$LOG_FILE" ]; then
    echo "  Ultimas acoes"
    tail -n 3 "$LOG_FILE" | sed 's/^/    /'
  fi
  echo "======================================================="
}

cmd_set() {
  local p="$1"
  provider_exists "$p" || { echo "Provedor desconhecido: $p"; cmd_list; exit 1; }
  require_root
  MODE="fixed"
  DEFAULT_PROVIDER="$p"
  persist_conf
  apply_dns "$p" || { echo "Falha ao aplicar $p"; exit 1; }
  notify_user "DNS fixado em: $p (${P_DESC[$p]:-})"
  echo "DNS aplicado e fixado em: $p"
  echo "(o ciclo de 30min so trocara se '$p' ficar lento/fora)"
}

cmd_rotate() {
  require_root
  load_conf
  MODE="rotate"
  persist_conf
  cmd_cycle
  echo "Rotacao automatica reativada (usa o mais rapido a cada ciclo)"
}

cmd_off() {
  require_root
  restore_auto_dns || { echo "Falha ao restaurar"; exit 1; }
  notify_user "DNS restaurado para o automatico do roteador"
  echo "DNS restaurado para o automatico (DHCP do roteador)"
}

cmd_start() {
  require_root
  load_conf
  systemctl enable --now dns.timer >/dev/null 2>&1
  cmd_cycle
  echo "DNS iniciado: ciclo executado e timer ativo (a cada 30 min)."
  systemctl is-active dns.timer >/dev/null 2>&1 && systemctl status dns.timer --no-pager -n 0 | grep -E 'Trigger|Active'
}

cmd_stop() {
  require_root
  systemctl disable --now dns.timer >/dev/null 2>&1
  echo "Timer parado. O DNS atual continua em uso ate voce restaurar ('dns off')."
}

cmd_list() {
  load_conf
  local p
  echo "Provedores disponiveis:"
  for p in $(providers); do
    printf '  %-12s %-30s IPv4: %s | IPv6: %s\n' \
      "$p" "${P_DESC[$p]:-}" "${P_V4[$p]}" "${P_V6[$p]:--}"
  done
}

persist_conf() {
  [ -w "$CONF_FILE" ] || { echo "Sem permissao para gravar $CONF_FILE"; exit 1; }
  touch "$CONF_FILE"
  sed -i \
    -e "s|^MODE=.*|MODE=\"$MODE\"|" \
    -e "s|^DEFAULT_PROVIDER=.*|DEFAULT_PROVIDER=\"$DEFAULT_PROVIDER\"|" \
    "$CONF_FILE"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    local self
    self=$(readlink -f "$0")
    if ! sudo -n "$self" "$@" 2>/dev/null; then
      exec sudo "$self" "$@"
    fi
    exit $?
  fi
}

usage() {
  cat <<EOF
Polaris DNS - troca e renova o DNS automaticamente a cada 30 minutos

Uso: polaris <comando>  (alias: dns)

Comandos:
  start               Inicia o servico: aplica o melhor DNS agora e ativa o timer
  stop                Para o timer (mantem o DNS atual em uso)
  status              Mostra modo, provedor atual, DNS em uso e timer
  test                Mede latencia de todos os provedores
  set <provedor>      Fixa um provedor especifico (ex.: dns set adguard)
  rotate              Reativa rotacao automatica (sempre usa o mais rapido)
  off                 Restaura o DNS automatico do roteador (DHCP)
  list                Lista os provedores disponiveis
  cycle               Executa um ciclo agora (usado pelo timer do systemd)

Modos:
  rotate   cada ciclo mede todos e aplica o mais rapido (padrao)
  fixed    mantem o provedor escolhido; failover se cair ou ficar lento

Configuracao: $CONF_FILE
Log:          $LOG_FILE
Estado:       $STATE_FILE
EOF
}

case "${1:-help}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  shift; cmd_status ;;
  test)    shift; cmd_test ;;
  set)     [ $# -ge 2 ] || { usage; exit 1; }; cmd_set "$2" ;;
  rotate)  cmd_rotate ;;
  off)     cmd_off ;;
  list)    cmd_list ;;
  cycle)   require_root; cmd_cycle ;;
  help|--help|-h) usage ;;
  *)       echo "Comando invalido: $1"; echo; usage; exit 1 ;;
esac
