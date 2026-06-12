# Quip Network Node Manager (v0.2)

Simple Bash manager for running a **Quip Network** node (CPU or CUDA/GPU) on the
live **Quip Testnet**, with a small terminal UI. Rewritten for the **v0.2** stack
(substrate validator + RPC-client miner + dashboard).

> Quip Network is a **Proof-of-Useful-Work** chain — miners solve real
> optimization (Ising) problems instead of grinding hashes. Mainnet + token
> generation event (TGE) are slated for **Q2 2026**; testnet participation feeds
> the **airdrop** ([quest.quip.network/airdrop](https://quest.quip.network/airdrop)).

---

## ⚠️ Back up your wallet (read this first)

In **v0.2 the wallet is generated automatically** on first start — you no longer
paste an address. The node creates an account, self-funds it from the testnet
faucet, and registers it on-chain. **That account is your miner identity and your
airdrop/reward address.** If you lose it, it's gone — there is no recovery.

**Files to back up (keep them private and offline):**

| File | What it is | Lose it = |
|------|-----------|-----------|
| `~/quip-node/data/keystore.json` | **Your wallet.** Hybrid sr25519 keystore — contains the **seed/secret key** (plaintext on testnet builds). | account + any tQUIP / rewards / airdrop link gone |
| `~/quip-node/data/config.toml` | Node config incl. the `secret` used for deterministic key generation | harder to reproduce the same identity |
| `~/quip-node/data/validator-data/` | Validator libp2p + session keys (only matters for named/bootnode validators) | new peer id (regenerable for normal miners) |

**Simplest safe backup — copy the whole `data/` dir somewhere private:**

```bash
tar czf quip-wallet-backup.tar.gz -C ~/quip-node data/keystore.json data/config.toml
# move quip-wallet-backup.tar.gz off the server (scp/download), store offline
```

**Restore** = put `keystore.json` (and `config.toml`) back into `~/quip-node/data/`
before starting the node.

> 🔒 Never commit `keystore.json`, never paste your seed anywhere, `chmod 600` it.
> The repo's `data/` is gitignored for this reason.

---

## Quick start

```bash
# download + run (root needed for docker/firewall)
curl -fsSL https://raw.githubusercontent.com/VaniaHilkovets/QuipNetwork-node-autoinstall/main/quip_manager.sh -o quip_manager.sh
sudo bash quip_manager.sh
```

Then pick **`1) install`**, choose `cpu` or `cuda`, and the script does the rest:
installs Docker (+ NVIDIA toolkit for CUDA), opens firewall ports, clones the
node repo, writes config + `.env`, pulls images, and brings the testnet stack up.
The wallet is generated and shown to you at the end (and under **`5) node info`**).

## Menu

| Option | Does |
|--------|------|
| `1 install` | Docker + firewall + clone + config + `.env` + start. Migrates an old v0.1 config via `make updateconfig` if found. |
| `2 start` / `3 stop` | Bring the stack up / down |
| `4 logs` | Miner / validator / full compose logs |
| `5 node info` | **Wallet address**, container status, and live `/api/v1` telemetry |
| `6 update` | `git pull` + pull new images + recreate |
| `7 switch profile` | CPU ⇄ CUDA (keeps your wallet keystore) |
| `8 remove` | Tear down containers + repo (**also deletes `data/` — back up first!**) |

CUDA mode starts the host **NVIDIA MPS** daemon for SM sharing (no-op / software
fallback under WSL2).

## Ports to open on your provider/firewall

| Port | Why |
|------|-----|
| `20049/tcp` | Caddy front door — **dashboard + `/api/v1/*` telemetry + `/rpc`** (required) |
| `30333/tcp` + `30333/udp` | libp2p peering — open it or you're a leaf, not a peer (recommended) |
| `80/tcp`, `443/tcp` | only if you run public HTTPS (Caddy auto-TLS) |

Verify they're reachable from the internet (run on the host):

```bash
curl -sS https://check.quip.network/checkport?port=20049
curl -sS https://check.quip.network/checkport?port=30333
```

## Monitoring & links

- **Dashboard (your node):** `http://localhost:20049/` — or `http://<your-server-ip>:20049/`
- **Telemetry API:** `http://localhost:20049/api/v1/status` · `/api/v1/stats` · `/api/v1/miner/survey`
- **Port checker:** [check.quip.network](https://check.quip.network)
- **Testnet faucet:** [faucet.testnet.quip.network](https://faucet.testnet.quip.network) (the node self-funds from it)
- **Airdrop / quest:** [quest.quip.network/airdrop](https://quest.quip.network/airdrop)
- **Project:** [quip.network](https://quip.network) · **Docs:** [quip.gitbook.io/docs](https://quip.gitbook.io/docs)
- **Run-a-node docs:** [quip.gitbook.io/docs/nodes/run-a-node-testnet](https://quip.gitbook.io/docs/nodes/run-a-node-testnet)
- **Node repo (upstream):** [gitlab.com/quip.network/nodes.quip.network](https://gitlab.com/quip.network/nodes.quip.network)
- **Discord:** [discord.gg/quipnetwork](https://discord.gg/quipnetwork)

## Server rental

If you need a VPS or GPU server for Quip:

- Contabo: https://www.dpbolvw.net/click-101335050-17082114
- Servarica: https://clients.servarica.com/aff.php?aff=1242

## What changed from v0.1

The Quip stack moved from a self-contained P2P node to a **substrate validator +
RPC-client miner**. This manager was rewritten to match:

- wallet is **auto-generated** (`data/keystore.json`) and self-funded/registered — no manual `0x...` entry
- CPU cores / GPU share configured via `.env` (`QUIP_MINER_CPUSET`, `QUIP_GPU_UTILIZATION`)
- single front door on **`:20049`** (Caddy): dashboard + `/api/v1/*` + `/rpc`; libp2p on `:30333`
- bundled validator + dashboard + postgres per profile; richer stats
- old-config auto-migration (`make updateconfig`), NVIDIA MPS for CUDA, hourly auto-update via `cron.sh`

---

## Telegram

- Channel: https://t.me/SotochkaZela
- Chat: https://t.me/sotochkachat
