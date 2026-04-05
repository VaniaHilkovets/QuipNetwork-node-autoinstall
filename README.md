# Quip Network Node Manager

Simple Bash manager for running a Quip node in `CPU` or `CUDA` mode with a small terminal UI.

## Server Rental

If you need a VPS or GPU server for Quip:

- Contabo: https://www.dpbolvw.net/click-101335050-17082114
- Servarica: https://clients.servarica.com/aff.php?aff=1242

## What This Script Does

`quip.sh` helps you install, configure, run, and manage a Quip node without doing everything manually through Docker and config files.

It supports:

- CPU profile
- CUDA profile
- profile switching without losing node identity
- node stats and wallet info
- cleaner miner log viewing
- GPU tuning prompts for CUDA mode

## Main Features

- `install`
  Installs Docker if needed, clones the Quip node repo, prepares config, opens required ports, and starts the node.

- `start`
  Starts the selected node profile.

- `stop`
  Stops the selected node profile.

- `logs`
  Lets you choose between:
  `normal logs` - raw logs as-is
  `miner logs` - filtered logs with noisy network spam hidden

- `node info`
  Shows node name, host, profile, secret, mining stats, and for CUDA also shows current GPU settings.

- `update`
  Pulls the latest repo/image and recreates the container.

- `switch profile`
  Switches between `CPU` and `CUDA` while preserving the current `secret`, `node_name`, and `public_host`.

- `remove`
  Stops containers and removes the local installation and saved manager state.

## CPU Mode

In CPU mode the script asks how many CPU cores to use.

Notes:

- `num_cpus` is written into config
- the selected core count is remembered
- when you switch back to CPU later, the script restores the saved value

## CUDA Mode

When installing CUDA for the first time, or when switching from CPU to CUDA, the script asks for GPU settings.

### GPU Settings

- `utilization`
  GPU load ceiling from `1` to `100`.
  `100` means maximum allowed GPU load.

- `yielding`
  Friendly GPU sharing mode.
  When enabled, the miner gives GPU resources to other applications when needed.

Current CUDA settings are shown:

- after CUDA install/switch
- in `node info`

## Logs

The log viewer has 2 modes:

- `normal logs`
  Full container logs without filtering

- `miner logs`
  Filtered view that hides noisy lines from:
  `node_client.py`
  `peer_ban_list.py`
  `telemetry.py`

This makes it easier to watch actual mining activity instead of network spam.

## Identity Persistence

When switching between `CPU` and `CUDA`, the script keeps:

- `secret`
- `node_name`
- `public_host`

This means your node identity is preserved during normal profile switching.

The secret changes only if you remove the installation or delete the config manually.

## What You Need

- Linux VPS or server
- root access
- Docker support
- NVIDIA GPU and drivers if you want CUDA mode

## Usage

Run:

```bash
sudo bash quip.sh
```

Then use the menu to install and manage the node.

## Notes

- CPU mode uses configurable CPU worker count
- CUDA mode uses one miner per detected GPU device
- if GPU settings are not explicitly saved yet, CUDA falls back to:
  `utilization = 100`
  `yielding = false`

## Contacts

- Telegram Channel: https://t.me/SotochkaZela
- Telegram Chat: https://t.me/sotochkachat
