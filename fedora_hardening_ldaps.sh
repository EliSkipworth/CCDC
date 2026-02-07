#!/usr/bin/env bash
set -euo pipefail

########################################
# Fedora Webmail Server Hardening Script
# Custom Version with Apache & Roundcube
# 
# Domain: ccdcteam.com
# Authentication: LDAPS (Active Directory)
# 
# SCORED SERVICES:
#   SMTP (25) - Postfix
#   POP3 (110) - Dovecot
#   HTTP/HTTPS (80/443) - Apache + Roundcube
########################################

if [[ ${EUID} -ne 0 ]]; then
  echo "[!] Run as root: sudo $0"
  exit 1
fi

LOG="/root/hardening_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%H:%M:%S')] [+] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] [!] $*"; }
err() { echo "[$(date '+%H:%M:%S')] [ERROR] $*"; }

########################################
# COLLECT AD INFORMATION
########################################
echo ""
echo "========================================="
echo "  ACTIVE DIRECTORY CONFIGURATION"
echo "========================================="
echo ""
echo "This script will configure LDAPS authentication to Active Directory."
echo ""

# Get AD server IP
read -p "Enter AD Server IP address [172.20.240.102]: " AD_SERVER_IP
AD_SERVER_IP=${AD_SERVER_IP:-172.20.240.102}

# Get AD domain
read -p "Enter AD Domain [ccdcteam.com]: " AD_DOMAIN
AD_DOMAIN=${AD_DOMAIN:-ccdcteam.com}

# Calculate base DN from domain
IFS='.' read -ra DOMAIN_PARTS <<< "$AD_DOMAIN"
BASE_DN=""
for part in "${DOMAIN_PARTS[@]}"; do
  if [[ -z "$BASE_DN" ]]; then
    BASE_DN="dc=$part"
  else
    BASE_DN="${BASE_DN},dc=$part"
  fi
done

echo ""
echo "Calculated Base DN: $BASE_DN"
echo ""

# Prompt to create LDAP service account
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  ACTION REQUIRED: Create LDAP Service Account in AD        │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│  On your Windows AD Server, create a service account:      │"
echo "│                                                             │"
echo "│  1. Open 'Active Directory Users and Computers'            │"
echo "│  2. Navigate to Users container                            │"
echo "│  3. Create new user:                                        │"
echo "│     - Name: ldapbind                                        │"
echo "│     - User logon name: ldapbind@${AD_DOMAIN}                │"
echo "│     - Set a strong password                                 │"
echo "│     - Check: 'Password never expires'                      │"
echo "│     - Check: 'User cannot change password'                 │"
echo "│  4. No special permissions needed (read-only is default)   │"
echo "│                                                             │"
echo "│  Alternative PowerShell command:                            │"
echo "│  New-ADUser -Name 'ldapbind' \\                             │"
echo "│    -UserPrincipalName 'ldapbind@${AD_DOMAIN}' \\            │"
echo "│    -AccountPassword (Read-Host -AsSecureString) \\          │"
echo "│    -Enabled \$true -PasswordNeverExpires \$true             │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
read -p "Press ENTER when you have created the ldapbind account in AD..."
echo ""

# Get LDAP bind credentials
read -p "Enter LDAP Bind DN [cn=ldapbind,cn=Users,$BASE_DN]: " LDAP_BIND_DN
LDAP_BIND_DN=${LDAP_BIND_DN:-cn=ldapbind,cn=Users,$BASE_DN}

read -sp "Enter password for LDAP bind account: " LDAP_BIND_PASS
echo ""
echo ""

# Confirm settings
echo "========================================="
echo "  Configuration Summary"
echo "========================================="
echo "AD Server:    $AD_SERVER_IP"
echo "AD Domain:    $AD_DOMAIN"
echo "Base DN:      $BASE_DN"
echo "Bind DN:      $LDAP_BIND_DN"
echo "========================================="
echo ""
read -p "Is this information correct? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Exiting. Please run the script again with correct information."
  exit 1
fi
echo ""

########################################
# BACKUP CRITICAL CONFIGS
########################################
log "Creating backup of original configs"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup mail services
for dir in /etc/postfix /etc/dovecot; do
  if [[ -d "$dir" ]]; then
    cp -a "$dir" "$BACKUP_DIR/" 2>/dev/null || true
  fi
done

# Backup authentication files
cp /etc/passwd "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/shadow "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/group "$BACKUP_DIR/" 2>/dev/null || true

# Backup SSSD if exists
cp -a /etc/sssd "$BACKUP_DIR/" 2>/dev/null || true

log "Backup created at: $BACKUP_DIR"

# Save AD configuration
cat > "$BACKUP_DIR/ad_config.txt" <<EOF
AD Server: $AD_SERVER_IP
AD Domain: $AD_DOMAIN
Base DN: $BASE_DN
Bind DN: $LDAP_BIND_DN
LDAP Bind Password: $LDAP_BIND_PASS
EOF
chmod 600 "$BACKUP_DIR/ad_config.txt"
log "AD configuration saved to: $BACKUP_DIR/ad_config.txt"

########################################
# PASSWORD MANAGEMENT (LOCAL ONLY)
########################################
log "Starting password management for LOCAL accounts only"

echo ""
echo "========================================="
echo "  PASSWORD MANAGEMENT"
echo "========================================="
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  ⚠️  ACTIVE DIRECTORY AUTHENTICATION WILL BE CONFIGURED    │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│  This server will use LDAPS for ${AD_DOMAIN} domain.         │"
echo "│                                                             │"
echo "│  DO NOT change mail user passwords on this Linux box!      │"
echo "│  They must be changed on Windows AD server instead.        │"
echo "│                                                             │"
echo "│  This script will ONLY change LOCAL accounts:              │"
echo "│    • root                                                   │"
echo "│    • sysadmin (if local)                                    │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
read -p "Press ENTER to continue with local account password changes..."
echo ""

# Root password
echo "Setting password for: root"
while true; do
  read -s -p "  Enter new password for root: " p1; echo ""
  read -s -p "  Confirm password: " p2; echo ""
  
  if [[ "$p1" != "$p2" ]]; then
    echo "  Passwords don't match. Try again."
    continue
  fi
  
  if [[ ${#p1} -lt 10 ]]; then
    echo "  Password too short (minimum 10 characters). Try again."
    continue
  fi
  
  echo "root:$p1" | chpasswd
  log "✓ root password changed"
  break
done

# Sysadmin password (if exists and is local)
if id "sysadmin" &>/dev/null; then
  if grep -q "^sysadmin:" /etc/passwd; then
    echo ""
    echo "Setting password for: sysadmin"
    while true; do
      read -s -p "  Enter new password for sysadmin: " p1; echo ""
      read -s -p "  Confirm password: " p2; echo ""
      
      if [[ "$p1" != "$p2" ]]; then
        echo "  Passwords don't match. Try again."
        continue
      fi
      
      if [[ ${#p1} -lt 10 ]]; then
        echo "  Password too short (minimum 10 characters). Try again."
        continue
      fi
      
      echo "sysadmin:$p1" | chpasswd
      log "✓ sysadmin password changed"
      break
    done
  fi
fi

# Clear password variables
unset p1 p2

echo ""
log "Local account passwords changed"
echo ""
warn "REMINDER: Change mail user passwords on Windows AD server!"
echo ""

########################################
# INSTALL LDAPS PREREQUISITES
########################################
log "Installing LDAPS and authentication packages"

dnf install -y sssd openldap-clients authselect oddjob-mkhomedir

########################################
# OBTAIN AD CA CERTIFICATE
########################################
log "Obtaining AD CA certificate"

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Fetching AD CA Certificate via LDAPS                      │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""

# Try to get certificate automatically
if openssl s_client -connect ${AD_SERVER_IP}:636 -showcerts </dev/null 2>/dev/null | openssl x509 -outform PEM > /etc/pki/tls/certs/ad-ca-cert.pem 2>/dev/null; then
  log "✓ AD CA certificate obtained automatically"
  chmod 644 /etc/pki/tls/certs/ad-ca-cert.pem
else
  warn "Could not automatically obtain CA certificate"
  echo ""
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│  ACTION REQUIRED: Export CA Certificate from AD            │"
  echo "├─────────────────────────────────────────────────────────────┤"
  echo "│  On your Windows AD Server:                                 │"
  echo "│                                                             │"
  echo "│  1. Open Command Prompt as Administrator                   │"
  echo "│  2. Run: certutil -ca.cert ad-ca-cert.cer                  │"
  echo "│  3. Copy ad-ca-cert.cer to this Linux server               │"
  echo "│  4. Convert: openssl x509 -inform DER -in ad-ca-cert.cer \\ │"
  echo "│              -out /etc/pki/tls/certs/ad-ca-cert.pem        │"
  echo "│                                                             │"
  echo "│  OR manually paste the certificate content below.          │"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo ""
  read -p "Press ENTER when certificate is at /etc/pki/tls/certs/ad-ca-cert.pem..."
  
  if [[ ! -f /etc/pki/tls/certs/ad-ca-cert.pem ]]; then
    err "Certificate not found. Cannot continue without CA certificate."
    exit 1
  fi
  chmod 644 /etc/pki/tls/certs/ad-ca-cert.pem
fi

########################################
# TEST LDAPS CONNECTION
########################################
log "Testing LDAPS connection to AD"

LDAPTLS_CACERT=/etc/pki/tls/certs/ad-ca-cert.pem \
ldapsearch -H ldaps://${AD_SERVER_IP}:636 \
  -D "${LDAP_BIND_DN}" \
  -w "${LDAP_BIND_PASS}" \
  -b "${BASE_DN}" \
  -s base "(objectclass=*)" >/dev/null 2>&1

if [[ $? -eq 0 ]]; then
  log "✓ LDAPS connection successful"
else
  err "✗ LDAPS connection failed"
  echo ""
  echo "Troubleshooting:"
  echo "  1. Verify AD server is reachable: ping $AD_SERVER_IP"
  echo "  2. Verify LDAPS port is open: nc -zv $AD_SERVER_IP 636"
  echo "  3. Verify credentials are correct"
  echo "  4. Check certificate: openssl s_client -connect ${AD_SERVER_IP}:636"
  echo ""
  read -p "Press ENTER to continue anyway (not recommended) or Ctrl+C to exit..."
fi

########################################
# CONFIGURE SSSD FOR LDAPS
########################################
log "Configuring SSSD for LDAPS authentication"

cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = ${AD_DOMAIN}
config_file_version = 2
services = nss, pam

[domain/${AD_DOMAIN}]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap

ldap_uri = ldaps://${AD_SERVER_IP}:636
ldap_search_base = ${BASE_DN}

ldap_default_bind_dn = ${LDAP_BIND_DN}
ldap_default_authtok_type = password
ldap_default_authtok = ${LDAP_BIND_PASS}

ldap_id_use_start_tls = False
ldap_tls_reqcert = demand
ldap_tls_cacert = /etc/pki/tls/certs/ad-ca-cert.pem

ldap_user_object_class = user
ldap_user_name = sAMAccountName
ldap_user_principal = userPrincipalName
ldap_group_object_class = group
ldap_group_name = cn

ldap_schema = ad
ldap_id_mapping = True

use_fully_qualified_names = False
fallback_homedir = /home/%u
default_shell = /bin/bash

cache_credentials = True
enumerate = False
EOF

chmod 600 /etc/sssd/sssd.conf
log "✓ SSSD configuration created"

# Enable authselect with home directory creation
authselect select sssd with-mkhomedir --force 2>/dev/null || true

# Enable and start SSSD
systemctl enable sssd
systemctl restart sssd

log "✓ SSSD started"

# Wait for SSSD to initialize
sleep 3

# Test user lookup
log "Testing AD user lookup..."
echo ""
read -p "Enter an AD username to test (e.g., jdoe): " TEST_USER
if id "$TEST_USER" &>/dev/null; then
  log "✓ AD user lookup successful"
  id "$TEST_USER"
else
  warn "Could not find user $TEST_USER in AD"
  echo "This may be normal if the user doesn't exist or SSSD needs more time to sync"
fi
echo ""
read -p "Press ENTER to continue..."
echo ""

########################################
# INSTALL APACHE AND DEPENDENCIES
########################################
log "Installing Apache (httpd) and dependencies"

dnf install -y httpd mod_ssl

log "Installing PHP for Roundcube"
dnf install -y php php-mysqlnd php-mbstring php-intl php-xml php-json php-ldap

# Backup Apache configs
if [[ -f /etc/httpd/conf/httpd.conf ]]; then
  cp /etc/httpd/conf/httpd.conf "$BACKUP_DIR/httpd.conf.original"
fi
if [[ -f /etc/httpd/conf.d/ssl.conf ]]; then
  cp /etc/httpd/conf.d/ssl.conf "$BACKUP_DIR/ssl.conf.original"
fi

########################################
# CONFIGURE APACHE SECURITY
########################################
log "Configuring Apache security settings"

HTTPD_CONF="/etc/httpd/conf/httpd.conf"

# Add security directives
cat >> "$HTTPD_CONF" <<'EOF'

# Security hardening
ServerTokens Prod
ServerSignature Off
TraceEnable Off
EOF

# Disable directory listing
sed -i 's/Options Indexes FollowSymLinks/Options FollowSymLinks/' "$HTTPD_CONF"

# Configure SSL/TLS
SSL_CONF="/etc/httpd/conf.d/ssl.conf"
if [[ -f "$SSL_CONF" ]]; then
  sed -i 's/^SSLProtocol.*/SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1/' "$SSL_CONF" 2>/dev/null || true
  log "SSL/TLS hardened"
fi

########################################
# INSTALL MARIADB DATABASE
########################################
log "Installing MariaDB database"

dnf install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb

log "MariaDB started"

########################################
# SECURE MARIADB
########################################
log "Securing MariaDB (automated)"

# Generate random root password
DB_ROOT_PASS=$(openssl rand -base64 16 | tr -d '/+=')

# Secure MariaDB automatically
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

log "✓ MariaDB secured"
log "MariaDB root password saved to: $BACKUP_DIR/db_root_password.txt"
echo "$DB_ROOT_PASS" > "$BACKUP_DIR/db_root_password.txt"
chmod 600 "$BACKUP_DIR/db_root_password.txt"

########################################
# CREATE ROUNDCUBE DATABASE
########################################
log "Creating Roundcube database"

# Generate Roundcube DB password
ROUNDCUBE_DB_PASS=$(openssl rand -base64 16 | tr -d '/+=')

mysql -u root -p"$DB_ROOT_PASS" <<EOF
CREATE DATABASE roundcubemail CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER 'roundcube'@'localhost' IDENTIFIED BY '$ROUNDCUBE_DB_PASS';
GRANT ALL PRIVILEGES ON roundcubemail.* TO 'roundcube'@'localhost';
FLUSH PRIVILEGES;
EOF

log "✓ Roundcube database created"
log "Roundcube DB password saved to: $BACKUP_DIR/roundcube_db_password.txt"
echo "$ROUNDCUBE_DB_PASS" > "$BACKUP_DIR/roundcube_db_password.txt"
chmod 600 "$BACKUP_DIR/roundcube_db_password.txt"

########################################
# INSTALL ROUNDCUBE
########################################
log "Installing Roundcube webmail"

# Try package installation first
if dnf list roundcubemail &>/dev/null; then
  dnf install -y roundcubemail
  ROUNDCUBE_DIR="/usr/share/roundcubemail"
  ROUNDCUBE_CONFIG_DIR="/etc/roundcubemail"
else
  # Manual installation
  log "Installing Roundcube manually"
  cd /var/www/html
  
  ROUNDCUBE_VERSION="1.6.5"
  wget -q "https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"
  tar -xzf "roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"
  mv "roundcubemail-${ROUNDCUBE_VERSION}" roundcube
  rm "roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"
  
  ROUNDCUBE_DIR="/var/www/html/roundcube"
  ROUNDCUBE_CONFIG_DIR="$ROUNDCUBE_DIR/config"
fi

log "Roundcube installed at: $ROUNDCUBE_DIR"

########################################
# CONFIGURE ROUNDCUBE
########################################
log "Configuring Roundcube"

# Generate DES key
DES_KEY=$(openssl rand -base64 24 | tr -d '/+=')

# Create configuration file
cat > "${ROUNDCUBE_CONFIG_DIR}/config.inc.php" <<EOF
<?php
\$config['db_dsnw'] = 'mysql://roundcube:${ROUNDCUBE_DB_PASS}@localhost/roundcubemail';
\$config['default_host'] = 'localhost';
\$config['smtp_server'] = 'localhost';
\$config['smtp_port'] = 25;
\$config['des_key'] = '${DES_KEY}';
\$config['product_name'] = 'Webmail';
\$config['enable_installer'] = false;
\$config['support_url'] = '';
\$config['skin'] = 'elastic';
\$config['plugins'] = array();
EOF

log "✓ Roundcube configured"

# Initialize database
if [[ -f "/usr/share/doc/roundcubemail/SQL/mysql.initial.sql" ]]; then
  mysql -u roundcube -p"$ROUNDCUBE_DB_PASS" roundcubemail < "/usr/share/doc/roundcubemail/SQL/mysql.initial.sql"
  log "✓ Roundcube database initialized"
elif [[ -f "$ROUNDCUBE_DIR/SQL/mysql.initial.sql" ]]; then
  mysql -u roundcube -p"$ROUNDCUBE_DB_PASS" roundcubemail < "$ROUNDCUBE_DIR/SQL/mysql.initial.sql"
  log "✓ Roundcube database initialized"
fi

# Set permissions
chown -R apache:apache "$ROUNDCUBE_DIR"
chmod 640 "${ROUNDCUBE_CONFIG_DIR}/config.inc.php"

########################################
# CREATE APACHE VIRTUAL HOST
########################################
log "Creating Apache configuration for Roundcube"

cat > /etc/httpd/conf.d/roundcube.conf <<EOF
Alias /webmail $ROUNDCUBE_DIR

<Directory $ROUNDCUBE_DIR/>
    Options +FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF

log "✓ Apache virtual host created"

########################################
# REMOVE ROUNDCUBE INSTALLER
########################################
if [[ -d "$ROUNDCUBE_DIR/installer" ]]; then
  mv "$ROUNDCUBE_DIR/installer" "$BACKUP_DIR/roundcube_installer" 2>/dev/null || true
  log "✓ Roundcube installer directory removed"
fi

# Create temp and logs directories
mkdir -p "$ROUNDCUBE_DIR/temp" "$ROUNDCUBE_DIR/logs"
chown -R apache:apache "$ROUNDCUBE_DIR/temp" "$ROUNDCUBE_DIR/logs"
chmod 755 "$ROUNDCUBE_DIR/temp" "$ROUNDCUBE_DIR/logs"

########################################
# ENABLE AND START APACHE
########################################
log "Starting Apache"

systemctl enable httpd
systemctl start httpd

if systemctl is-active --quiet httpd; then
  log "✓ Apache is running"
else
  err "Apache failed to start!"
  journalctl -u httpd --no-pager -n 20
fi

########################################
# REMOVE UNAUTHORIZED SSH KEYS
########################################
log "Removing unauthorized SSH keys"

for homedir in /root /home/*; do
  if [[ -d "$homedir/.ssh" ]]; then
    log "Backing up and clearing SSH keys in $homedir/.ssh"
    cp -a "$homedir/.ssh" "$BACKUP_DIR/$(basename $homedir)_ssh" 2>/dev/null || true
    rm -f "$homedir/.ssh/authorized_keys" 2>/dev/null || true
    rm -f "$homedir/.ssh/id_*" 2>/dev/null || true
  fi
done

########################################
# DISABLE SSH (NOT SCORED)
########################################
log "Disabling SSH service"
systemctl disable --now sshd.service 2>/dev/null || true

########################################
# DISABLE UNNECESSARY SERVICES
########################################
log "Disabling non-essential services"

DISABLE_SERVICES=(
  "avahi-daemon"
  "cups"
  "bluetooth"
  "rpcbind"
  "nfs-server"
  "vsftpd"
  "telnet"
)

for svc in "${DISABLE_SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    systemctl disable --now "${svc}.service" 2>/dev/null || true
    log "Disabled: $svc"
  fi
done

########################################
# ENABLE SCORED SERVICES
########################################
log "Starting/enabling scored services"

# Postfix (SMTP)
systemctl enable postfix
systemctl restart postfix
sleep 2
if systemctl is-active --quiet postfix; then
  log "✓ Postfix (SMTP) is running"
else
  err "✗ Postfix FAILED - check logs!"
  journalctl -u postfix --no-pager -n 20
fi

# Dovecot (POP3)
systemctl enable dovecot
systemctl restart dovecot
sleep 2
if systemctl is-active --quiet dovecot; then
  log "✓ Dovecot (POP3) is running"
else
  err "✗ Dovecot FAILED - check logs!"
  journalctl -u dovecot --no-pager -n 20
fi

########################################
# VERIFY SCORED PORTS ARE LISTENING
########################################
log "Verifying scored service ports"

declare -A PORTS=(
  ["25"]="SMTP (Postfix)"
  ["110"]="POP3 (Dovecot)"
  ["80"]="HTTP"
  ["443"]="HTTPS"
)

for port in "${!PORTS[@]}"; do
  if ss -tlnp | grep -q ":$port "; then
    log "✓ Port $port (${PORTS[$port]}) is listening"
  else
    err "✗ Port $port (${PORTS[$port]}) NOT listening!"
  fi
done

########################################
# POSTFIX HARDENING
########################################
log "Hardening Postfix (SMTP)"

POSTFIX_MAIN="/etc/postfix/main.cf"

if [[ -f "$POSTFIX_MAIN" ]]; then
  cp "$POSTFIX_MAIN" "$BACKUP_DIR/main.cf.current"
  
  # Security settings
  postconf -e "smtpd_banner = \$myhostname ESMTP"
  postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
  postconf -e "disable_vrfy_command = yes"
  postconf -e "smtpd_helo_required = yes"
  postconf -e "message_size_limit = 10240000"
  postconf -e "mailbox_size_limit = 51200000"
  postconf -e "smtpd_client_connection_count_limit = 10"
  postconf -e "smtpd_client_connection_rate_limit = 30"
  postconf -e "smtpd_timeout = 30s"
  postconf -e "smtpd_hard_error_limit = 5"
  
  log "Postfix hardening applied"
  systemctl restart postfix
else
  err "Postfix main.cf not found!"
fi

########################################
# DOVECOT LDAP CONFIGURATION
########################################
log "Configuring Dovecot for LDAP authentication"

DOVECOT_CONF="/etc/dovecot/dovecot.conf"
DOVECOT_AUTH_CONF="/etc/dovecot/conf.d/10-auth.conf"

if [[ -f "$DOVECOT_CONF" ]]; then
  cp "$DOVECOT_CONF" "$BACKUP_DIR/dovecot.conf.current"
  
  # Enable protocols
  if grep -q "^protocols" "$DOVECOT_CONF"; then
    sed -i 's/^protocols.*/protocols = pop3 imap/' "$DOVECOT_CONF"
  else
    echo "protocols = pop3 imap" >> "$DOVECOT_CONF"
  fi
  
  # Enable logging
  DOVECOT_LOGGING="/etc/dovecot/conf.d/10-logging.conf"
  if [[ -f "$DOVECOT_LOGGING" ]]; then
    cp "$DOVECOT_LOGGING" "$BACKUP_DIR/10-logging.conf.current"
    
    cat >> "$DOVECOT_LOGGING" <<'EOF'

# Enhanced Logging
auth_verbose = yes
auth_verbose_passwords = sha1
mail_debug = no
verbose_ssl = no
log_timestamp = "%Y-%m-%d %H:%M:%S "
EOF
  fi
fi

# Configure authentication to use LDAP
if [[ -f "$DOVECOT_AUTH_CONF" ]]; then
  cp "$DOVECOT_AUTH_CONF" "$BACKUP_DIR/10-auth.conf.current"
  
  # Disable system auth, enable LDAP
  sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' "$DOVECOT_AUTH_CONF"
  sed -i 's/^#!include auth-ldap.conf.ext/!include auth-ldap.conf.ext/' "$DOVECOT_AUTH_CONF"
  
  # If LDAP line doesn't exist, add it
  if ! grep -q "!include auth-ldap.conf.ext" "$DOVECOT_AUTH_CONF"; then
    echo "!include auth-ldap.conf.ext" >> "$DOVECOT_AUTH_CONF"
  fi
fi

# Create LDAP auth configuration
cat > /etc/dovecot/dovecot-ldap.conf.ext <<EOF
# LDAPS connection to Active Directory
hosts = ${AD_SERVER_IP}:636
tls = yes
tls_ca_cert_file = /etc/pki/tls/certs/ad-ca-cert.pem
tls_require_cert = demand

# Bind credentials
dn = ${LDAP_BIND_DN}
dnpass = ${LDAP_BIND_PASS}

# Search base
base = ${BASE_DN}

# Authentication - use bind authentication
auth_bind = yes
auth_bind_userdn = %u@${AD_DOMAIN}

# User attributes
pass_attrs = sAMAccountName=user
user_attrs = =home=/home/%u,=uid=5000,=gid=5000

# Search scope
scope = subtree

# Filters
pass_filter = (&(objectClass=person)(sAMAccountName=%u))
user_filter = (&(objectClass=person)(sAMAccountName=%u))
EOF

chmod 600 /etc/dovecot/dovecot-ldap.conf.ext

log "✓ Dovecot LDAP configuration created"
systemctl restart dovecot

if systemctl is-active --quiet dovecot; then
  log "✓ Dovecot restarted successfully"
else
  err "Dovecot failed to restart!"
  journalctl -u dovecot --no-pager -n 20
fi

########################################
# PHP HARDENING
########################################
log "Hardening PHP"

PHP_INI=$(php -i 2>/dev/null | grep "Loaded Configuration File" | awk '{print $NF}')
if [[ -f "$PHP_INI" ]]; then
  cp "$PHP_INI" "$BACKUP_DIR/php.ini.original"
  
  # Disable dangerous functions
  sed -i 's/^disable_functions.*/disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source/' "$PHP_INI" 2>/dev/null || true
  
  # Hide PHP version
  sed -i 's/^expose_php.*/expose_php = Off/' "$PHP_INI" 2>/dev/null || true
  
  # Disable remote file inclusion
  sed -i 's/^allow_url_fopen.*/allow_url_fopen = Off/' "$PHP_INI" 2>/dev/null || true
  sed -i 's/^allow_url_include.*/allow_url_include = Off/' "$PHP_INI" 2>/dev/null || true
  
  log "PHP hardening applied"
  systemctl restart httpd
else
  warn "PHP config not found - skipping PHP hardening"
fi

########################################
# SYSCTL KERNEL HARDENING
########################################
log "Applying kernel hardening"

cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# Disable IP forwarding
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# SYN Flood Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Don't send ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1

# Ignore broadcast pings
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF

sysctl -p /etc/sysctl.d/99-hardening.conf

########################################
# SELINUX CONFIGURATION
########################################
log "Configuring SELinux"

if command -v getenforce &>/dev/null; then
  SELINUX_STATUS=$(getenforce)
  log "SELinux is: $SELINUX_STATUS"
  
  if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
    # Set booleans for httpd
    setsebool -P httpd_can_sendmail on 2>/dev/null || true
    setsebool -P httpd_can_network_connect on 2>/dev/null || true
    setsebool -P httpd_can_network_connect_db on 2>/dev/null || true
    log "SELinux booleans configured for httpd"
    
    # Restore contexts
    restorecon -Rv "$ROUNDCUBE_DIR" 2>/dev/null || true
    restorecon -Rv /etc/roundcubemail 2>/dev/null || true
    
    # Set contexts for LDAP access
    semanage fcontext -a -t httpd_sys_content_t "${ROUNDCUBE_DIR}(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t httpd_sys_rw_content_t "${ROUNDCUBE_DIR}/temp(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t httpd_sys_rw_content_t "${ROUNDCUBE_DIR}/logs(/.*)?" 2>/dev/null || true
    restorecon -Rv "$ROUNDCUBE_DIR" 2>/dev/null || true
  fi
fi

########################################
# FILE PERMISSIONS
########################################
log "Hardening file permissions"

chmod 0700 /root
chmod 0600 /etc/shadow
chmod 0600 /etc/gshadow
chmod 0644 /etc/passwd
chmod 0644 /etc/group

# Secure mail directories
chmod 0750 /etc/postfix 2>/dev/null || true
chmod 0750 /etc/dovecot 2>/dev/null || true

# Secure SSSD
chmod 0600 /etc/sssd/sssd.conf 2>/dev/null || true

# Secure Dovecot LDAP config
chmod 0600 /etc/dovecot/dovecot-ldap.conf.ext 2>/dev/null || true

# Secure home directories
find /home -mindepth 1 -maxdepth 1 -type d -exec chmod 0700 {} \; 2>/dev/null || true

########################################
# SECURITY SCANNING
########################################
log "Scanning for suspicious files"

# Check for webshells
WEBSHELL_PATTERNS=(
  "c99.php" "r57.php" "shell.php" "cmd.php" "backdoor.php"
  "webshell.php" "eval.php" "base64.php" "upload.php"
)

SUSPICIOUS_FILES=()

for pattern in "${WEBSHELL_PATTERNS[@]}"; do
  while IFS= read -r -d '' file; do
    SUSPICIOUS_FILES+=("$file")
  done < <(find /var/www -name "*$pattern*" -print0 2>/dev/null)
done

# Look for suspicious PHP code
while IFS= read -r -d '' file; do
  if grep -l -E "(eval\s*\(\s*base64_decode|eval\s*\(\s*\\\$_(GET|POST|REQUEST)|passthru|shell_exec\s*\()" "$file" &>/dev/null; then
    SUSPICIOUS_FILES+=("$file")
  fi
done < <(find /var/www -name "*.php" -print0 2>/dev/null)

if [[ ${#SUSPICIOUS_FILES[@]} -gt 0 ]]; then
  warn "SUSPICIOUS FILES FOUND:"
  printf '%s\n' "${SUSPICIOUS_FILES[@]}" | tee -a "$BACKUP_DIR/suspicious_files.txt"
  warn "Review these files manually!"
fi

# Check cron jobs
log "Checking cron jobs"
for user in $(cut -f1 -d: /etc/passwd); do
  crontab -l -u "$user" 2>/dev/null && echo "--- Above cron for: $user ---"
done > "$BACKUP_DIR/cron_jobs.txt"

if grep -r -E "(wget|curl|nc |netcat|bash -i|/dev/tcp|python.*socket)" /etc/cron* /var/spool/cron 2>/dev/null; then
  warn "SUSPICIOUS CRON ENTRIES FOUND - review manually!"
fi

########################################
# FINAL SERVICE VERIFICATION
########################################
log "=== FINAL SERVICE STATUS ==="

echo ""
echo "SCORED SERVICES:"
for svc in postfix dovecot httpd mariadb; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "  ✓ $svc is RUNNING"
  else
    echo "  ✗ $svc is DOWN - INVESTIGATE!"
  fi
done

echo ""
echo "SSSD STATUS:"
if systemctl is-active --quiet sssd 2>/dev/null; then
  echo "  ✓ sssd is RUNNING"
else
  echo "  ✗ sssd is DOWN - INVESTIGATE!"
fi

echo ""
echo "LISTENING PORTS:"
ss -tlnp | grep -E ":(25|110|80|443|3306) "

########################################
# TEST AD AUTHENTICATION
########################################
echo ""
log "Testing AD authentication"
echo ""
read -p "Enter an AD username to test login (or press ENTER to skip): " TEST_AD_USER

if [[ -n "$TEST_AD_USER" ]]; then
  if id "$TEST_AD_USER" &>/dev/null; then
    log "✓ User $TEST_AD_USER found in LDAP"
    echo ""
    echo "User information:"
    id "$TEST_AD_USER"
  else
    warn "User $TEST_AD_USER not found. Check SSSD configuration."
  fi
fi

########################################
# COMPLETION
########################################
echo ""
log "========================================="
log "Fedora Webmail Hardening Complete"
log "========================================="
echo ""
log "CRITICAL FILES:"
log "  Backup:              $BACKUP_DIR"
log "  Log:                 $LOG"
log "  MariaDB root pass:   $BACKUP_DIR/db_root_password.txt"
log "  Roundcube DB pass:   $BACKUP_DIR/roundcube_db_password.txt"
log "  AD Config:           $BACKUP_DIR/ad_config.txt"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  ✓ Apache + Roundcube installed and configured             │"
echo "│  ✓ LDAPS authentication to ${AD_DOMAIN} configured           │"
echo "│  ✓ All passwords saved to backup directory                 │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
log "ACTIVE DIRECTORY CONFIGURATION:"
log "  AD Server:    $AD_SERVER_IP"
log "  AD Domain:    $AD_DOMAIN"
log "  Base DN:      $BASE_DN"
log "  Bind DN:      $LDAP_BIND_DN"
echo ""
warn "NEXT STEPS:"
echo "  1. TEST SMTP:    telnet localhost 25"
echo "  2. TEST POP3:    telnet localhost 110"
echo "  3. TEST Webmail: http://<server-ip>/webmail"
echo "  4. Login with AD credentials (username or username@${AD_DOMAIN})"
echo "  5. Change AD user passwords on Windows AD server!"
echo "  6. Monitor scoring dashboard"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  IMPORTANT: Remember to change AD user passwords!          │"
echo "│  Run PowerShell script on AD server (${AD_SERVER_IP})        │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
