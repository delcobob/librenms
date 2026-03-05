# LibreNMS Docker Deployment Guide — Ubuntu 24.04 LTS

> **Last updated:** March 2026
> **Target OS:** Ubuntu 24.04 LTS (Noble Numbat)
> **Deployment method:** Docker Compose
> **Database:** MySQL 8.0

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [System Requirements](#system-requirements)
3. [File Inventory](#file-inventory)
4. [Complete Environment Variable Reference](#complete-environment-variable-reference)
5. [Prerequisites — Install Docker Engine](#prerequisites--install-docker-engine)
6. [Deployment Steps](#deployment-steps)
7. [Post-Deployment Configuration](#post-deployment-configuration)
8. [Network Device Configuration](#network-device-configuration)
9. [Alerting & Notifications](#alerting--notifications)
10. [Reverse Proxy with HTTPS](#reverse-proxy-optional--nginx-with-https)
11. [Firewall Rules](#firewall-rules)
12. [Backup & Restore](#backup--restore)
13. [Updating LibreNMS](#updating-librenms)
14. [Scaling & Performance Tuning](#scaling--performance-tuning)
15. [Security Hardening](#security-hardening)
16. [Useful Commands Reference](#useful-commands-reference)
17. [Troubleshooting](#troubleshooting)
18. [Docker Volume Locations](#docker-volume-locations)

---

## Architecture Overview

This deployment runs 7 Docker containers on a single host, interconnected via a private Docker bridge network (`172.20.0.0/24`). No container ports are exposed to the internal Docker network except those explicitly published to the host.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Ubuntu 24.04 LTS Host                              │
│                                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐   │
│  │  librenms    │  │  dispatcher  │  │  syslogng    │  │  snmptrapd     │   │
│  │  (Web UI)    │  │  (Poller)    │  │  (Syslog)    │  │  (SNMP Traps)  │   │
│  │  :8000→8000  │  │  no ports    │  │  :514→514    │  │  :162→162      │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬─────────┘  │
│         │                 │                  │                  │            │
│         └────────┬────────┴──────────┬───────┴──────────┬──────┘            │
│                  │                   │                   │                   │
│           ┌──────┴──────┐    ┌───────┴──────┐   ┌───────┴──────┐           │
│           │    MySQL    │    │    Redis     │   │  RRDcached   │           │
│           │    8.0      │    │    7-alpine  │   │              │           │
│           │  (internal) │    │  (internal)  │   │  (internal)  │           │
│           └─────────────┘    └──────────────┘   └──────────────┘           │
│                                                                             │
│  Docker Volumes:                                                            │
│    db_data (/var/lib/mysql)     librenms_data (/data)                      │
│    rrd_data (/data/rrd)         rrd_journal (/data/journal)                │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Service Descriptions

| Service | Container Name | Image | Purpose | Exposed Ports |
|---------|---------------|-------|---------|---------------|
| **db** | `librenms_db` | `mysql:8.0` | Stores all device data, users, alerts, syslog entries. Runs with `innodb-file-per-table=1`, `utf8mb4` charset. | None (internal only) |
| **redis** | `librenms_redis` | `redis:7-alpine` | In-memory cache for sessions and distributed poller locking. Required for multi-container polling. | None (internal only) |
| **rrdcached** | `librenms_rrdcached` | `crazymax/rrdcached` | Buffers RRD file writes in memory, flushing every 1800s. Dramatically reduces disk I/O. | None (internal only) |
| **librenms** | `librenms` | `librenms/librenms:latest` | Main web frontend (Nginx + PHP-FPM). Serves the UI, API, and runs scheduled cron jobs (discovery, alerts, daily maintenance). | `8000/tcp` |
| **dispatcher** | `librenms_dispatcher` | `librenms/librenms:latest` | Runs background SNMP polling workers. Pulls work from Redis queue, polls devices, writes results to MySQL and RRD. | None |
| **syslogng** | `librenms_syslogng` | `librenms/librenms:latest` | Receives syslog messages from network devices and writes them into the LibreNMS database for viewing/alerting. | `514/udp`, `514/tcp` |
| **snmptrapd** | `librenms_snmptrapd` | `librenms/librenms:latest` | Receives SNMP traps/informs from network devices, processes them, and creates events/alerts in LibreNMS. | `162/udp`, `162/tcp` |

### Data Flow

1. **Polling:** `dispatcher` → SNMP to devices → results to `db` (MySQL) + `rrdcached` (RRD graphs)
2. **Syslog:** Network devices → UDP/TCP 514 → `syslogng` → `db` (MySQL)
3. **SNMP Traps:** Network devices → UDP 162 → `snmptrapd` → `db` (MySQL)
4. **Web UI:** Browser → `librenms` (:8000) → reads from `db` + `rrdcached` + `redis`
5. **Cron jobs:** `librenms` container runs discovery, alerts, daily.sh, billing internally on schedule

---

## System Requirements

### Minimum (up to ~100 devices)
| Resource | Requirement |
|----------|------------|
| CPU | 2 cores |
| RAM | 4 GB |
| Disk | 40 GB SSD |
| Network | 1 Gbps NIC |

### Recommended (100–500 devices)
| Resource | Requirement |
|----------|------------|
| CPU | 4 cores |
| RAM | 8 GB |
| Disk | 100 GB SSD (NVMe preferred) |
| Network | 1 Gbps NIC |

### Large (500–2000+ devices)
| Resource | Requirement |
|----------|------------|
| CPU | 8+ cores |
| RAM | 16+ GB |
| Disk | 250+ GB NVMe SSD |
| Network | 1–10 Gbps NIC |

> **Disk growth estimate:** RRD data grows approximately 1–5 MB per device per month, depending on number of interfaces/sensors. MySQL syslog data can grow rapidly if many devices send logs — consider enabling log rotation in the UI under **Settings → Syslog → Purge**.

### Software Requirements
| Software | Version |
|----------|---------|
| Ubuntu | 24.04 LTS (Noble Numbat) |
| Docker Engine | 24.0+ (latest recommended) |
| Docker Compose | v2.20+ (included with docker-compose-plugin) |

---

## File Inventory

All deployment files are in the `docker/` directory:

```
docker/
├── compose.yml          # Docker Compose service definitions (7 services)
├── .env.example         # Template for host-level settings (passwords, ports, timezone)
├── librenms.env         # LibreNMS application settings (SNMP, poller, mail, cron)
└── DEPLOY.md            # This deployment guide
```

### File Purposes

| File | What it controls | When to edit |
|------|-----------------|--------------|
| `.env.example` → `.env` | MySQL passwords, timezone, host port mappings | **Before first deploy** — copy to `.env`, set passwords |
| `librenms.env` | SNMP community, poller threads, memory limits, mail config, cron toggles | **Before first deploy** — set SNMP community; after deploy to tune |
| `compose.yml` | Container images, volumes, networks, health checks, dependencies | Rarely — only to add services or change resource limits |

---

## Complete Environment Variable Reference

### `.env` file (host-level / Docker Compose interpolation)

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `TZ` | `America/New_York` | Yes | IANA timezone for all containers. Must match your locale for correct graph times and alert schedules. Examples: `America/Chicago`, `America/Los_Angeles`, `Europe/London`, `UTC` |
| `MYSQL_ROOT_PASSWORD` | *(none)* | **Yes — change this** | Root password for MySQL. Used only for initial DB creation and admin tasks. Minimum 16 characters recommended. |
| `MYSQL_DATABASE` | `librenms` | No | Database name. No reason to change unless running multiple instances. |
| `MYSQL_USER` | `librenms` | No | Database user for the application. |
| `MYSQL_PASSWORD` | *(none)* | **Yes — change this** | Password for the `librenms` MySQL user. All LibreNMS containers use this. Minimum 16 characters recommended. |
| `LIBRENMS_HTTP_PORT` | `8000` | No | Host port for the web UI. Change to `80` if not using a reverse proxy, or any available port. |
| `SYSLOG_UDP_PORT` | `514` | No | Host UDP port for syslog reception. Use `1514` on non-root Docker setups. |
| `SYSLOG_TCP_PORT` | `514` | No | Host TCP port for syslog reception. Use `1514` on non-root Docker setups. |
| `SNMPTRAP_PORT` | `162` | No | Host port for SNMP trap reception. Use `1162` on non-root Docker setups. |

### `librenms.env` file (LibreNMS application settings)

| Variable | Default | Description |
|----------|---------|-------------|
| **Memory & Performance** | | |
| `MEMORY_LIMIT` | `256M` | PHP memory limit per process. Increase to `512M` for 500+ devices or complex dashboards. |
| `MAX_INPUT_VARS` | `1000` | PHP max input variables. Increase if you get form errors on large config pages. |
| `UPLOAD_MAX_SIZE` | `30M` | Max file upload size (MIB imports, firmware). |
| `OPCACHE_MEM_SIZE` | `128` | PHP OPcache memory in MB. Increase to `256` for large installs. |
| **SNMP** | | |
| `LIBRENMS_SNMP_COMMUNITY` | `public` | Default SNMPv2c community string for device discovery. **Change to match your network.** You can add per-device overrides in the web UI. |
| **Polling** | | |
| `LIBRENMS_POLLER_THREADS` | `16` | Number of concurrent poller worker threads. Guideline: 1 thread per ~30 devices. |
| `LIBRENMS_POLLER_INTERVAL` | `300` | Polling interval in seconds (300 = 5 minutes). Must complete all polls within this window. |
| **Cron Jobs** | | |
| `CRON_DISCOVERY_ENABLE` | `true` | Run device discovery every 6 hours (finds new devices by network scan). |
| `CRON_DAILY_ENABLE` | `true` | Run daily maintenance (DB cleanup, update checks, syslog/eventlog rotation). |
| `CRON_ALERTS_ENABLE` | `true` | Process alert rules every minute. |
| `CRON_BILLING_ENABLE` | `true` | Run billing data collection. |
| `CRON_BILLING_CALCULATE_ENABLE` | `true` | Calculate billing totals. |
| `CRON_CHECK_SERVICES_ENABLE` | `true` | Run Nagios-compatible service checks. |
| `CRON_POLLER_ENABLE` | `true` | **Keep enabled.** This is the main poller cron trigger. |
| **Weathermap** | | |
| `LIBRENMS_WEATHERMAP` | `false` | Enable the Network Weathermap plugin for visual topology maps. |
| **Logging** | | |
| `LOG_IP_VAR` | `remote_addr` | Which HTTP header contains the real client IP. Change to `http_x_forwarded_for` if behind a reverse proxy. |
| **Reverse Proxy** | | |
| `REAL_IP_FROM` | *(commented)* | CIDR of your trusted reverse proxy (e.g., `172.20.0.0/24` or `10.0.0.1/32`). Uncomment if using Nginx/HAProxy in front. |
| `REAL_IP_HEADER` | *(commented)* | HTTP header containing real IP. Typically `X-Forwarded-For` or `X-Real-IP`. |
| **SMTP / Email** | | |
| `LIBRENMS_MAILER_DRIVER` | *(commented)* | Mail transport: `smtp`, `sendmail`, `mailgun`, `ses`. |
| `LIBRENMS_MAILER_HOST` | *(commented)* | SMTP server hostname (e.g., `smtp.office365.com`, `smtp.gmail.com`). |
| `LIBRENMS_MAILER_PORT` | *(commented)* | SMTP port: `587` (STARTTLS), `465` (SSL), `25` (unencrypted). |
| `LIBRENMS_MAILER_USER` | *(commented)* | SMTP authentication username. |
| `LIBRENMS_MAILER_PASSWORD` | *(commented)* | SMTP authentication password. |
| `LIBRENMS_MAILER_ENCRYPTION` | *(commented)* | `tls` (STARTTLS on 587) or `ssl` (implicit on 465). |
| `LIBRENMS_MAILER_FROM_ADDRESS` | *(commented)* | "From" address on alert emails (e.g., `librenms@yourdomain.com`). |
| `LIBRENMS_MAILER_FROM_NAME` | *(commented)* | "From" display name (e.g., `LibreNMS Alerts`). |

### `compose.yml` internal environment variables (set automatically — do not edit)

These are set inside `compose.yml` and reference `.env` values. You should not need to change these:

| Variable | Set On | Value | Purpose |
|----------|--------|-------|---------|
| `DB_HOST` | All LibreNMS containers | `db` | MySQL container hostname (Docker internal DNS) |
| `DB_PORT` | All LibreNMS containers | `3306` | MySQL port |
| `DB_NAME` | All LibreNMS containers | From `MYSQL_DATABASE` | Database name |
| `DB_USER` | All LibreNMS containers | From `MYSQL_USER` | Database user |
| `DB_PASSWORD` | All LibreNMS containers | From `MYSQL_PASSWORD` | Database password |
| `DB_TIMEOUT` | All LibreNMS containers | `60` | Connection timeout in seconds |
| `CACHE_DRIVER` | All LibreNMS containers | `redis` | Use Redis for caching |
| `SESSION_DRIVER` | All LibreNMS containers | `redis` | Use Redis for sessions |
| `REDIS_HOST` | All LibreNMS containers | `redis` | Redis container hostname |
| `REDIS_PORT` | All LibreNMS containers | `6379` | Redis port |
| `REDIS_DB` | All LibreNMS containers | `0` | Redis database number |
| `RRDCACHED_SERVER` | librenms, dispatcher | `rrdcached:42217` | RRDcached daemon address |
| `DISPATCHER_NODE_ID` | dispatcher | `dispatcher1` | Unique node ID for distributed polling |
| `SIDECAR_DISPATCHER` | dispatcher | `1` | Enables dispatcher mode (no web server) |
| `SIDECAR_SYSLOGNG` | syslogng | `1` | Enables syslog-ng mode (no web server) |
| `SIDECAR_SNMPTRAPD` | snmptrapd | `1` | Enables SNMP trap mode (no web server) |

---

## Prerequisites — Install Docker Engine

### 1. Update the system

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot   # if kernel was updated
```

### 2. Install Docker Engine on Ubuntu 24.04

```bash
# Remove any old/conflicting packages
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt remove -y $pkg 2>/dev/null
done

# Install prerequisites
sudo apt update
sudo apt install -y ca-certificates curl gnupg

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine, CLI, Compose plugin, and Buildx
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable Docker to start on boot
sudo systemctl enable docker
sudo systemctl start docker

# Add your user to the docker group (you must log out and back in for this to take effect)
sudo usermod -aG docker $USER
```

### 3. Verify Docker installation

```bash
docker --version          # Expected: Docker version 27.x+
docker compose version    # Expected: Docker Compose version v2.x+
docker run hello-world    # Should print "Hello from Docker!"
```

---

## Deployment Steps

### Step 1: Transfer files to your Ubuntu server

From your Windows workstation, copy the `docker/` folder to the server:

```bash
# Using SCP (from PowerShell or Git Bash)
scp -r C:\Users\chrisr\Documents\GitHub\librenms\docker\ user@your-server:/opt/librenms/

# Or using rsync (if available)
rsync -avz docker/ user@your-server:/opt/librenms/
```

Alternatively, clone this repo on the server and use the `docker/` subfolder:

```bash
ssh user@your-server
git clone https://github.com/librenms/librenms.git /opt/librenms-src
cp -r /opt/librenms-src/docker /opt/librenms
cd /opt/librenms
```

### Step 2: Create and configure your .env file

```bash
cd /opt/librenms
cp .env.example .env
nano .env
```

**You MUST change these values before deploying:**

```dotenv
# Generate strong passwords (run this to generate random ones):
#   openssl rand -base64 24
TZ=America/New_York
MYSQL_ROOT_PASSWORD=YourStrongRootPassword123!
MYSQL_PASSWORD=YourStrongLibreNMSPassword456!
LIBRENMS_HTTP_PORT=8000
```

### Step 3: Configure LibreNMS application settings

```bash
nano librenms.env
```

**Critical settings to set now:**

```dotenv
# Set to your actual SNMP community string (NOT "public" in production!)
LIBRENMS_SNMP_COMMUNITY=YourSNMPCommunityString

# Adjust poller threads based on your device count
# Guideline: 1 thread per ~30 devices
# 50 devices  → 2 threads
# 200 devices → 8 threads
# 500 devices → 16 threads
# 1000 devices → 32 threads
LIBRENMS_POLLER_THREADS=16
```

### Step 4: Start the full stack

```bash
cd /opt/librenms
sudo docker compose up -d
```

Docker will pull all images on first run (approximately 1–2 GB total download).

### Step 5: Wait for health checks to pass

```bash
# Watch container status until all show "Up" and "healthy"
watch -n 5 docker compose ps
```

Expected output after ~60 seconds:

```
NAME                  STATUS                    PORTS
librenms              Up (healthy)              0.0.0.0:8000->8000/tcp
librenms_db           Up (healthy)              3306/tcp
librenms_dispatcher   Up                        
librenms_redis        Up (healthy)              6379/tcp
librenms_rrdcached    Up                        
librenms_snmptrapd    Up                        0.0.0.0:162->162/tcp, 0.0.0.0:162->162/udp
librenms_syslogng     Up                        0.0.0.0:514->514/tcp, 0.0.0.0:514->514/udp
```

### Step 6: Access the web UI and create your admin account

1. Open your browser: **http://YOUR-SERVER-IP:8000**
2. The LibreNMS web installer will appear on first access
3. Create your admin username and password
4. Complete the setup wizard

### Step 7: Validate the installation

After logging in, go to **Settings (gear icon) → Validate Config**. Fix any warnings shown.

---

## Post-Deployment Configuration

### Add your first network device

**Via Web UI:**
1. Navigate to **Devices → Add Device**
2. Fill in:
   - **Hostname/IP:** The device's management IP (e.g., `10.0.0.1`)
   - **SNMP Version:** `v2c` (or `v3` for encrypted)
   - **Community:** Your SNMP community string (should match what's on the device)
   - **Port:** `161` (default SNMP port)
3. Click **Add Device**
4. Wait 5–10 minutes for the first poll cycle to complete

**Via CLI (inside the container):**
```bash
docker compose exec librenms lnms device:add 10.0.0.1 \
  --v2c \
  --community YourCommunityString
```

### Configure auto-discovery by network range

Auto-discovery scans subnets and adds any SNMP-responding devices automatically.

**Via Web UI:**
1. Go to **Settings → Discovery → Networks**
2. Add your management subnets, one per line:
   ```
   10.0.0.0/24
   10.0.1.0/24
   192.168.1.0/24
   ```
3. Discovery runs every 6 hours by default (controlled by `CRON_DISCOVERY_ENABLE`)

**Via CLI:**
```bash
docker compose exec librenms lnms config:set nets.+ "10.0.0.0/24"
docker compose exec librenms lnms config:set nets.+ "192.168.1.0/24"
```

### Enable billing (bandwidth accounting)

Billing tracks data transfer per port/device for capacity planning or customer billing:

```bash
docker compose exec librenms lnms config:set enable_billing 1
```

### Enable service monitoring (Nagios-compatible)

This allows HTTP/HTTPS/DNS/ICMP service checks in addition to SNMP:

```bash
docker compose exec librenms lnms config:set show_services 1
```

---

## Network Device Configuration

### SNMP Configuration Examples

LibreNMS polls devices via SNMP. Configure your devices to respond to SNMP queries from the LibreNMS server IP.

#### Cisco IOS / IOS-XE
```
snmp-server community YourCommunityString RO
snmp-server location "Server Room A, Rack 12"
snmp-server contact "netops@yourdomain.com"
! Restrict SNMP to LibreNMS server only
access-list 99 permit host 10.0.0.100
snmp-server community YourCommunityString RO 99
```

#### Cisco NX-OS
```
snmp-server community YourCommunityString use-acl SNMP_ACL
ip access-list SNMP_ACL
  permit ip host 10.0.0.100/32 any
snmp-server location "Data Center, Row 3"
snmp-server contact netops@yourdomain.com
```

#### Cisco ASA / Firepower
```
snmp-server host inside 10.0.0.100 community YourCommunityString version 2c
snmp-server location "Server Room"
snmp-server contact "netops@yourdomain.com"
snmp-server community YourCommunityString
```

#### Juniper Junos
```
set snmp community YourCommunityString authorization read-only
set snmp community YourCommunityString clients 10.0.0.100/32
set snmp location "Server Room A"
set snmp contact "netops@yourdomain.com"
```

#### Arista EOS
```
snmp-server community YourCommunityString ro
snmp-server location "DC1 Rack 5"
snmp-server contact "netops@yourdomain.com"
```

#### Palo Alto PAN-OS
```
set deviceconfig system snmp-setting access-setting version v2c snmp-community-string YourCommunityString
```

#### Linux (net-snmp / snmpd)
Edit `/etc/snmp/snmpd.conf`:
```
# Allow LibreNMS server to poll
rocommunity YourCommunityString 10.0.0.100
syslocation "Server Room"
syscontact netops@yourdomain.com
```
Then restart: `sudo systemctl restart snmpd`

#### Windows (SNMP Service)
1. Open **Services** → Ensure **SNMP Service** is installed and running
2. Open **SNMP Service Properties → Security tab**
3. Add community string: `YourCommunityString` with **READ ONLY** rights
4. Under "Accept SNMP packets from these hosts," add: `10.0.0.100`

### Syslog Configuration Examples

Point your devices to send syslog to the LibreNMS server IP on UDP port 514.

#### Cisco IOS / IOS-XE
```
logging host 10.0.0.100 transport udp port 514
logging trap informational
logging source-interface Loopback0
logging origin-id hostname
```

#### Cisco NX-OS
```
logging server 10.0.0.100 5 use-vrf management
logging source-interface mgmt0
logging origin-id hostname
```

#### Cisco ASA / Firepower
```
logging enable
logging timestamp
logging host inside 10.0.0.100 udp/514
logging trap informational
```

#### Juniper Junos
```
set system syslog host 10.0.0.100 any info
set system syslog host 10.0.0.100 port 514
set system syslog host 10.0.0.100 source-address 10.0.1.1
```

#### Arista EOS
```
logging host 10.0.0.100 514 protocol udp
logging trap informational
logging source-interface Management1
```

#### Palo Alto PAN-OS
```
set shared log-settings syslog LibreNMS server 10.0.0.100
set shared log-settings syslog LibreNMS transport UDP
set shared log-settings syslog LibreNMS port 514
set shared log-settings syslog LibreNMS format BSD
set shared log-settings syslog LibreNMS facility LOG_USER
```

#### Linux (rsyslog)
Add to `/etc/rsyslog.d/99-librenms.conf`:
```
*.info @10.0.0.100:514    # UDP
# *.info @@10.0.0.100:514  # TCP (double @)
```
Then restart: `sudo systemctl restart rsyslog`

### SNMP Trap Configuration Examples

Point your devices to send SNMP traps to LibreNMS on UDP port 162.

#### Cisco IOS / IOS-XE
```
snmp-server enable traps
snmp-server host 10.0.0.100 version 2c YourCommunityString
```

#### Juniper Junos
```
set snmp trap-group LibreNMS targets 10.0.0.100
set snmp trap-group LibreNMS version v2
```

#### Arista EOS
```
snmp-server host 10.0.0.100 version 2c YourCommunityString
snmp-server enable traps
```

---

## Alerting & Notifications

### Built-in Alert Transports

LibreNMS supports many notification channels. Configure them under **Alerts → Alert Transports** in the web UI:

| Transport | Use Case | Setup Notes |
|-----------|----------|-------------|
| **Email (SMTP)** | Standard alert emails | Uncomment and configure the `LIBRENMS_MAILER_*` variables in `librenms.env` |
| **Slack** | Team chat notifications | Create a Slack incoming webhook URL, paste it in the transport config |
| **Microsoft Teams** | Team chat notifications | Create a Teams incoming webhook URL |
| **PagerDuty** | On-call escalation | Enter your PagerDuty integration key |
| **Discord** | Chat notifications | Create a Discord webhook URL |
| **Telegram** | Mobile notifications | Create a bot via @BotFather, get chat ID |
| **API (webhook)** | Custom integrations | POST JSON to any HTTP endpoint |
| **Syslog** | Forward alerts to SIEM | Send alert events as syslog messages |

### Example: Configure Email Alerts

1. Edit `librenms.env` and uncomment the mail section:
   ```dotenv
   LIBRENMS_MAILER_DRIVER=smtp
   LIBRENMS_MAILER_HOST=smtp.office365.com
   LIBRENMS_MAILER_PORT=587
   LIBRENMS_MAILER_USER=librenms@yourdomain.com
   LIBRENMS_MAILER_PASSWORD=YourMailPassword
   LIBRENMS_MAILER_ENCRYPTION=tls
   LIBRENMS_MAILER_FROM_ADDRESS=librenms@yourdomain.com
   LIBRENMS_MAILER_FROM_NAME=LibreNMS Alerts
   ```
2. Restart the stack: `docker compose restart`
3. In the web UI: **Alerts → Alert Transports → Create** → Type: Mail
4. Test with: **Alerts → Alert Transports → (click test icon)**

### Common Alert Rules (pre-built)

LibreNMS ships with default alert rules. Review and enable them under **Alerts → Alert Rules**:

| Rule | Triggers When |
|------|---------------|
| Device Down | Device fails ICMP/SNMP poll |
| Port Down | Interface goes operationally down |
| Port Utilization | Interface exceeds bandwidth threshold |
| BGP Session Down | BGP peer state changes |
| Sensor Alert | Temperature, fan, PSU thresholds exceeded |
| Disk Usage | Disk partition exceeds percentage threshold |
| Memory Usage | Device memory exceeds threshold |
| Processor Load | CPU utilization exceeds threshold |

---

## Reverse Proxy (Optional — Nginx with HTTPS)

If you want to serve LibreNMS on port 443 with SSL, install Nginx on the host.

### Install Nginx and Certbot

```bash
sudo apt install -y nginx certbot python3-certbot-nginx
```

### Create the Nginx site config

Create `/etc/nginx/sites-available/librenms`:

```nginx
server {
    listen 80;
    server_name nms.yourdomain.com;

    # Redirect HTTP to HTTPS (after certbot runs)
    # return 301 https://$server_name$request_uri;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeout settings for long-running API calls
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
    }
}
```

### Enable the site and get SSL certificate

```bash
sudo ln -s /etc/nginx/sites-available/librenms /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default   # Remove default site if not needed
sudo nginx -t                                   # Test config syntax
sudo systemctl reload nginx

# Get a free Let's Encrypt SSL certificate (must have DNS pointing to this server)
sudo certbot --nginx -d nms.yourdomain.com

# Certbot will auto-renew. Verify:
sudo certbot renew --dry-run
```

### Update LibreNMS to trust the proxy

Edit `librenms.env` and uncomment:

```dotenv
REAL_IP_FROM=127.0.0.1
REAL_IP_HEADER=X-Forwarded-For
LOG_IP_VAR=http_x_forwarded_for
```

Then restart: `docker compose restart librenms`

---

## Firewall Rules

### UFW (Ubuntu's default firewall)

```bash
# Allow SSH (don't lock yourself out!)
sudo ufw allow 22/tcp comment "SSH"

# LibreNMS Web UI
sudo ufw allow 8000/tcp comment "LibreNMS Web UI"
# Or if using reverse proxy:
# sudo ufw allow 80/tcp comment "HTTP"
# sudo ufw allow 443/tcp comment "HTTPS"

# Syslog from network devices
sudo ufw allow 514/udp comment "Syslog UDP"
sudo ufw allow 514/tcp comment "Syslog TCP"

# SNMP Traps from network devices
sudo ufw allow 162/udp comment "SNMP Traps"

# Enable the firewall
sudo ufw enable
sudo ufw status verbose
```

### iptables (if not using UFW)

```bash
# LibreNMS Web UI
sudo iptables -A INPUT -p tcp --dport 8000 -j ACCEPT
# Syslog
sudo iptables -A INPUT -p udp --dport 514 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 514 -j ACCEPT
# SNMP Traps
sudo iptables -A INPUT -p udp --dport 162 -j ACCEPT

# Save rules (Ubuntu)
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

---

## Backup & Restore

### Automated Daily Backup Script

Create `/opt/librenms/backup.sh`:

```bash
#!/bin/bash
# LibreNMS Docker Backup Script
# Recommended: run daily via cron
# crontab -e → 0 2 * * * /opt/librenms/backup.sh

BACKUP_DIR="/opt/librenms/backups"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting LibreNMS backup..."

# 1. Backup MySQL database
echo "  Backing up database..."
docker compose -f /opt/librenms/compose.yml exec -T db \
    mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" \
    --single-transaction --routines --triggers \
    librenms | gzip > "$BACKUP_DIR/db_${DATE}.sql.gz"

# 2. Backup LibreNMS config/data volume
echo "  Backing up LibreNMS data..."
docker run --rm \
    -v librenms_librenms_data:/data \
    -v "$BACKUP_DIR":/backup \
    alpine tar czf "/backup/librenms_data_${DATE}.tar.gz" -C /data .

# 3. Backup RRD data (can be large — optional)
echo "  Backing up RRD data..."
docker run --rm \
    -v librenms_rrd_data:/data \
    -v "$BACKUP_DIR":/backup \
    alpine tar czf "/backup/rrd_data_${DATE}.tar.gz" -C /data .

# 4. Backup environment files
echo "  Backing up config files..."
cp /opt/librenms/.env "$BACKUP_DIR/env_${DATE}.bak"
cp /opt/librenms/librenms.env "$BACKUP_DIR/librenms_env_${DATE}.bak"
cp /opt/librenms/compose.yml "$BACKUP_DIR/compose_${DATE}.bak"

# 5. Clean up old backups
echo "  Cleaning backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -type f -mtime +${RETENTION_DAYS} -delete

echo "[$(date)] Backup complete. Files in $BACKUP_DIR:"
ls -lh "$BACKUP_DIR"/*${DATE}*
```

```bash
chmod +x /opt/librenms/backup.sh

# Add to cron (runs at 2:00 AM daily)
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/librenms/backup.sh >> /var/log/librenms-backup.log 2>&1") | crontab -
```

### Manual Database Backup (quick)

```bash
cd /opt/librenms

# Backup
docker compose exec -T db mysqldump -u root -p"$(grep MYSQL_ROOT_PASSWORD .env | cut -d= -f2)" \
  --single-transaction librenms | gzip > librenms_db_$(date +%Y%m%d).sql.gz

# Check backup size
ls -lh librenms_db_*.sql.gz
```

### Restore from Backup

```bash
cd /opt/librenms

# 1. Stop all services except the database
docker compose stop librenms dispatcher syslogng snmptrapd

# 2. Restore the database
gunzip -c backups/db_20260303_020000.sql.gz | \
  docker compose exec -T db mysql -u root -p"$(grep MYSQL_ROOT_PASSWORD .env | cut -d= -f2)" librenms

# 3. Restore LibreNMS data volume (if needed)
docker compose stop librenms
docker run --rm \
    -v librenms_librenms_data:/data \
    -v /opt/librenms/backups:/backup \
    alpine sh -c "rm -rf /data/* && tar xzf /backup/librenms_data_20260303_020000.tar.gz -C /data"

# 4. Restore RRD data (if needed)
docker run --rm \
    -v librenms_rrd_data:/data \
    -v /opt/librenms/backups:/backup \
    alpine sh -c "rm -rf /data/* && tar xzf /backup/rrd_data_20260303_020000.tar.gz -C /data"

# 5. Restart everything
docker compose up -d
```

---

## Updating LibreNMS

### Standard Update Procedure

```bash
cd /opt/librenms

# 1. Backup first! (see Backup section above)
./backup.sh

# 2. Pull the latest images
docker compose pull

# 3. Recreate containers with new images (data is preserved in volumes)
docker compose up -d

# 4. Verify all containers are healthy
docker compose ps

# 5. Check for any database migrations needed
docker compose exec librenms lnms migrate --force

# 6. Validate the installation
docker compose exec librenms lnms validate
```

### Pin to a specific version (optional)

If you want to avoid unexpected updates, pin the image tag in `compose.yml`:

```yaml
# Instead of:
image: librenms/librenms:latest

# Use a specific version:
image: librenms/librenms:24.9.0
```

---

## Scaling & Performance Tuning

### Poller Thread Tuning

The dispatcher service runs poller workers. The number of threads determines how many devices can be polled concurrently.

| Devices | Recommended `LIBRENMS_POLLER_THREADS` | Notes |
|---------|--------------------------------------|-------|
| 1–50 | 2–4 | Minimal load |
| 50–200 | 4–8 | Light load |
| 200–500 | 8–16 | Default setting is fine |
| 500–1000 | 16–32 | Monitor CPU usage |
| 1000–2000 | 32–64 | May need more RAM (16 GB+) |
| 2000+ | 64+ | Consider multiple dispatcher nodes |

**To change:** Edit `LIBRENMS_POLLER_THREADS` in `librenms.env`, then:
```bash
docker compose restart dispatcher
```

### Multiple Dispatcher Nodes

For very large networks (1000+ devices), you can run multiple dispatcher workers:

```bash
# Scale to 3 dispatcher instances
docker compose up -d --scale dispatcher=3
```

Or add additional named dispatchers in `compose.yml` with unique `DISPATCHER_NODE_ID` values.

### RRDcached Tuning

The default `WRITE_TIMEOUT=1800` (30 minutes) is good for most setups. For very high-throughput environments:

| Setting | Default | Large Install |
|---------|---------|---------------|
| `WRITE_TIMEOUT` | `1800` | `3600` |
| `WRITE_JITTER` | `1800` | `1800` |
| `WRITE_THREADS` | `4` | `8` |
| `FLUSH_DEAD_DATA_INTERVAL` | `3600` | `7200` |

### MySQL Tuning

For large installations, you may want to add MySQL tuning parameters. Edit `compose.yml` and add to the `db` service command:

```yaml
command:
  - "mysqld"
  - "--innodb-file-per-table=1"
  - "--lower-case-table-names=0"
  - "--character-set-server=utf8mb4"
  - "--collation-server=utf8mb4_unicode_ci"
  - "--innodb-buffer-pool-size=1G"       # Set to ~70% of available RAM for DB
  - "--innodb-log-file-size=256M"
  - "--innodb-flush-method=O_DIRECT"
  - "--max-connections=200"
  - "--tmp-table-size=64M"
  - "--max-heap-table-size=64M"
```

### Memory Limit Tuning

If you see PHP out-of-memory errors in logs:
```dotenv
# In librenms.env:
MEMORY_LIMIT=512M      # or 1024M for very large installs
OPCACHE_MEM_SIZE=256   # Increase PHP opcode cache
```

---

## Security Hardening

### 1. Change default SNMP community string

**Never use `public` in production.** Update `LIBRENMS_SNMP_COMMUNITY` in `librenms.env` and all your network devices.

### 2. Generate strong passwords

```bash
# Generate random passwords for .env
openssl rand -base64 24   # For MYSQL_ROOT_PASSWORD
openssl rand -base64 24   # For MYSQL_PASSWORD
```

### 3. Restrict SNMP access on devices

Always use SNMP ACLs to limit which IPs can query your devices (only the LibreNMS server IP).

### 4. Use SNMPv3 instead of v2c (recommended)

SNMPv3 provides authentication and encryption. Configure per-device in the LibreNMS web UI under **Device → Edit → SNMP**.

### 5. Run behind a reverse proxy with HTTPS

Never expose port 8000 directly to the internet. Use the Nginx reverse proxy with Let's Encrypt SSL (see above).

### 6. Restrict Docker network exposure

The `compose.yml` already uses an isolated bridge network (`172.20.0.0/24`). Only explicitly published ports are accessible from the host.

### 7. Keep images updated

```bash
# Update images regularly
docker compose pull
docker compose up -d

# Remove old unused images
docker image prune -f
```

### 8. Disable unused sidecar services

If you don't need syslog or SNMP trap reception, comment out or remove the `syslogng` and `snmptrapd` services from `compose.yml` to reduce attack surface.

### 9. Set up log monitoring

```bash
# Monitor LibreNMS logs for authentication failures
docker compose logs -f librenms 2>&1 | grep -i "auth\|login\|denied"
```

---

## Useful Commands Reference

### Container Management

```bash
cd /opt/librenms

# Status of all containers
docker compose ps

# View real-time logs (all services)
docker compose logs -f

# View logs for specific service
docker compose logs -f librenms
docker compose logs -f dispatcher
docker compose logs -f db
docker compose logs -f syslogng
docker compose logs -f snmptrapd

# View last 100 lines of logs
docker compose logs --tail=100 librenms

# Restart a specific service
docker compose restart dispatcher

# Restart all services
docker compose restart

# Stop everything (preserves data)
docker compose down

# Stop and DELETE ALL DATA (destructive!)
docker compose down -v
```

### LibreNMS CLI Commands

```bash
# Open a shell inside the LibreNMS container
docker compose exec librenms bash

# Run any lnms command
docker compose exec librenms lnms --help

# Add a device
docker compose exec librenms lnms device:add 10.0.0.1 --v2c --community YourCommunity

# Remove a device
docker compose exec librenms lnms device:remove 10.0.0.1

# Poll a specific device immediately
docker compose exec librenms lnms device:poll 10.0.0.1

# Discover a specific device immediately
docker compose exec librenms php discovery.php -h 10.0.0.1

# List all devices  
docker compose exec librenms lnms device:list

# Validate installation
docker compose exec librenms lnms validate

# Run database migrations
docker compose exec librenms lnms migrate --force

# Clear cache
docker compose exec librenms lnms cache:clear

# Set a config value
docker compose exec librenms lnms config:set auth_mechanism mysql
docker compose exec librenms lnms config:set nets.+ "10.0.0.0/24"
```

### Database Operations

```bash
# Connect to MySQL shell
docker compose exec db mysql -u librenms -p librenms

# Quick database size check
docker compose exec db mysql -u root -p -e "
SELECT table_schema AS 'Database',
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
FROM information_schema.tables
WHERE table_schema = 'librenms'
GROUP BY table_schema;"

# Check syslog table size (can grow large)
docker compose exec db mysql -u root -p -e "
SELECT table_name,
  ROUND(data_length / 1024 / 1024, 2) AS 'Data (MB)',
  ROUND(index_length / 1024 / 1024, 2) AS 'Index (MB)',
  table_rows AS 'Rows'
FROM information_schema.tables
WHERE table_schema = 'librenms'
ORDER BY data_length DESC
LIMIT 10;"
```

### Docker Disk Usage

```bash
# Check Docker disk usage
docker system df

# Check volume sizes
docker system df -v | grep librenms

# Clean up unused Docker resources
docker system prune -f
docker image prune -f
```

---

## Docker Volume Locations

Docker volumes are stored by default in `/var/lib/docker/volumes/`. The volume names are prefixed with the Compose project name (directory name):

| Volume Name | Mount Point | Contents | Growth Rate |
|-------------|-------------|----------|-------------|
| `librenms_db_data` | `/var/lib/mysql` | MySQL database files | Moderate — grows with device count and syslog |
| `librenms_librenms_data` | `/data` | LibreNMS config, plugins, MIBs, logs | Small — mostly static |
| `librenms_rrd_data` | `/data/rrd` | Round-robin database files (graphs) | Steady — ~1-5 MB/device/month |
| `librenms_rrd_journal` | `/data/journal` | RRDcached write journal | Temporary — flushed periodically |

To check actual on-disk sizes:
```bash
sudo du -sh /var/lib/docker/volumes/librenms_*
```

---

## Troubleshooting

### Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Web UI won't load / connection refused | LibreNMS container not started or DB not ready | `docker compose ps` — wait for `db` to show `healthy`, then restart `librenms` |
| "Database connection refused" in logs | MySQL still initializing | Wait 60s for healthcheck; check `docker compose logs db` |
| Devices not being polled | Dispatcher not running or Redis down | `docker compose logs dispatcher` — ensure Redis is healthy |
| "Permission denied" on port 514/162 | Non-root user can't bind <1024 | Change ports to `1514`/`1162` in `.env`, or run Docker as root |
| Graphs show "No Data" | RRDcached not connected or device not polled yet | Check `docker compose logs rrdcached`; manually poll: `docker compose exec librenms lnms device:poll <host>` |
| Slow web UI | Memory too low or MySQL untuned | Increase `MEMORY_LIMIT` in `librenms.env`; add MySQL tuning params |
| Syslog messages not appearing | Firewall blocking UDP 514 or wrong syslog config | Check UFW: `sudo ufw status`; verify device syslog config points to correct IP |
| SNMP traps not received | Firewall blocking UDP 162 or wrong community | Check firewall; verify device trap config; `docker compose logs snmptrapd` |
| "Out of memory" errors | PHP memory limit too low | Set `MEMORY_LIMIT=512M` in `librenms.env`, restart |
| Container keeps restarting | Check logs for crash reason | `docker compose logs --tail=50 <service>` |
| Disk space running out | RRD or syslog data growth | Check `docker system df`; enable syslog purge in Settings; `docker system prune` |
| Alert emails not sending | SMTP config wrong | Verify `LIBRENMS_MAILER_*` vars in `librenms.env`; test with transport test button in UI |
| "Too many connections" in DB logs | MySQL max connections hit | Add `--max-connections=300` to db command in `compose.yml` |

### Debug Commands

```bash
# Check if containers can reach each other
docker compose exec librenms ping -c 3 db
docker compose exec librenms ping -c 3 redis
docker compose exec librenms ping -c 3 rrdcached

# Test MySQL connection from LibreNMS container
docker compose exec librenms php -r "new PDO('mysql:host=db;dbname=librenms', 'librenms', 'YOUR_PASSWORD');"

# Check Redis connectivity
docker compose exec redis redis-cli ping   # Should return PONG

# Check RRDcached connectivity
docker compose exec librenms rrdtool info /data/rrd/*/poller-perf.rrd

# Full validation
docker compose exec librenms lnms validate

# Check PHP configuration
docker compose exec librenms php -i | grep memory_limit
docker compose exec librenms php -i | grep timezone

# Check container resource usage
docker stats --no-stream
```
