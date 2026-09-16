# Polaris DNS

<p align="center">
  <strong>Gerenciador inteligente de DNS para Linux</strong><br/>
  Mede, escolhe e aplica automaticamente o DNS mais rápido a cada 30 minutos.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-linux-lightgrey?style=flat-square" alt="platform linux"/>
  <img src="https://img.shields.io/badge/systemd-timer-blue?style=flat-square" alt="systemd"/>
  <img src="https://img.shields.io/badge/NetworkManager-nmcli-green?style=flat-square" alt="nmcli"/>
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square" alt="bash"/>
  <img src="https://img.shields.io/badge/license-MIT-yellow?style=flat-square" alt="license"/>
  <img src="https://img.shields.io/badge/version-2.0--beta-orange?style=flat-square" alt="version"/>
</p>

---

## Por que Polaris DNS?

Trocar DNS manualmente é lento e propenso a erro. O Polaris DNS automatiza tudo: mede a latência real dos principais provedores anycast, aplica o mais rápido em todas as conexões ativas (Wi-Fi e cabo) via NetworkManager e mantém a escolha otimizada com histerese inteligente — sem ping-pong entre provedores quase empatados.

*   **Automático:** ciclo a cada 30 min + 60s após o boot (`Persistent=true` — recupera ciclos perdidos se o PC estava desligado).
*   **Inteligente:** só troca se o concorrente for >20% mais rápido; failover imediato se o atual cair ou ficar lento (>150ms).
*   **Seguro:** nunca toca em `/etc/resolv.conf` direto, nunca desativa firewall, exige `sudo` apenas nas ações que alteram o sistema.
*   **Transparente:** painel `status`, log rotativo, notificações na área de trabalho quando o provedor muda.

> **Versão atual: Linux terminal.** 

---

## Requisitos

- Linux com **systemd** e **NetworkManager** (Fedora, Ubuntu, Debian e derivados)
- `nmcli` e `resolvectl` (já vêm com NetworkManager)
- `dig` (`bind-utils` / `dnsutils`) ou `ping` como fallback
- `notify-send` (opcional, pacote `libnotify` — para notificações visuais)

Verifique:

```bash
nmcli --version && resolvectl --version && dig -v 2>&1 | head -n1
```

---

## Instalação

```bash
git clone https://github.com/rings33/polaris-dns.git
cd polaris-dns
sudo ./install.sh          # instala e ativa (aplica o melhor DNS imediatamente)
```

O instalador faz:

1.  Instala o script em `/etc/polaris/polaris.sh`
2.  Cria os comandos globais `/usr/local/bin/polaris` (e alias compatível `/usr/local/bin/dns`)
3.  Instala as unidades `polaris.service` + `polaris.timer` (ciclo de 30 min)
4.  Aplica o melhor DNS imediatamente e ativa o timer
5.  Migra automaticamente instalações antigas de `dns` / `dns-changer` (`/etc/dns`, `/var/lib/dns`)

Desinstalar:

```bash
sudo ./install.sh --remove   # pergunta se quer restaurar DHCP antes de remover
```

---

## Uso

Todos os comandos que alteram o sistema pedem senha via `sudo` automaticamente.

| Comando | Descrição |
|---|---|
| `polaris start` | Aplica o melhor DNS agora e ativa a renovação automática |
| `polaris stop` | Para a renovação automática (mantém o DNS atual em uso) |
| `polaris status` | Painel completo: serviço, provedor, latência e tempo até renovar |
| `polaris test` | Mede a latência de todos os provedores cadastrados |
| `polaris set <provedor>` | Fixa um provedor específico (ex.: `polaris set adguard`) |
| `polaris rotate` | Volta ao modo rotativo (sempre usa o mais rápido) |
| `polaris off` | Restaura o DNS automático do roteador (DHCP) |
| `polaris list` | Lista os provedores disponíveis com IPs |
| `polaris cycle` | Executa um ciclo agora (usado internamente pelo timer) |

Alias legado `dns` continua funcionando: `dns status`, `dns test`, etc.

### Exemplos

```bash
polaris status              # painel geral
polaris test                # comparar antes de escolher
polaris set quad9           # fixar Quad9 (segurança)
polaris set adguard         # bloquear anúncios
polaris rotate              # voltar a rotacionar pelo mais rápido
polaris off                 # voltar ao DHCP do roteador
```

Saída de `polaris status`:

```
=======================================================
              P O L A R I S  ·  PAINEL
=======================================================
  Servico:       ATIVO (renovacao automatica a cada 30 min)
  Renovacao:     em 18min 42s (14:30:00)
  Modo:          rotativo (sempre aplica o mais rapido)
  Provedor:      cloudflare — Cloudflare (privacidade)
  IPv4:          1.1.1.1, 1.0.0.1
  Latencia:      18ms
  Provedores:    7 cadastrados
-------------------------------------------------------
  Conexoes ativas
    • Casa [802-11-wireless] via wlp3s0
      DNS em uso: 1.1.1.1 1.0.0.1
=======================================================
```

Saída de `polaris test`:

```
PROVEDOR     LATENCIA  DESCRICAO
--------     --------  ---------
* cloudflare     18ms  Cloudflare (privacidade)
  google         24ms  Google (estavel)
 +quad9          12ms  Quad9 (seguranca/malware)
 ...

* atual   + mais rapido
```

---

## Provedores

| Nome | Serviço | IPv4 | IPv6 | Perfil |
|---|---|---|---|---|
| `cloudflare` | Cloudflare | 1.1.1.1, 1.0.0.1 | 2606:4700:4700::1111, 2606:4700:4700::1001 | Privacidade |
| `google` | Google Public DNS | 8.8.8.8, 8.8.4.4 | 2001:4860:4860::8888, 2001:4860:4860::8844 | Estabilidade |
| `quad9` | Quad9 | 9.9.9.9, 149.112.112.112 | 2620:fe::fe, 2620:fe::9 | Segurança / anti-malware |
| `adguard` | AdGuard | 94.140.14.14, 94.140.15.15 | 2a10:50c0::ad1:ff, 2a10:50c0::ad2:ff | Bloqueia anúncios |
| `opendns` | OpenDNS (Cisco) | 208.67.222.222, 208.67.220.220 | 2620:119:35::35, 2620:119:53::53 | Geral |
| `umbrella` | Cisco Umbrella | 208.67.222.123, 208.67.220.123 | 2620:119:35::123, 2620:119:53::123 | Bloqueia malware/adulto |
| `controld` | Control D | 76.76.2.0, 76.76.10.0 | 2606:1a40::, 2606:1a40:1:: | Sem filtros |

Todos com IPv6 correspondente. Adicione um custom em `/etc/polaris/polaris.conf`:

```bash
CUSTOM_NAME="meudns"
CUSTOM_IPV4="192.168.1.10 1.2.3.4"
CUSTOM_IPV6="2001:db8::1"   # opcional
```

Depois: `polaris set meudns`.

---

## Configuração

Arquivo: `/etc/polaris/polaris.conf` (também aceita `POLARIS_CONF`, `DNS_CONF` para testes)

| Variável | Padrão | Função |
|---|---|---|
| `MODE` | `rotate` | `rotate` = mais rápido a cada ciclo; `fixed` = mantém o escolhido, failover se cair |
| `DEFAULT_PROVIDER` | `cloudflare` | Provedor preferido no modo fixo |
| `SLOW_MS` | `150` | Acima disso é considerado lento (dispara troca) |
| `SWITCH_MARGIN_PCT` | `20` | Só troca se concorrente for >20% mais rápido (histerese) |
| `NOTIFY_USER` | `satuan` | Usuário que recebe `notify-send` quando o DNS muda |
| `TEST_DOMAIN` | `example.com` | Domínio usado na medição |

Estado: `/var/lib/polaris/current-provider` (ou `POLARIS_STATE`)
Log: `/var/log/polaris.log` (ou `POLARIS_LOG`) — rotação automática >500 linhas mantém últimas 400.

---

## Como funciona

```
polaris.timer (systemd, *:0/30 + OnBootSec 60s)
      │
      ▼
polaris.service (Type=oneshot, Timeout 90s)
      │ ExecStart=/usr/local/bin/polaris cycle
      ▼
  polaris.sh
    1. load_conf → lê polaris.conf, injeta custom
    2. measure_all → dig @IP example.com (+tries=1 +time=2) fallback ping, falha=999999
    3. pick_target → aplica histerese 20% (rotate) ou failover (fixed)
    4. apply_dns → nmcli con modify ... ipv4.dns/ipv6.dns + ignore-auto-dns yes + device reapply
    5. verifica resolvectl dns (remove sobras DHCP), grava state, loga top3, notifica
```

Detalhes completos em [`docs/TECHNICAL.md`](docs/TECHNICAL.md).

---

## Logs e diagnóstico

```bash
polaris status                      # painel
tail -f /var/log/polaris.log        # log da aplicação
journalctl -u polaris.service -f    # log do systemd em tempo real
journalctl -u polaris.timer --no-pager -n 20
resolvectl status                   # DNS efetivamente em uso por interface
polaris test                        # latência ao vivo
```

**Troquei de Wi-Fi, preciso rodar algo?** Não — o próximo ciclo aplica automaticamente em todas as conexões ativas.

---

## Compatibilidade e migração

- Instalação antiga em `/etc/dns` / `dns.service` é migrada automaticamente para `/etc/polaris` / `polaris.service` na primeira instalação.
- Comandos `dns` continuam funcionando como alias de `polaris`.
- `sudo ./install.sh --remove` mantém config/log para auditoria; apague manualmente com `sudo rm -rf /etc/polaris /var/log/polaris.log /var/lib/polaris` se desejar.

---

## Roadmap

- [x] **Linux terminal** — estável (este repositório)
- [ ] **Windows gráfico Polaris** — tray ao lado do relógio, instalador `PolarisSetup.exe` (beta em desenvolvimento, ver `WINDOWS.md` no projeto original)
- [ ] DoH/DoT opcional
- [ ] Modo benchmark contínuo

---

## Contribuindo

Issues e PRs são bem-vindos. Para mudanças no algoritmo de seleção, inclua saída de `polaris test` antes/depois.

```bash
shellcheck polaris.sh install.sh
bash -n polaris.sh
```

---

## Licença

[MIT](LICENSE) — © 2026 Polaris DNS — rings33

---

<p align="center">
  Feito para quem quer DNS rápido sem dor de cabeça.<br/>
  <code>polaris status</code> e deixe o resto com o Polaris.
</p>
