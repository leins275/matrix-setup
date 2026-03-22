# Matrix Synapse Self-Hosted Server

A fully automated, reproducible deployment of a **Matrix Synapse** homeserver with:

- [Matrix Synapse](https://github.com/element-hq/synapse) — homeserver
- [PostgreSQL 15](https://www.postgresql.org/) — database
- [Coturn](https://github.com/coturn/coturn) — STUN/TURN for legacy 1:1 calls
- [LiveKit](https://livekit.io/) — modern SFU for group video (Element X / Element Call)
- [lk-jwt-service](https://github.com/element-hq/lk-jwt-service) — JWT auth for LiveKit
- [Synapse Admin](https://github.com/Awesome-Technologies/synapse-admin) — web admin UI
- [Nginx Proxy Manager](https://nginxproxymanager.com/) — reverse proxy + automatic SSL

After completing the two manual steps (server creation and DNS), run `make install && make run` and the playbook handles everything else: system hardening, Docker installation, all config generation, stack startup, Matrix admin user creation, and full Nginx Proxy Manager configuration including SSL certificates.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Part 1 — Manual Steps (Server & DNS)](#part-1--manual-steps-server--dns)
   - [Step 1: Create a VPS](#step-1-create-a-vps)
   - [Step 2: Configure DNS Records](#step-2-configure-dns-records)
4. [Part 2 — Automated Setup with Ansible](#part-2--automated-setup-with-ansible)
   - [Step 3: Prepare Your Local Machine](#step-3-prepare-your-local-machine)
   - [Step 4: Clone This Repository](#step-4-clone-this-repository)
   - [Step 5: Generate Secrets](#step-5-generate-secrets)
   - [Step 6: Configure Variables](#step-6-configure-variables)
   - [Step 7: Run the Playbook](#step-7-run-the-playbook)
5. [Verification](#verification)
6. [Port Reference](#port-reference)
7. [Directory Layout on Server](#directory-layout-on-server)
8. [Useful Commands](#useful-commands)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
                    Internet
                       │
              ┌────────▼────────┐
              │  Nginx Proxy    │  :80 / :443  (auto SSL via Let's Encrypt)
              │  Manager        │  :81  (admin UI)
              └──┬──────────┬───┘
                 │          │
        ┌────────▼──┐  ┌────▼────────────┐
        │  Synapse  │  │  lk-jwt-service │ :8081
        │  :8008    │  └────────┬────────┘
        └─────┬─────┘           │
              │           ┌─────▼────────┐
        ┌─────▼─────┐     │   LiveKit    │ :7880/:7881
        │ PostgreSQL│     │   SFU        │ UDP 50000-50200
        │ :5432     │     └──────────────┘
        └───────────┘
        ┌───────────┐
        │  Coturn   │ :3478/:5349 UDP+TCP
        │  STUN/TURN│ UDP 49152-65535
        └───────────┘
        ┌───────────┐
        │  Synapse  │ :8080
        │  Admin    │
        └───────────┘
```

---

## Prerequisites

### Local machine

- Python 3.10+
- `make`
- `ansible` — install with `pip install ansible`
- An SSH key pair (`~/.ssh/id_ed25519` recommended)

### Server

- Ubuntu 24.04 LTS
- Minimum 2 vCPU, 2 GB RAM, 20 GB SSD
- A public IPv4 address
- Root SSH access on the fresh server

---

## Part 1 — Manual Steps (Server & DNS)

These two steps must be done **before** running Ansible, as they require external services.

### Step 1: Create a VPS

Create a fresh Ubuntu 24.04 server at your preferred provider (Hetzner, DigitalOcean, Vultr, Linode, etc.).

**During creation:** add your SSH public key so you can connect as root.

**Cloud firewall / Security Groups:**  
Many providers have a network-level firewall separate from UFW. If yours does, open these ports in the provider dashboard:

| Port(s) | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80, 443 | TCP | HTTP / HTTPS |
| 81 | TCP | Nginx Proxy Manager admin |
| 8080 | TCP | Synapse Admin UI |
| 3478, 5349 | TCP + UDP | Coturn STUN/TURN |
| 7881 | TCP | LiveKit WebRTC |
| 49152–65535 | UDP | Coturn relay range |
| 50000–50200 | UDP | LiveKit media range |

> Ports 7880 (LiveKit HTTP), 8008 (Synapse), and 8081 (lk-jwt-service) are internal — accessed only via Nginx Proxy Manager from within the host.

Test that you can log in:

```bash
ssh root@YOUR_SERVER_IP
```

---

### Step 2: Configure DNS Records

Log into your domain registrar and add three **A records**, replacing `YOUR_SERVER_IP` with your server's public IP:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `matrix` | `YOUR_SERVER_IP` | 3600 |
| A | `livekit` | `YOUR_SERVER_IP` | 3600 |
| A | `call-auth` | `YOUR_SERVER_IP` | 3600 |

Verify propagation before proceeding (may take a few minutes):

```bash
ping -c 2 matrix.example.com
ping -c 2 livekit.example.com
ping -c 2 call-auth.example.com
```

All three must resolve to your server's IP.

---

## Part 2 — Automated Setup with Ansible

### Step 3: Prepare Your Local Machine

```bash
# Install Ansible
pip install ansible

# Confirm your SSH key exists
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C "matrix-deploy"
```

---

### Step 4: Clone This Repository

```bash
git clone https://github.com/YOUR_USERNAME/matrix-setup.git
cd matrix-setup
```

---

### Step 5: Generate Secrets

Run these three commands and save the output for the next step:

```bash
openssl rand -hex 16   # → db_password
openssl rand -hex 24   # → coturn_secret
openssl rand -hex 32   # → livekit_secret
```

---

### Step 6: Configure Variables

**6a. Edit the inventory**

Open `ansible/inventory.ini` and replace `YOUR_SERVER_IP` with your server's IP address:

```ini
[matrix]
server ansible_host=1.2.3.4 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

> Use `ansible_user=root` for the initial run. The playbook will create the `usr` account and harden SSH. Subsequent runs can use `ansible_user=usr`.

**6b. Fill in `ansible/vars.yml`**

Open `ansible/vars.yml` and fill in every value:

```yaml
matrix_domain: "matrix.example.com"
livekit_domain: "livekit.example.com"
call_auth_domain: "call-auth.example.com"

server_public_ip: "1.2.3.4"

db_password: "your_hex_16_value"
coturn_secret: "your_hex_24_value"
livekit_secret: "your_hex_32_value"
livekit_key_id: "matrix-key"

matrix_admin_user: "admin"
matrix_admin_password: "strong_password"

npm_admin_email: "you@example.com"
npm_admin_password: "strong_password"

letsencrypt_email: "you@example.com"
```

> **Security note:** `ansible/vars.yml` is in `.gitignore` — your secrets will never be committed.

---

### Step 7: Run the Playbook

```bash
make install   # install required Ansible collections (once)
make run       # deploy everything
```

**What Ansible does, in order:**

| Phase | Role | Actions |
|---|---|---|
| System hardening | `common` | `apt` upgrade, create `usr` user + sudo, harden SSH (disable root + password login), configure UFW with all required ports, enable fail2ban and unattended-upgrades |
| Docker | `docker` | Install Docker Engine + Compose plugin from official repo, add `usr` to `docker` group |
| Matrix stack | `matrix` | Write all config files, generate Synapse config, pull and start all containers, wait for Synapse health, create admin user, configure Nginx Proxy Manager via API (set credentials, create 3 proxy hosts with Let's Encrypt SSL, add `.well-known` endpoints) |

> **Total runtime:** approximately 5–10 minutes on a fresh server.

To run only a specific phase:

```bash
make hardening   # system hardening only
make docker      # Docker install only
make matrix      # Matrix stack only
make check       # dry run (no changes made)
```

---

## Verification

After the playbook completes, verify the stack is working:

```bash
# All containers should be Up
ssh usr@YOUR_SERVER_IP "docker compose -f ~/matrix/docker-compose.yml ps"

# Synapse federation endpoint
curl https://matrix.example.com/_matrix/client/versions

# well-known discovery (used by Element X for LiveKit)
curl https://matrix.example.com/.well-known/matrix/client
curl https://matrix.example.com/.well-known/matrix/server

# LiveKit health (look for "started listening" in logs)
ssh usr@YOUR_SERVER_IP "docker logs matrix-livekit-1 2>&1 | tail -20"
```

**Connect with a Matrix client:**

1. Open [Element Web](https://app.element.io) or install Element X on mobile
2. Enter your homeserver URL: `https://matrix.example.com`
3. Log in as `@admin:matrix.example.com` with the password you set

**Synapse Admin UI:**

Access at `http://YOUR_SERVER_IP:8080` — log in with your Matrix admin credentials and homeserver URL `https://matrix.example.com`.

---

## Port Reference

| Port | Protocol | Service | Publicly exposed |
|---|---|---|---|
| 22 | TCP | SSH | Yes |
| 80 | TCP | HTTP (redirects to HTTPS) | Yes |
| 443 | TCP | HTTPS | Yes |
| 81 | TCP | Nginx Proxy Manager admin UI | Yes |
| 3478, 5349 | TCP + UDP | Coturn STUN/TURN | Yes |
| 7881 | TCP | LiveKit WebRTC | Yes |
| 8080 | TCP | Synapse Admin UI | Yes |
| 49152–65535 | UDP | Coturn relay range | Yes |
| 50000–50200 | UDP | LiveKit media range | Yes |
| 7880 | TCP | LiveKit HTTP (internal) | No — proxied via NPM |
| 8008 | TCP | Synapse (internal) | No — proxied via NPM |
| 8081 | TCP | lk-jwt-service (internal) | No — proxied via NPM |
| 5432 | TCP | PostgreSQL (internal) | No |

---

## Directory Layout on Server

```
/home/usr/matrix/
├── docker-compose.yml          # Full stack definition (all secrets inlined)
├── coturn/
│   └── turnserver.conf
├── livekit/
│   └── livekit.yaml
├── nginx/
│   ├── data/                   # Nginx Proxy Manager runtime data
│   └── letsencrypt/            # SSL certificates
├── postgresdata/               # PostgreSQL data volume
├── synapse-data/
│   ├── homeserver.yaml
│   ├── *.signing.key
│   ├── *.log.config
│   └── media_store/
└── create-admin.sh             # Helper to create additional Matrix users
```

---

## Useful Commands

Run on the server from `/home/usr/matrix/`:

```bash
# View all containers and their status
docker compose ps

# Follow logs for all services
docker compose logs -f

# Follow logs for a single service
docker compose logs -f synapse

# Restart the entire stack
docker compose restart

# Restart a single service
docker compose restart synapse

# Stop and start the full stack
docker compose down && docker compose up -d

# Create an additional (non-admin) Matrix user
docker exec -it matrix-synapse-1 register_new_matrix_user \
    -c /data/homeserver.yaml http://localhost:8008 \
    -u USERNAME -p PASSWORD

# Create an additional admin Matrix user
docker exec -it matrix-synapse-1 register_new_matrix_user \
    -c /data/homeserver.yaml http://localhost:8008 \
    --admin -u USERNAME -p PASSWORD

# Check disk usage
df -h && docker system df
```

---

## Troubleshooting

### Synapse fails to start — database collation error

The `docker-compose.yml` already sets `POSTGRES_INITDB_ARGS` to enforce `C` collation. If you see this error on an existing deployment with stale data:

```bash
docker compose down
sudo rm -rf ~/matrix/postgresdata/
docker compose up -d
```

### DNS not resolving (`DNS_PROBE_FINISHED_NXDOMAIN`)

DNS propagation is not complete yet. Verify from the command line:

```bash
nslookup matrix.example.com
```

Wait a few minutes and retry. Ansible will also fail at the NPM SSL step if DNS is not ready.

### NPM proxy host creation fails (SSL certificate error)

Let's Encrypt requires the domain to be publicly reachable on port 80. Ensure:
- DNS A records are fully propagated
- Port 80 is open in both UFW and any cloud firewall
- No existing conflicting proxy hosts in NPM

Re-run only the matrix role after fixing: `make matrix`

### "Insufficient capacity" error in Element during a call

Element found the JWT service but cannot reach LiveKit. Check:

1. Cloud firewall allows UDP 50000–50200 and TCP 7881
2. LiveKit container is healthy: `docker logs matrix-livekit-1 2>&1 | grep -i "started\|error"`
3. The `livekit.example.com` proxy host in NPM has **WebSocket support** enabled (set automatically by Ansible)

### "MISSING_MATRIX_RTC_TRANSPORT" in Element

The `.well-known/matrix/client` endpoint is not returning valid JSON. Verify:

```bash
curl -s https://matrix.example.com/.well-known/matrix/client | python3 -m json.tool
```

If it returns an error, the custom Nginx config in the Synapse proxy host may not have been applied. Re-run `make matrix` to re-apply.

### SSH locked out after first Ansible run

The playbook disables password authentication and root login. Ensure your SSH public key was deployed before running. If locked out, use your provider's web console to restore access.

### Ansible fails with "collection not found"

Run `make install` before `make run` to install the required Ansible collections.
