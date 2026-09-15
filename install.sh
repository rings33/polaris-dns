#!/usr/bin/env bash
set -u -o pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/etc/polaris"
BIN_LINK="/usr/local/bin/polaris"
BIN_LINK_LEGACY="/usr/local/bin/dns"
SERVICE_FILE="/etc/systemd/system/polaris.service"
TIMER_FILE="/etc/systemd/system/polaris.timer"
SERVICE_FILE_LEGACY="/etc/systemd/system/dns.service"
TIMER_FILE_LEGACY="/etc/systemd/system/dns.timer"
LOG_FILE="/var/log/polaris.log"
LOG_FILE_LEGACY="/var/log/dns.log"
STATE_DIR="/var/lib/polaris"

die() { echo "ERRO: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "execute com sudo: sudo ./install.sh"
}

cleanup_legacy() {
  # dns-changer (muito antigo)
  systemctl disable --now dns-changer.timer 2>/dev/null || true
  rm -f /etc/systemd/system/dns-changer.service /etc/systemd/system/dns-changer.timer
  rm -f /usr/local/bin/dns-changer
  if [ -d /etc/dns-changer ] && [ ! -f "$INSTALL_DIR/polaris.conf" ]; then
    mkdir -p "$INSTALL_DIR"
    cp /etc/dns-changer/dns.conf "$INSTALL_DIR/polaris.conf" 2>/dev/null || true
    info "Configuracao antiga migrada para $INSTALL_DIR/polaris.conf"
  fi
  [ -f /var/lib/dns-changer/current-provider ] && \
    mkdir -p "$STATE_DIR" && cp -n /var/lib/dns-changer/current-provider "$STATE_DIR/" 2>/dev/null
  [ -f /var/log/dns-changer.log ] && [ ! -f "$LOG_FILE" ] && \
    cp /var/log/dns-changer.log "$LOG_FILE" 2>/dev/null
  rm -rf /etc/dns-changer /var/lib/dns-changer

  # dns (nome anterior) -> polaris: migra config/state/log/timer se existirem
  if [ -d /etc/dns ] && [ ! -f "$INSTALL_DIR/polaris.conf" ]; then
    mkdir -p "$INSTALL_DIR"
    cp /etc/dns/dns.conf "$INSTALL_DIR/polaris.conf" 2>/dev/null || true
    cp /etc/dns/dns.sh "$INSTALL_DIR/polaris.sh" 2>/dev/null || true
    info "Migrado /etc/dns -> $INSTALL_DIR"
  fi
  if [ -f /var/lib/dns/current-provider ] && [ ! -f "$STATE_DIR/current-provider" ]; then
    mkdir -p "$STATE_DIR"
    cp -n /var/lib/dns/current-provider "$STATE_DIR/current-provider" 2>/dev/null || true
  fi
  if [ -f "$LOG_FILE_LEGACY" ] && [ ! -f "$LOG_FILE" ]; then
    cp -n "$LOG_FILE_LEGACY" "$LOG_FILE" 2>/dev/null || true
  fi
  # desativa unidades antigas dns.* se ainda ativas (serao substituidas por polaris.*)
  if systemctl is-active --quiet dns.timer 2>/dev/null || [ -f "$TIMER_FILE_LEGACY" ]; then
    systemctl disable --now dns.timer 2>/dev/null || true
    systemctl disable --now dns.service 2>/dev/null || true
  fi
}

remove_all() {
  require_root
  info "Parando e desativando o timer"
  systemctl disable --now polaris.timer 2>/dev/null || true
  systemctl disable --now dns.timer 2>/dev/null || true
  systemctl stop polaris.service 2>/dev/null || true
  systemctl stop dns.service 2>/dev/null || true

  local bin="polaris"
  command -v polaris >/dev/null 2>&1 || bin="dns"
  if command -v "$bin" >/dev/null 2>&1; then
    echo
    echo "Deseja restaurar o DNS automatico (DHCP) antes de remover? [s/N]"
    read -r ans
    case "$ans" in
      s|S|sim|SIM) "$bin" off || true ;;
    esac
  fi

  rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SERVICE_FILE_LEGACY" "$TIMER_FILE_LEGACY"
  systemctl daemon-reload
  rm -f "$BIN_LINK" "$BIN_LINK_LEGACY"
  rm -f "$INSTALL_DIR/polaris.sh"

  echo
  info "Removido. Mantidos para consulta manual:"
  echo "    Config: $INSTALL_DIR/polaris.conf"
  echo "    Log:    $LOG_FILE"
  echo "Para apagar tudo: sudo rm -rf $INSTALL_DIR $LOG_FILE $STATE_DIR"
}

write_units() {
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Polaris DNS - aplica e renova DNS automaticamente
Documentation=man:nmcli(1)
Wants=network-online.target NetworkManager.service
After=network-online.target NetworkManager-wait-online.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/polaris cycle
SyslogIdentifier=polaris
TimeoutStartSec=90
EOF

  cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Polaris DNS - atualizacao a cada 30 minutos

[Timer]
OnBootSec=60s
OnCalendar=*:0/30
Persistent=true
AccuracySec=5s
Unit=polaris.service

[Install]
WantedBy=timers.target
EOF
}

install_all() {
  require_root
  [ -f "$SRC_DIR/polaris.sh" ] || die "polaris.sh nao encontrado em $SRC_DIR"

  info "Limpando instalacoes antigas, se houver"
  cleanup_legacy

  info "Instalando script em $INSTALL_DIR"
  install -Dm755 "$SRC_DIR/polaris.sh" "$INSTALL_DIR/polaris.sh"

  if [ ! -f "$INSTALL_DIR/polaris.conf" ]; then
    install -Dm644 "$SRC_DIR/polaris.conf" "$INSTALL_DIR/polaris.conf"
    info "Configuracao criada: $INSTALL_DIR/polaris.conf"
  else
    info "Configuracao existente preservada: $INSTALL_DIR/polaris.conf"
  fi

  info "Criando comandos globais: $BIN_LINK e $BIN_LINK_LEGACY (compatibilidade)"
  ln -sf "$INSTALL_DIR/polaris.sh" "$BIN_LINK"
  ln -sf "$INSTALL_DIR/polaris.sh" "$BIN_LINK_LEGACY"

  info "Instalando unidades systemd (polaris.service/polaris.timer)"
  write_units
  # remove legadas para evitar duplicacao
  rm -f "$SERVICE_FILE_LEGACY" "$TIMER_FILE_LEGACY"
  chmod 644 "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload

  info "Aplicando DNS pela primeira vez"
  systemctl start polaris.service \
    || die "primeiro ciclo falhou; veja: journalctl -u polaris.service -n 20 --no-pager"

  info "Ativando timer de 30 minutos"
  systemctl enable --now polaris.timer \
    || die "falha ao ativar o timer"

  echo
  echo "Instalacao concluida!"
  echo "----------------------------------------"
  systemctl list-timers polaris.timer --no-pager | head -n3
  echo "----------------------------------------"
  echo "Comandos disponiveis:"
  echo "  polaris start           inicia servico e aplica o melhor DNS agora"
  echo "  polaris status          painel com renovacao e DNS em uso"
  echo "  polaris test            mede latencia dos provedores"
  echo "  polaris set adguard     fixa um provedor (cloudflare/google/quad9/adguard/opendns/umbrella/controld)"
  echo "  polaris rotate          reativa rotacao pelo mais rapido"
  echo "  polaris off             volta ao DNS do roteador"
  echo "  (alias compativel: dns ...)"
  echo "Log em tempo real: journalctl -u polaris.service -f"
  echo "Desinstalar:       sudo $0 --remove"
}

case "${1:-install}" in
  install)                     install_all ;;
  --remove|--uninstall|remove) remove_all ;;
  *) echo "Uso: sudo $0 [install|--remove]"; exit 1 ;;
esac
