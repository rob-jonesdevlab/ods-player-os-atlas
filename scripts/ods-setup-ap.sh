#!/bin/bash
# ODS Setup AP — manages WiFi hotspot for phone-based network configuration
# Usage: ods-setup-ap.sh start|stop|status|ssid

ACTION="${1:-status}"
HOSTAPD_CONF="/etc/hostapd/hostapd-setup.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/ods-setup.conf"
AP_IP="192.168.4.1"
IFACE="wlan0"

case "$ACTION" in
    start)
        echo "[ODS-AP] Starting setup hotspot..."

        # Kill any existing wpa_supplicant on wlan0
        killall wpa_supplicant 2>/dev/null
        sleep 1

        # Bring interface down then up in AP mode
        ip link set "$IFACE" down 2>/dev/null
        sleep 0.5

        # Set static IP for AP
        ip addr flush dev "$IFACE" 2>/dev/null
        ip addr add "$AP_IP/24" dev "$IFACE"
        ip link set "$IFACE" up

        # Start hostapd
        hostapd -B "$HOSTAPD_CONF" -P /run/hostapd-setup.pid
        if [ $? -ne 0 ]; then
            echo "[ODS-AP] ERROR: hostapd failed to start"
            exit 1
        fi

        # Start dnsmasq for DHCP (kill any existing first)
        killall dnsmasq 2>/dev/null
        sleep 0.5
        dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file=/run/dnsmasq-setup.pid --no-resolv --no-poll
        if [ $? -ne 0 ]; then
            echo "[ODS-AP] WARNING: dnsmasq failed (may already be running)"
        fi

        # Get SSID from config
        SSID=$(grep "^ssid=" "$HOSTAPD_CONF" | cut -d= -f2)
        echo "[ODS-AP] Hotspot active: SSID=$SSID IP=$AP_IP"
        ;;

    stop)
        echo "[ODS-AP] Stopping setup hotspot..."

        # Kill hostapd and dnsmasq
        [ -f /run/hostapd-setup.pid ] && kill $(cat /run/hostapd-setup.pid) 2>/dev/null
        [ -f /run/dnsmasq-setup.pid ] && kill $(cat /run/dnsmasq-setup.pid) 2>/dev/null
        killall hostapd 2>/dev/null
        killall dnsmasq 2>/dev/null
        rm -f /run/hostapd-setup.pid /run/dnsmasq-setup.pid

        # Flush AP IP and bring down
        ip addr flush dev "$IFACE" 2>/dev/null
        ip link set "$IFACE" down 2>/dev/null
        sleep 0.5

        echo "[ODS-AP] Hotspot stopped"
        ;;

    status)
        if [ -f /run/hostapd-setup.pid ] && kill -0 $(cat /run/hostapd-setup.pid 2>/dev/null) 2>/dev/null; then
            SSID=$(grep "^ssid=" "$HOSTAPD_CONF" | cut -d= -f2)
            echo "active"
            echo "ssid=$SSID"
            echo "ip=$AP_IP"
        else
            echo "inactive"
        fi
        ;;

    ssid)
        SSID=$(grep "^ssid=" "$HOSTAPD_CONF" | cut -d= -f2)
        echo "$SSID"
        ;;

    *)
        echo "Usage: $0 {start|stop|status|ssid}"
        exit 1
        ;;
esac
