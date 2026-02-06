#!/bin/bash

echo "Configuring Roundcube..."

# Check where the config should be
if [ -d "/etc/roundcubemail" ]; then
    CONFIG_DIR="/etc/roundcubemail"
    ROUNDCUBE_DIR="/usr/share/roundcubemail"
    echo "✓ Found package installation"
else
    echo "✗ Error: /etc/roundcubemail not found"
    exit 1
fi

# Get the database password that was saved
ROUNDCUBE_DB_PASS=$(cat /root/backup_*/roundcube_db_password.txt)
echo "✓ Retrieved database password"

# Generate DES key
DES_KEY=$(openssl rand -base64 24 | tr -d '/+=')
echo "✓ Generated DES key"

# Create the configuration file directly
echo "<?php" > $CONFIG_DIR/config.inc.php
echo "\$config['db_dsnw'] = 'mysql://roundcube:${ROUNDCUBE_DB_PASS}@localhost/roundcubemail';" >> $CONFIG_DIR/config.inc.php
echo "\$config['default_host'] = 'localhost';" >> $CONFIG_DIR/config.inc.php
echo "\$config['smtp_server'] = 'localhost';" >> $CONFIG_DIR/config.inc.php
echo "\$config['smtp_port'] = 25;" >> $CONFIG_DIR/config.inc.php
echo "\$config['des_key'] = '${DES_KEY}';" >> $CONFIG_DIR/config.inc.php
echo "\$config['product_name'] = 'Webmail';" >> $CONFIG_DIR/config.inc.php
echo "\$config['enable_installer'] = false;" >> $CONFIG_DIR/config.inc.php
echo "\$config['support_url'] = '';" >> $CONFIG_DIR/config.inc.php
echo "\$config['skin'] = 'elastic';" >> $CONFIG_DIR/config.inc.php
echo "\$config['plugins'] = array();" >> $CONFIG_DIR/config.inc.php

echo "✓ Created configuration file"

# Set proper permissions
chmod 640 $CONFIG_DIR/config.inc.php
chown root:apache $CONFIG_DIR/config.inc.php
echo "✓ Set permissions"

# Find and initialize database
echo "Looking for SQL initialization file..."
if [ -f "/usr/share/doc/roundcubemail/SQL/mysql.initial.sql" ]; then
    SQL_FILE="/usr/share/doc/roundcubemail/SQL/mysql.initial.sql"
    echo "✓ Found SQL file at: $SQL_FILE"
    mysql -u roundcube -p"$ROUNDCUBE_DB_PASS" roundcubemail < "$SQL_FILE"
    echo "✓ Database initialized"
elif [ -f "$ROUNDCUBE_DIR/SQL/mysql.initial.sql" ]; then
    SQL_FILE="$ROUNDCUBE_DIR/SQL/mysql.initial.sql"
    echo "✓ Found SQL file at: $SQL_FILE"
    mysql -u roundcube -p"$ROUNDCUBE_DB_PASS" roundcubemail < "$SQL_FILE"
    echo "✓ Database initialized"
else
    echo "! Warning: Could not find SQL initialization file"
    echo "  Checking common locations..."
    find /usr/share -name "mysql.initial.sql" 2>/dev/null
fi

# Create temp and logs directories
echo "Setting up directories..."
mkdir -p /usr/share/roundcubemail/temp
mkdir -p /usr/share/roundcubemail/logs
chown -R apache:apache /usr/share/roundcubemail/temp
chown -R apache:apache /usr/share/roundcubemail/logs
chmod 755 /usr/share/roundcubemail/temp
chmod 755 /usr/share/roundcubemail/logs
echo "✓ Directories created"

# Fix SELinux contexts
echo "Fixing SELinux..."
restorecon -Rv /usr/share/roundcubemail 2>/dev/null
restorecon -Rv /etc/roundcubemail 2>/dev/null
semanage fcontext -a -t httpd_sys_content_t "/usr/share/roundcubemail(/.*)?" 2>/dev/null || true
semanage fcontext -a -t httpd_sys_rw_content_t "/usr/share/roundcubemail/temp(/.*)?" 2>/dev/null || true
semanage fcontext -a -t httpd_sys_rw_content_t "/usr/share/roundcubemail/logs(/.*)?" 2>/dev/null || true
restorecon -Rv /usr/share/roundcubemail 2>/dev/null
echo "✓ SELinux configured"

# Restart Apache
echo "Restarting Apache..."
systemctl restart httpd
echo "✓ Apache restarted"

echo ""
echo "========================================="
echo "Roundcube configuration complete!"
echo "========================================="
echo ""
echo "Test with: curl -I http://localhost/webmail"
echo "Access at: http://172.20.242.40/webmail"
echo ""

echo "Roundcube configuration complete!"

echo "Access at: http://172.20.242.40/webmail"
