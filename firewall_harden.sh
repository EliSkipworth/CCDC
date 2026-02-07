#!/usr/bin/env bash
set -euo pipefail

########################################
# Firewalld Hardening Script
# Closes all ports except required services
# 
# ALLOWED SERVICES:
#   SMTP (25) - Postfix
#   POP3 (110) - Dovecot
#   HTTP (80) - Apache
#   HTTPS (443) - Apache
########################################

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo $0"
  exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] [+] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] [!] $*"; }

echo ""
echo "========================================="
echo "  Firewalld Hardening Script"
echo "========================================="
echo ""

########################################
# INSTALL AND ENABLE FIREWALLD
########################################
log "Checking firewalld status"

if ! systemctl is-active --quiet firewalld 2>/dev/null; then
  log "Installing and starting firewalld"
  dnf5 install -y firewalld 2>/dev/null || dnf install -y firewalld
  systemctl enable firewalld
  systemctl start firewalld
  sleep 2
else
  log "✓ Firewalld is already running"
fi

########################################
# BACKUP CURRENT CONFIGURATION
########################################
log "Backing up current firewall configuration"

BACKUP_DIR="/root/firewall_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Export current configuration
firewall-cmd --list-all > "$BACKUP_DIR/firewall_before.txt"
firewall-cmd --list-all-zones > "$BACKUP_DIR/firewall_zones_before.txt"

log "Backup saved to: $BACKUP_DIR"

########################################
# GET CURRENT ZONE
########################################
DEFAULT_ZONE=$(firewall-cmd --get-default-zone)
log "Current default zone: $DEFAULT_ZONE"

########################################
# REMOVE ALL EXISTING SERVICES
########################################
log "Removing all existing services and ports"

# Get list of currently enabled services
CURRENT_SERVICES=$(firewall-cmd --list-services)

# Remove each service
for service in $CURRENT_SERVICES; do
  firewall-cmd --zone=$DEFAULT_ZONE --remove-service=$service --permanent
  log "Removed service: $service"
done

# Get list of currently open ports
CURRENT_PORTS=$(firewall-cmd --list-ports)

# Remove each port
for port in $CURRENT_PORTS; do
  firewall-cmd --zone=$DEFAULT_ZONE --remove-port=$port --permanent
  log "Removed port: $port"
done

########################################
# ADD ONLY REQUIRED SERVICES
########################################
log "Adding required services for webmail server"

# SMTP (port 25)
firewall-cmd --zone=$DEFAULT_ZONE --add-service=smtp --permanent
log "✓ Allowed SMTP (25)"

# HTTP (port 80)
firewall-cmd --zone=$DEFAULT_ZONE --add-service=http --permanent
log "✓ Allowed HTTP (80)"

# HTTPS (port 443)
firewall-cmd --zone=$DEFAULT_ZONE --add-service=https --permanent
log "✓ Allowed HTTPS (443)"

# POP3 (port 110)
firewall-cmd --zone=$DEFAULT_ZONE --add-port=110/tcp --permanent
log "✓ Allowed POP3 (110)"

########################################
# OPTIONAL SERVICES (PROMPTED)
########################################
echo ""
echo "Optional services:"
echo ""

# SSH
read -p "Allow SSH (port 22)? (yes/no) [no]: " ALLOW_SSH
if [[ "$ALLOW_SSH" == "yes" ]]; then
  firewall-cmd --zone=$DEFAULT_ZONE --add-service=ssh --permanent
  log "✓ Allowed SSH (22)"
else
  log "✗ SSH blocked"
fi

# IMAP (if using webmail that needs it)
read -p "Allow IMAP (port 143)? (yes/no) [no]: " ALLOW_IMAP
if [[ "$ALLOW_IMAP" == "yes" ]]; then
  firewall-cmd --zone=$DEFAULT_ZONE --add-port=143/tcp --permanent
  log "✓ Allowed IMAP (143)"
else
  log "✗ IMAP blocked"
fi

# IMAPS (if using webmail that needs it)
read -p "Allow IMAPS (port 993)? (yes/no) [no]: " ALLOW_IMAPS
if [[ "$ALLOW_IMAPS" == "yes" ]]; then
  firewall-cmd --zone=$DEFAULT_ZONE --add-port=993/tcp --permanent
  log "✓ Allowed IMAPS (993)"
else
  log "✗ IMAPS blocked"
fi

# POP3S
read -p "Allow POP3S (port 995)? (yes/no) [no]: " ALLOW_POP3S
if [[ "$ALLOW_POP3S" == "yes" ]]; then
  firewall-cmd --zone=$DEFAULT_ZONE --add-port=995/tcp --permanent
  log "✓ Allowed POP3S (995)"
else
  log "✗ POP3S blocked"
fi

# SMTPS
read -p "Allow SMTPS (port 465)? (yes/no) [no]: " ALLOW_SMTPS
if [[ "$ALLOW_SMTPS" == "yes" ]]; then
  firewall-cmd --zone=$DEFAULT_ZONE --add-port=465/tcp --permanent
  log "✓ Allowed SMTPS (465)"
else
  log "✗ SMTPS blocked"
fi

# Submission (SMTP with auth on port 587)
read -p "Allow SMTP Submission (port 587)? (yes/no) [no]: " ALLOW_SUBMISSION
if [[ "$ALLOW_SUBMISSION" == "yes" ]]; then
  firewall-cmd --zone=$DEFAULT_ZONE --add-port=587/tcp --permanent
  log "✓ Allowed SMTP Submission (587)"
else
  log "✗ SMTP Submission blocked"
fi

########################################
# HARDEN FIREWALL SETTINGS
########################################
log "Applying firewall hardening settings"

# Drop invalid packets
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="0.0.0.0/0" drop'
firewall-cmd --permanent --remove-rich-rule='rule family="ipv4" source address="0.0.0.0/0" drop' 2>/dev/null || true

# Set default policies
firewall-cmd --zone=$DEFAULT_ZONE --set-target=DROP --permanent 2>/dev/null || true

# Enable logging for dropped packets (optional, can be verbose)
read -p "Enable logging for dropped packets? (yes/no) [no]: " ENABLE_LOGGING
if [[ "$ENABLE_LOGGING" == "yes" ]]; then
  firewall-cmd --set-log-denied=all --permanent
  log "✓ Dropped packet logging enabled"
else
  firewall-cmd --set-log-denied=off --permanent
  log "✗ Dropped packet logging disabled"
fi

########################################
# RELOAD FIREWALL
########################################
log "Reloading firewall configuration"
firewall-cmd --reload

########################################
# VERIFY CONFIGURATION
########################################
log "Verifying firewall configuration"
echo ""
echo "========================================="
echo "  Active Firewall Configuration"
echo "========================================="
echo ""
firewall-cmd --list-all
echo ""

# Save final configuration
firewall-cmd --list-all > "$BACKUP_DIR/firewall_after.txt"

########################################
# SHOW SUMMARY
########################################
echo ""
echo "========================================="
echo "  Firewall Hardening Summary"
echo "========================================="
echo ""
echo "ALLOWED PORTS:"
firewall-cmd --list-ports | tr ' ' '\n' | while read port; do
  [[ -n "$port" ]] && echo "  ✓ $port"
done

echo ""
echo "ALLOWED SERVICES:"
firewall-cmd --list-services | tr ' ' '\n' | while read service; do
  [[ -n "$service" ]] && echo "  ✓ $service"
done

echo ""
echo "BLOCKED: Everything else"
echo ""
log "Configuration saved to: $BACKUP_DIR"
echo ""

########################################
# WARNING
########################################
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  ⚠️  WARNING: Test connectivity immediately!               │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│  If you blocked SSH and lose access:                       │"
echo "│  1. Access via console/KVM                                  │"
echo "│  2. Run: firewall-cmd --add-service=ssh --permanent        │"
echo "│  3. Run: firewall-cmd --reload                             │"
echo "│                                                             │"
echo "│  To restore previous configuration:                        │"
echo "│  systemctl stop firewalld                                  │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
