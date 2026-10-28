#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_USER="${SUDO_USER:-$USER}"
RUN_GROUP="$(id -gn "$RUN_USER")"
SSID="DE0CV-Chess"
PASSWORD="fpgachess"
HOTSPOT=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-hotspot) HOTSPOT=false ;;
        --ssid) shift; SSID="${1:?--ssid requires a value}" ;;
        --password) shift; PASSWORD="${1:?--password requires a value}" ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
if [[ "$RUN_USER" == root ]]; then
    echo 'Run as your normal Pi user: bash setup.sh (sudo is used where needed).' >&2
    exit 1
fi
if $HOTSPOT && (( ${#PASSWORD} < 8 || ${#PASSWORD} > 63 || ${#SSID} < 1 || ${#SSID} > 32 )); then
    echo 'SSID must be 1..32 characters and password 8..63 characters.' >&2; exit 2
fi

sudo systemctl stop de0cv-chess 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y python3-venv python3-spidev network-manager
sudo raspi-config nonint do_spi 0
sudo usermod -aG spi "$RUN_USER"
python3 "$ROOT/run.py" setup --system-site-packages

if $HOTSPOT; then
    sudo systemctl enable --now NetworkManager
    WIFI_DEVICE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1; exit}')"
    if [[ -z "$WIFI_DEVICE" ]]; then echo 'No Wi-Fi interface found. Use --no-hotspot for existing LAN access.' >&2; exit 1; fi
    if ! nmcli -g connection.id connection show de0cv-chess-hotspot >/dev/null 2>&1; then
        sudo nmcli connection add type wifi ifname "$WIFI_DEVICE" con-name de0cv-chess-hotspot ssid "$SSID"
    fi
    sudo nmcli connection modify de0cv-chess-hotspot \
        connection.interface-name "$WIFI_DEVICE" connection.autoconnect yes connection.autoconnect-priority 100 \
        802-11-wireless.ssid "$SSID" 802-11-wireless.mode ap 802-11-wireless.band bg \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD" \
        ipv4.method shared ipv4.addresses 10.42.0.1/24 ipv6.method disabled
    sudo nmcli radio wifi on
fi

# Generate the unit without shell/sed interpolation of paths or user names.
SERVICE_FILE="$(mktemp)"
trap 'rm -f -- "$SERVICE_FILE"' EXIT
python3 "$ROOT/run.py" service-unit "$RUN_USER" "$RUN_GROUP" "$SERVICE_FILE"
sudo install -m 0644 "$SERVICE_FILE" /etc/systemd/system/de0cv-chess.service
sudo systemctl daemon-reload
sudo systemctl enable de0cv-chess
sudo systemctl restart de0cv-chess
echo 'DE0-CV Chess service is installed. SPI changes may require a reboot.'
echo 'Logs: journalctl -u de0cv-chess -f'
if $HOTSPOT; then
    echo "Wi-Fi: $SSID   Password: $PASSWORD"
    echo 'Open http://10.42.0.1:8080'
    echo 'Starting the hotspot now; an existing Wi-Fi SSH session may disconnect.'
    sudo nmcli connection up de0cv-chess-hotspot
else
    echo 'Open http://<your-pi-address>:8080 on your existing network.'
fi
