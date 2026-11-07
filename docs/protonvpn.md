# Proton VPN setup

The stack uses WireGuard through Gluetun. It never asks for your Proton e-mail or password.

## Get the WireGuard private key

1. Sign in at <https://account.proton.me/u/0/vpn/WireGuard>.
2. Create a configuration (any platform, any server). The key works for all Proton servers.
3. Download the `.conf` file and copy the value of `PrivateKey` (44 characters ending in `=`).
4. Put it in `.env`:

   ```dotenv
   WIREGUARD_PRIVATE_KEY=...
   ```

5. Delete the downloaded `.conf` file. Never commit it (`*.conf` is git-ignored).

`./scripts/validate.sh` checks that the key is base64 for exactly 32 bytes, without printing it.

## Choose the exit location

```dotenv
SERVER_COUNTRIES=Netherlands
SERVER_CITIES=
```

Names follow Gluetun's Proton server list (for example `Germany`, `United States`, `Japan`).
A wrong name makes Gluetun unhealthy and the log lists valid choices:

```bash
docker compose logs gluetun | grep "not valid"
```

Free Proton plans only work with free servers; this stack does not set `FREE_ONLY` and assumes a paid plan.

## Rotate the key

Generate a new configuration in the Proton dashboard, revoke the old one, update `.env`, then
`docker compose up -d`.

## Check the current exit IP

```bash
./scripts/test-vpn.sh
```

## Rotate the exit IP

```bash
./scripts/rotate-ip.sh                  # up to 3 reconnects until the IP changes
./scripts/rotate-ip.sh --max-attempts 5 # 1-10
```

It reconnects the tunnel through Gluetun's control server; Gluetun picks a random server matching
`SERVER_COUNTRIES`/`SERVER_CITIES`, so the IP usually changes on the first attempt (about 15 s).
`api` and `playwright` are not restarted. Scrapes running during the reconnect fail instead of leaving
through the host. Output shows masked IPs only.

| Exit code | Meaning |
|---|---|
| 0 | Rotated |
| 1 | IP unchanged after all attempts: the filter matches too few servers, widen it |
| 2 | Control server or tunnel error (stack down, wrong `GLUETUN_CONTROL_API_KEY`, tunnel not back in 180 s) |
| 3 | Another rotation is running |
| 64 | Bad arguments |

Interrupting it (Ctrl-C, `kill`, SSH disconnect) restores the tunnel before exiting.
`./scripts/test-rotation.sh` proves the IP changes without leaking the host IP or restarting services.

## Responsible use

Follow Proton's terms of service and the terms and `robots.txt` of the sites you scrape.
This project does not implement CAPTCHA solving or fingerprint evasion.
