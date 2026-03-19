# HTTP Reverse Tunnel

Generic SSH reverse tunnel scripts to expose a local HTTP service on a remote host.

This repo is intentionally separate from any specific SDK server repo.

## Setup

```bash
cd /Users/yongqiwu/code/http-reverse-tunnel
cp .env.example .env
```

## Check SSH connectivity

```bash
bash scripts/check-ssh.sh
```

## Start reverse tunnel

```bash
bash scripts/start-reverse-tunnel.sh
```

If `TUNNEL_REMOTE_PORT` is unset, it defaults to `TUNNEL_LOCAL_PORT` so both ends stay consistent by default.

## Tunnel Health Check + Auto Reconnect

`scripts/start-reverse-tunnel.sh` now runs as a supervisor:

- Performs remote-side HTTP checks through the tunnel:
  - `http://${TUNNEL_REMOTE_BIND_HOST}:${TUNNEL_REMOTE_PORT}${TUNNEL_HEALTH_PATH}`
- Automatically reconnects when the SSH process exits or health checks fail repeatedly.

Defaults:

- Health path: `/healthz`
- Check interval: `15s`
- Max consecutive failures before restart: `3`

You can tune all of these in `.env` (see `.env.example`).

## Example with local SDK server

If your local SDK server listens on `127.0.0.1:8787` and `TUNNEL_REMOTE_PORT=8787`, then on the remote machine:

```bash
curl http://127.0.0.1:8787/healthz
```
