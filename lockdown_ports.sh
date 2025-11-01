#!/bin/bash
# -----------------------------------------------------------
# Ubuntu Firewall Lockdown Script
# Closes all ports except HTTP, HTTPS, SMTP, POP3, FTP, and DNS
# Compatible with Ubuntu 22.04 / 24.04 LTS
# -----------------------------------------------------------

# Exit on error
set -e

echo "Starting firewall lockdown..."

# Ensure UFW is installed
if ! command -v ufw >/dev/null 2>&1; then
    echo "Installing UFW..."
    sudo apt update && sudo apt install -y ufw
fi

echo "Resetting firewall to default settings..."
sudo ufw --force reset

echo "Setting default policy to deny all incoming traffic..."
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow essential services
echo "Allowing HTTP (80)..."
sudo ufw allow 80/tcp

echo "Allowing HTTPS (443)..."
sudo ufw allow 443/tcp

echo "Allowing SMTP (25)..."
sudo ufw allow 25/tcp

echo "Allowing POP3 (110)..."
sudo ufw allow 110/tcp

echo "Allowing FTP (21)..."
sudo ufw allow 21/tcp

echo "Allowing DNS (53)..."
sudo ufw allow 53/tcp
sudo ufw allow 53/udp

# Enable firewall
echo "Enabling UFW..."
sudo ufw --force enable

echo "Firewall configuration complete."
echo "Allowed ports:"
sudo ufw status numbered
