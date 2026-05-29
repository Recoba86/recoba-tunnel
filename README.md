# Recoba Tunnel

Raw Packet Tunnel Installer & Manager — optimised for Iran entry → abroad exit paths with ENOBUFS recovery.

This project is based on the open-source [Paqet](https://github.com/hanselime/paqet) core and has been independently modified and optimised for production tunnel stability.

## One-Click Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Recoba86/recoba-tunnel/main/install.sh)
```

## What It Does

- Installs the **Recoba Enhanced Core** (ENOBUFS recovery, split metrics, TCP write retry backoff)
- Sets up Server A (Iran entry) or Server B (abroad exit) configurations
- Supports **multiple simultaneous exit tunnels** (Dubai, Switzerland, Germany, etc.)
- Applies the **Iran Optimized Profile** (KCP MTU 1300, FEC off, window 1536, mode fast)
- Auto-tunes interface MTU, txqueuelen, and fq flow_limit for the path

## Architecture

```
Client (Passwall/Mobile)
    │
    ▼
Server A (Iran LAN: 192.168.10.159)
    ├─ recoba-tunnel-dubai.service   → port 1090 → Dubai Server B
    ├─ recoba-tunnel-switzerland.service → port 1091 → Swiss Server B
    └─ recoba-tunnel-germany.service → port 1092 → German Server B
```

## Quick Start

1. Run the one-click install command above
2. Select `2) Setup Server A` — enter tunnel name, Server B IP, and forward ports
3. On Server B, run the same installer and select `1) Setup Server B`
4. Configure your client with the printed VLESS URI and Passwall recommendations

## Multi-Location Tunnels

Add more exit locations without breaking existing ones:

```bash
recoba-tunnel  →  2) Setup Server A  →  name: switzerland  →  ports: 1091
```

Each tunnel gets:
- `/opt/recoba-tunnel/config-<name>.yaml`
- `recoba-tunnel-<name>.service`
- Independent status, logs, restart, and port management

## Passwall / Client Settings

Recommended:
- **Mux:** OFF
- **TCP Fast Open:** ON
- **TLS:** OFF
- **Transport:** RAW TCP
- **MPTCP:** OFF
- **Pre-connections:** 0

## Migration from Old Paqet Manager

If you have an existing install at `/opt/paqet/`:

```bash
recoba-tunnel  →  m) Migrate from old /opt/paqet
```

This copies configs, creates new service units, and installs the enhanced core — without deleting or stopping your old setup.

## Monitoring

```bash
# Check ENOBUFS/retry metrics
journalctl -u recoba-tunnel --no-pager -n 100 | grep -E 'raw_packet|tcp_write|ENOBUFS|retry'

# Live throughput
iftop -i <interface>
```

## Rollback

```bash
sudo cp /opt/recoba-tunnel/recoba-tunnel.v1.bak /opt/recoba-tunnel/recoba-tunnel
sudo systemctl restart recoba-tunnel
```

## Production Profile Defaults

```yaml
transport:
  protocol: "kcp"
  conn: 2
  kcp:
    mode: "fast"
    mtu: 1300
    sndwnd: 1536
    rcvwnd: 1536
    pshard: 0     # FEC off
    dshard: 0
    streambuf: 2097152
    smuxbuf: 4194304
```

## License

This project is based on the open-source Paqet core. See [LICENSE](LICENSE) for details.

## Repository

https://github.com/Recoba86/recoba-tunnel
