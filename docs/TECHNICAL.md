# Polaris DNS — Documentação Técnica

Versão: 2.0 (agosto/2026) — rebranding Polaris DNS (compatível com dns.sh original)
Componente principal: `polaris.sh` (bash) + unidades systemd `polaris.service`/`polaris.timer`

> Este documento é a versão Polaris do antigo `DOCUMENTACAO_TECNICA.md`. Caminho canônico: `/etc/polaris/polaris.sh`, alias legado `/etc/dns/dns.sh` migrado automaticamente.

---
## 1. Visão geral da arquitetura

```
┌──────────────┐   a cada 30 min    ┌───────────────┐
│polaris.timer │───────────────────▶│polaris.service│
│ (systemd)    │  OnBootSec=60s     │ Type=oneshot  │
└──────────────┘                    └──────┬────────┘
                                           │ ExecStart=/usr/local/bin/polaris cycle
                                           ▼
                                    ┌──────────────┐
                                    │  polaris.sh  │
                                    └──┬───┬───┬───┘
               medição (dig/ping)     │   │   │ aplicação (nmcli/reapply)
                      ┌───────────────┘   │   └───────────────┐
                      ▼                   ▼                   ▼
             Provedores anycast    Estado/Config         NetworkManager
             (7 serviços DNS)      /etc/polaris/…        → resolvectl
                                   /var/lib/polaris/
```

| Componente | Responsabilidade |
|---|---|
| `polaris.timer` | Agendar ciclos (`*:0/30`, `Persistent=true`) |
| `polaris.service` | Encapsular um ciclo oneshot com timeout 90s |
| `polaris.sh` | Medir, decidir, aplicar, registrar e notificar |
| NetworkManager | Persistir servidores por conexão (`ipv4.dns`/`ipv6.dns`) |

## 2. Estrutura de arquivos

| Caminho | Função |
|---|---|
| `/usr/local/bin/polaris` | Entrypoint (symlink para `/etc/polaris/polaris.sh`) |
| `/usr/local/bin/dns` | Alias legado (mesmo symlink) |
| `/etc/polaris/polaris.sh` | Script executável |
| `/etc/polaris/polaris.conf` | Configuração (sourced pelo script) |
| `/var/lib/polaris/current-provider` | Estado: último provedor aplicado |
| `/var/log/polaris.log` | Log rotativo |
| `/etc/systemd/system/polaris.service` | Unidade oneshot |
| `/etc/systemd/system/polaris.timer` | Temporizador |

Variáveis que sobrepõem caminhos (úteis para testes):
- `POLARIS_CONF`, `POLARIS_LOG`, `POLARIS_STATE` (fallback legado `DNS_CONF`, `DNS_LOG`, `DNS_STATE`)

## 3. Fluxo do ciclo (`cmd_cycle`)

1. **Carrega configuração** — `load_conf` faz source de `polaris.conf`; se houver custom, injeta nas tabelas.
2. **Medição** — `measure_all` testa o primeiro IPv4 de cada provedor com `dig @ip example.com` (Query time em ms). Sem `dig`, usa RTT de `ping`. Falhas recebem sentinela `999999`.
3. **Decisão** — `pick_target "$ranked"` escolhe destino (ver §4).
4. **Aplicação** — `apply_dns` grava em cada conexão ativa: `nmcli con modify <nome> ipv4.dns/ipv6.dns ... ignore-auto-dns yes` + `nmcli device reapply` (fallback `nmcli con up`).
5. **Verificação** — `link_has_foreign_dns` compara `resolvectl dns <dev>` com IPs esperados; detectando resíduos do roteador, refaz `nmcli con up`.
6. **Estado e telemetria** — grava `current-provider`, registra latências top-3 e notifica via D-Bus se houve troca.

## 4. Algoritmo de seleção

### Modo `rotate` (padrão)
```
atual_ok = latencia(atual) <= SLOW_MS (150ms)
se atual_ok:
    limite = latencia_atual * (100 - SWITCH_MARGIN_PCT)/100  # 20%
    alvo = melhor_se melhor.latencia < limite senão atual
senão:
    alvo = melhor
```
Margem evita ping-pong entre provedores empatados.

### Modo `fixed`
Mantém `DEFAULT_PROVIDER`; failover automático para o melhor disponível somente se o preferido falhar ou exceder `SLOW_MS`.

## 5. Decisões de implementação relevantes
- **Parsing de conexões**: nomes Wi-Fi podem conter `:`; leitura feita da direita para a esquerda (`${line##*:}`), separando DEVICE, TYPE e NAME.
- **Elevação**: `require_root` tenta `sudo -n` (sem prompt); falhando, reexecuta via `exec sudo` com `readlink -f "$0"` — robusto mesmo via symlink.
- **Rotação de log**: acima de 500 linhas, trunca para 400 mais recentes (atômico via `.tmp` + `mv`).
- **Notificações**: `notify-send` injetado no barramento do usuário `NOTIFY_USER` (funciona mesmo quando ciclo roda como root).
- **Fail-safe de medição**: timeout 2s no `dig` (+tries=1); sentinela `999999` mantém offline visíveis sem afetar escolha.

## 6. Segurança e permissões
| Item | Configuração |
|---|---|
| Script/unidades | `root:root 755/644` |
| Configuração | editável só por root; `persist_conf` exige escrita |
| Estado | gravado apenas após sucesso na aplicação |
| Elevação | sempre via `sudo`; nenhum `chmod u+s` |

O script nunca desativa firewall, nunca altera `/etc/resolv.conf` direto (quem gerencia é `systemd-resolved` via NetworkManager).

## 7. Instalador (`install.sh`)
- `install`: valida `polaris.sh`, executa `cleanup_legacy` (migra/remove artefatos `dns` e `dns-changer`), instala script+config+unidades, `daemon-reload`, primeiro ciclo e `enable --now polaris.timer`.
- `--remove`: interrompe timer/serviço, oferece `polaris off`, remove binário, unidades e cópia instalada; mantém config/log para auditoria.
Idempotente: config existente é preservada; reinstalar não perde ajustes.

## 8. Solução de problemas
| Sintoma | Investigação |
|---|---|
| Ciclo não roda | `systemctl status polaris.timer` e `systemctl list-timers` |
| Erro no ciclo | `journalctl -u polaris.service -n 50 --no-pager` |
| Provedor FALHOU no `polaris test` | `dig @IP example.com` |
| DNS não muda na interface | `resolvectl status <dev>`; verifique VPN |
| Sem notificações | confirme `NOTIFY_USER` e sessão gráfica ativa |

## 9. Limitações conhecidas
- Latência medida apenas contra o primeiro IPv4 do provedor (amostra única).
- Não suporta DoH/DoT (apenas DNS UDP clássico).
- Ambientes sem NetworkManager exigem adaptação.
