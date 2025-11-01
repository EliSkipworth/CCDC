#!/bin/bash
# ===========================================
# Ubuntu Brute-Force Protection Script (Fail2Ban)
# ===========================================

echo "==> Installing and configuring Fail2Ban..."

# Install Fail2Ban if not installed
if ! command -v fail2ban-client &>/dev/null; then
    sudo apt update -y
    sudo apt install fail2ban -y
fi

# Create local jail config if it doesn't exist
if [ ! -f /etc/fail2ban/jail.local ]; then
    echo "==> Creating Fail2Ban local configuration..."
    sudo tee /etc/fail2ban/jail.local > /dev/null <<EOL
[DEFAULT]
bantime  = 1h
findtime  = 10m
maxretry = 5
destemail = root@localhost
sender = fail2ban@localhost
action = %(action_mwl)s

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = systemd
EOL
fi

# Enable and restart Fail2Ban
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

# Show Fail2Ban status
sudo fail2ban-client status
sudo fail2ban-client status sshd

echo "==> Fail2Ban brute-force protection enabled."
