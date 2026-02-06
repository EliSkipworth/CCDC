#!/bin/bash

# Check where the config should be
if [ -d "/etc/roundcubemail" ]; then
    CONFIG_DIR="/etc/roundcubemail"
    ROUNDCUBE_DIR="/usr/share/roundcubemail"
    echo "Using package installation paths"
else
    echo "Error: /etc/roundcubemail not found"
    exit 1
fi

# Get the database password that was saved
ROUNDCUBE_DB_PASS=$(cat /root/backup_*/roundcube_db_password.txt)

# Generate DES key
DES_KEY=$(openssl rand -base64 24 | tr -d '/+=')

# Create the configuration file
cat > $CONFIG_DIR/config.inc.php <<EOF
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

# Set proper permissions
chmod 640 $CONFIG_DIR/config.inc.php
chown root:apache $CONFIG_DIR/config.inc.php

# Initialize the database if not already done
mysql -u roundcube -p"$ROUNDCUBE_DB_PASS" roundcubemail -e "SELECT 1" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Initializing Roundcube database..."
    # Find the SQL init file
    if [ -f "/usr/share/doc/roundcubemail/SQL/mysql.initial.sql" ]; then
        mysql -u roundcube -p"$ROUNDCUBE_DB_PASS" roundcubemail < /usr/share/doc/roundcubemail/SQL/mysql.initial.sql
    elif [ -f "$ROUNDCUBE_DIR/SQL/mysql.initial.sql" ]; then
        mysql -u roundcube -p"$ROUNDCUBE_DB_PASS" roundcubemail < $ROUNDCUBE_DIR/SQL/mysql.initial.sql
    fi
fi

# Fix SELinux contexts
restorecon -Rv /usr/share/roundcubemail
restorecon -Rv /etc/roundcubemail

# Set SELinux contexts
semanage fcontext -a -t httpd_sys_content_t "/usr/share/roundcubemail(/.*)?" 2>/dev/null || true
semanage fcontext -a -t httpd_sys_rw_content_t "/usr/share/roundcubemail/temp(/.*)?" 2>/dev/null || true
semanage fcontext -a -t httpd_sys_rw_content_t "/usr/share/roundcubemail/logs(/.*)?" 2>/dev/null || true
restorecon -Rv /usr/share/roundcubemail

# Create temp and logs directories with proper permissions
mkdir -p /usr/share/roundcubemail/temp
mkdir -p /usr/share/roundcubemail/logs
chown -R apache:apache /usr/share/roundcubemail/temp
chown -R apache:apache /usr/share/roundcubemail/logs
chmod 755 /usr/share/roundcubemail/temp
chmod 755 /usr/share/roundcubemail/logs

# Restart Apache
systemctl restart httpd

echo "Roundcube configuration complete!"
echo "Access at: http://172.20.242.40/webmail"