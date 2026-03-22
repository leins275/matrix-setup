# Matrix Synapse Self-Hosted Server

A fully automated, reproducible deployment of a **Matrix Synapse** homeserver with:

- [Matrix Synapse](https://github.com/element-hq/synapse) — homeserver
- [PostgreSQL 15](https://www.postgresql.org/) — database
- [Coturn](https://github.com/coturn/coturn) — STUN/TURN for legacy 1:1 calls
- [LiveKit](https://livekit.io/) — modern SFU for group video (Element X / Element Call)
- [lk-jwt-service](https://github.com/element-hq/lk-jwt-service) — JWT auth for LiveKit
- [Synapse Admin](https://github.com/Awesome-Technologies/synapse-admin) — web admin UI
- [Nginx Proxy Manager](https://nginxproxymanager.com/) — reverse proxy + automatic SSL

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Part 1 — Manual Steps (Server & DNS)](#part-1--manual-steps-server--dns)
   - [Step 1: Create a VPS](#step-1-create-a-vps)
   - [Step 2: Configure DNS Records](#step-2-configure-dns-records)
   - [Step 3: Prepare Your Local Machine](#step-3-prepare-your-local-machine)
4. [Part 2 — Automated Setup with Ansible](#part-2--automated-setup-with-ansible)
   - [Step 4: Clone This Repository](#step-4-clone-this-repository)
   - [Step 5: Generate Secrets](#step-5-generate-secrets)
   - [Step 6: Configure Variables](#step-6-configure-variables)
   - [Step 7: Run the Playbook](#step-7-run-the-playbook)
5. [Part 3 — Post-Deploy: Configure Nginx Proxy Manager](#part-3--post-deploy-configure-nginx-proxy-manager)
   - [Step 8: Log In and Create Proxy Hosts](#step-8-log-in-and-create-proxy-hosts)
   - [Step 9: Add .well-known for LiveKit Discovery](#step-9-add-well-known-for-livekit-discovery)
6. [Verification](#verification)
7. [Port Reference](#port-reference)
8. [Directory Layout on Server](#directory-layout-on-server)
9. [Useful Commands](#useful-commands)
10. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
                    Internet
                       │
              ┌────────▼────────┐
              │  Nginx Proxy    │  :80 / :443
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

### On your local machine

- Python 3.10+
- `make`
- `ansible` and `ansible-galaxy`
- An SSH key pair (`~/.ssh/id_ed25519` recommended)

Install Ansible:

```bash
pip install ansible
```

### Server requirements

- Ubuntu 22.04 LTS (recommended) or 24.04 LTS
- Minimum 2 vCPU, 2 GB RAM, 20 GB SSD
- A public IPv4 address
- Root SSH access to the fresh server (for the initial run)

---

## Part 1 — Manual Steps (Server & DNS)

These steps must be done **before** running Ansible.

### Step 1: Create a VPS

Create a fresh Ubuntu 22.04 server with your preferred provider:

| Provider | Notes |
|---|---|
| DigitalOcean | Droplets → Ubuntu 22.04 |
| Hetzner | Cloud → Ubuntu 22.04 |
| Vultr | Cloud Compute → Ubuntu 22.04 |
| Linode/Akamai | Linodes → Ubuntu 22.04 |

**Important — Cloud firewall / Security Groups:**  
Many providers have a network-level firewall *in addition* to UFW. You must open the following ports in their dashboard too:

| Port(s) | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80, 443 | TCP | HTTP/HTTPS |
| 81 | TCP | Nginx Proxy Manager admin |
| 8080 | TCP | Synapse Admin UI |
| 3478, 5349 | TCP + UDP | Coturn STUN/TURN |
| 7881 | TCP | LiveKit WebRTC |
| 49152–65535 | UDP | Coturn relay range |
| 50000–50200 | UDP | LiveKit media range |

> **Note:** Port 8081 (lk-jwt-service) and 7880 (LiveKit HTTP) do **not** need to be publicly exposed — they are accessed only via Nginx Proxy Manager from inside the same host.

Add your SSH public key to the server during creation (or copy it manually with `ssh-copy-id root@YOUR_SERVER_IP`).

---

### Step 2: Configure DNS Records

Log into your domain registrar (Namecheap, Cloudflare, GoDaddy, etc.) and add the following **A records**, replacing `YOUR_SERVER_IP` with your server's public IPv4 address:

| Type | Name / Host | Value | TTL |
|---|---|---|---|
| A | `matrix` | `YOUR_SERVER_IP` | 3600 |
| A | `livekit` | `YOUR_SERVER_IP` | 3600 |
| A | `call-auth` | `YOUR_SERVER_IP` | 3600 |

> **Example:** If your domain is `example.com`, the three hostnames will be `matrix.example.com`, `livekit.example.com`, and `call-auth.example.com`.

**Verify DNS propagation** (wait a few minutes, then run):

```bash
ping -c 2 matrix.example.com
ping -c 2 livekit.example.com
ping -c 2 call-auth.example.com
```

All three should resolve to your server's IP before proceeding.

---

### Step 3: Prepare Your Local Machine

Ensure you have an SSH key and can log into the server:

```bash
# Generate a key if you don't have one
ssh-keygen -t ed25519 -C "matrix-deploy"

# Test root access (required for the first Ansible run)
ssh root@YOUR_SERVER_IP
```

---

## Part 2 — Automated Setup with Ansible

### Step 4: Clone This Repository

```bash
git clone https://github.com/YOUR_USERNAME/matrix-setup.git
cd matrix-setup
```

---

### Step 5: Generate Secrets

Run the following commands and save the output — you will need them in the next step:

```bash
# Database password
openssl rand -hex 16

# Coturn shared secret
openssl rand -hex 24

# LiveKit secret
openssl rand -hex 32
```

Also choose a strong password for your Matrix admin account.

---

### Step 6: Configure Variables

**6a. Edit the inventory file**

Open `ansible/inventory.ini` and replace `YOUR_SERVER_IP` with your server's IP:

```ini
[matrix_servers]
matrix ansible_host=1.2.3.4 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

> **Note:** Use `ansible_user=root` for the first run. After Ansible creates the `usr` account you can switch to `ansible_user=usr`.

**6b. Create your host variables file**

```bash
cp ansible/host_vars/YOUR_SERVER_IP.yml.example ansible/host_vars/1.2.3.4.yml
```

Open `ansible/host_vars/1.2.3.4.yml` and fill in **every** value:

```yaml
matrix_domain: "matrix.example.com"
livekit_domain: "livekit.example.com"
call_auth_domain: "call-auth.example.com"
base_domain: "example.com"

server_public_ip: "1.2.3.4"

db_password: "PASTE_YOUR_DB_PASSWORD"
coturn_secret: "PASTE_YOUR_COTURN_SECRET"
livekit_secret: "PASTE_YOUR_LIVEKIT_SECRET"

matrix_admin_user: "admin"
matrix_admin_password: "PASTE_YOUR_ADMIN_PASSWORD"

deploy_user: "usr"
deploy_user_ssh_key: "{{ lookup('file', '~/.ssh/id_ed25519.pub') }}"

ssh_allowed_from: "any"   # or set to your static IP for tighter security
```

---

### Step 7: Run the Playbook

```bash
make install   # Install Ansible collections (run once)
make run       # Deploy everything
```

What `make run` does, in order:

1. **System hardening** — updates packages, creates `usr` user, hardens SSH (disables root + password login), configures UFW firewall, enables fail2ban
2. **Docker install** — installs Docker Engine and Compose plugin, adds `usr` to the `docker` group
3. **Matrix deploy** — writes all config files from templates, generates Synapse config, starts the full Docker Compose stack, waits for Synapse to be healthy, creates the admin user

> **Total runtime:** approximately 5–10 minutes on a fresh server.

To run only specific parts:

```bash
make run TAGS=hardening   # Only run system hardening
make run TAGS=docker      # Only install Docker
make run TAGS=matrix      # Only deploy Matrix stack
```

To do a dry run without making changes:

```bash
make check
```

---

## Part 3 — Post-Deploy: Configure Nginx Proxy Manager

After Ansible completes, Nginx Proxy Manager is running but not yet configured. This step is done **once** through its web UI.

### Step 8: Log In and Create Proxy Hosts

1. Open `http://YOUR_SERVER_IP:81` in your browser
2. Log in with the default credentials:
   - **Email:** `admin@example.com`
   - **Password:** `changeme`
3. **Change the default password immediately.**
4. Go to **Hosts → Proxy Hosts → Add Proxy Host** and create the following three entries:

**Host 1 — Synapse**

| Field | Value |
|---|---|
| Domain Names | `matrix.example.com` |
| Forward Hostname/IP | `synapse` (Docker service name) |
| Forward Port | `8008` |
| Websockets Support | ✅ On |
| SSL → Request new certificate | ✅ Force SSL, ✅ HTTP/2 |

**Host 2 — LiveKit**

| Field | Value |
|---|---|
| Domain Names | `livekit.example.com` |
| Forward Hostname/IP | `YOUR_SERVER_IP` |
| Forward Port | `7880` |
| Websockets Support | ✅ On (required!) |
| SSL → Request new certificate | ✅ Force SSL, ✅ HTTP/2 |

**Host 3 — Call Auth (JWT Service)**

| Field | Value |
|---|---|
| Domain Names | `call-auth.example.com` |
| Forward Hostname/IP | `YOUR_SERVER_IP` |
| Forward Port | `8081` |
| Websockets Support | ✅ On |
| SSL → Request new certificate | ✅ Force SSL, ✅ HTTP/2 |

> **Important for LiveKit and Call-Auth:** Use `YOUR_SERVER_IP` (not `localhost` or `127.0.0.1`) because LiveKit runs with `network_mode: host` and Nginx Proxy Manager runs inside Docker — `localhost` inside NPM's container points to NPM itself, not to the host.

---

### Step 9: Add .well-known for LiveKit Discovery

Matrix clients (Element X, Element Call) need to discover the LiveKit server via a `.well-known` file. This is served from the **Synapse** proxy host.

1. In Nginx Proxy Manager, edit the `matrix.example.com` proxy host
2. Click the **Advanced** tab
3. Paste the following into the **Custom Nginx Configuration** box (replace with your actual domains):

```nginx
location /.well-known/matrix/client {
    add_header Access-Control-Allow-Origin '*';
    add_header Content-Type application/json;
    return 200 '{
        "m.homeserver": {
            "base_url": "https://matrix.example.com"
        },
        "org.matrix.msc4143.rtc_foci": [
            {
                "type": "livekit",
                "livekit_service_url": "https://call-auth.example.com"
            }
        ]
    }';
}

location /.well-known/matrix/server {
    add_header Access-Control-Allow-Origin '*';
    add_header Content-Type application/json;
    return 200 '{"m.server": "matrix.example.com:443"}';
}
```

4. Click **Save**

**Verify it works:**

```bash
curl https://matrix.example.com/.well-known/matrix/client
curl https://matrix.example.com/.well-known/matrix/server
```

---

## Verification

Run through this checklist after the full setup:

```bash
# 1. Check all containers are running
ssh usr@YOUR_SERVER_IP "docker compose -f ~/matrix/docker-compose.yml ps"

# 2. Check Synapse is healthy
curl https://matrix.example.com/_matrix/client/versions

# 3. Check well-known
curl https://matrix.example.com/.well-known/matrix/client

# 4. Check LiveKit is alive (look for "started listening")
ssh usr@YOUR_SERVER_IP "docker logs matrix-livekit-1 2>&1 | tail -20"
```

**Connect with a Matrix client:**

1. Open [Element Web](https://app.element.io) or install Element X on mobile
2. When prompted for homeserver, enter: `https://matrix.example.com`
3. Log in with `@admin:matrix.example.com` and the password you set

**Synapse Admin UI:**

Access at `http://YOUR_SERVER_IP:8080` — log in with your Matrix admin credentials and the homeserver URL `https://matrix.example.com`.

---

## Port Reference

| Port | Protocol | Service | Publicly exposed |
|---|---|---|---|
| 22 | TCP | SSH | Yes |
| 80 | TCP | HTTP (redirects to HTTPS) | Yes |
| 443 | TCP | HTTPS | Yes |
| 81 | TCP | Nginx Proxy Manager UI | Yes |
| 3478 | TCP+UDP | Coturn STUN/TURN | Yes |
| 5349 | TCP+UDP | Coturn STUN/TURN TLS | Yes |
| 7881 | TCP | LiveKit WebRTC | Yes |
| 8080 | TCP | Synapse Admin UI | Yes |
| 49152–65535 | UDP | Coturn relay range | Yes |
| 50000–50200 | UDP | LiveKit media | Yes |
| 7880 | TCP | LiveKit HTTP (internal) | No — via NPM only |
| 8008 | TCP | Synapse (internal) | No — via NPM only |
| 8081 | TCP | lk-jwt-service | No — via NPM only |
| 5432 | TCP | PostgreSQL (internal) | No |

---

## Directory Layout on Server

```
/home/usr/matrix/
├── .env                        # Secrets (not committed to git)
├── docker-compose.yml          # Full stack definition
├── coturn/
│   └── turnserver.conf         # Coturn configuration
├── livekit/
│   └── livekit.yaml            # LiveKit configuration
├── nginx/
│   ├── data/                   # Nginx Proxy Manager data
│   └── letsencrypt/            # SSL certificates
├── postgresdata/               # PostgreSQL data volume
├── synapse-data/
│   ├── homeserver.yaml         # Synapse main config
│   ├── *.signing.key           # Server signing key
│   ├── *.log.config            # Log configuration
│   └── media_store/            # Uploaded media
└── create-admin.sh             # Script to create admin user manually
```

---

## Useful Commands

All run from `/home/usr/matrix/` on the server (or via `ssh usr@SERVER`):

```bash
# View running containers
docker compose ps

# Follow all logs
docker compose logs -f

# Follow only Synapse logs
docker compose logs -f synapse

# Restart the entire stack
docker compose restart

# Restart only Synapse
docker compose restart synapse

# Stop everything
docker compose down

# Start everything
docker compose up -d

# Create a new (non-admin) Matrix user
docker exec -it matrix-synapse-1 register_new_matrix_user \
    -c /data/homeserver.yaml http://localhost:8008 \
    -u USERNAME -p PASSWORD

# Create a new admin Matrix user
docker exec -it matrix-synapse-1 register_new_matrix_user \
    -c /data/homeserver.yaml http://localhost:8008 \
    --admin -u USERNAME -p PASSWORD

# Check disk usage
df -h
docker system df
```

---

## Troubleshooting

### Synapse fails to start — database collation error

Synapse requires the PostgreSQL database to use `C` collation. The docker-compose.yml in this repo already sets this via `POSTGRES_INITDB_ARGS`. If you are migrating an old database, you need to recreate it:

```bash
docker compose down
sudo rm -rf ~/matrix/postgresdata/
docker compose up -d
```

### DNS_PROBE_FINISHED_NXDOMAIN in browser

Your DNS records have not propagated yet. Wait a few minutes, then verify:

```bash
nslookup matrix.example.com
```

### "Insufficient capacity" error in Element when making a call

This means Element cannot connect to LiveKit. Check in order:

1. **WebSocket support** is enabled on the `livekit.example.com` Nginx Proxy Manager entry
2. **Cloud firewall** allows UDP 50000–50200 and TCP 7881
3. LiveKit is healthy: `docker logs matrix-livekit-1 2>&1 | grep -i "started\|error"`
4. The forward address for LiveKit in NPM uses the server's real IP, not `localhost`

### "MISSING_MATRIX_RTC_TRANSPORT" error in Element

The `.well-known/matrix/client` file is not being served correctly, or the custom nginx config in NPM is missing. Re-check [Step 9](#step-9-add-well-known-for-livekit-discovery).

### SSH locked out after first Ansible run

The playbook disables password auth and root login. Make sure your SSH public key was added before running. If locked out, use your provider's VNC/console to re-add your key or temporarily re-enable password auth.

### Ansible fails with "Module not found" for community.docker

Run `make install` to install required Ansible collections before `make run`.
