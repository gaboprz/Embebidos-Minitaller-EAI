#!/bin/sh
# ================================================================
#  /etc/profile.d/99-show-ip.sh
#  Se ejecuta automáticamente en cada login interactivo.
#  Muestra las IPs asignadas a las interfaces de red.
# ================================================================

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│         Raspberry Pi 5 — Yocto          │"
echo "├─────────────────────────────────────────┤"

found=0

# Itera sobre los nombres de interfaz más comunes en RPi5.
# eth0 / end0 son los posibles nombres de Ethernet según el kernel.
for iface in eth0 eth1 end0 wlan0; do
    # Extrae la IP con awk: toma el campo $2 de la línea "inet"
    # y elimina el sufijo de subred (ej: 192.168.1.10/24 → 192.168.1.10)
    IP=$(ip -4 addr show "$iface" 2>/dev/null \
         | awk '/inet / { split($2, a, "/"); print a[1] }')

    if [ -n "$IP" ]; then
        printf "│  %-6s  →  ssh root@%-18s │\n" "$iface" "$IP"
        found=1
    fi
done

if [ "$found" -eq 0 ]; then
    echo "│  Sin IP asignada aún. Esperando DHCP... │"
fi

echo "└─────────────────────────────────────────┘"
echo ""
