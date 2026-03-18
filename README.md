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

## Example with local SDK server

If your local SDK server listens on `127.0.0.1:8787` and `TUNNEL_REMOTE_PORT=18787`, then on the remote machine:

```bash
curl http://127.0.0.1:18787/healthz
```
