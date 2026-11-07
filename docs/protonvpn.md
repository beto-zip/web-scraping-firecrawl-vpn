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

## Responsible use

Follow Proton's terms of service and the terms and `robots.txt` of the sites you scrape.
This project does not implement CAPTCHA solving or fingerprint evasion.
