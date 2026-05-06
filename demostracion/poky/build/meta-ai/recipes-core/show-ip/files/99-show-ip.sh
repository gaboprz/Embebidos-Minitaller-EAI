#!/bin/sh
echo ""
echo "┌─────────────────────────────────────────┐"
echo "│         Raspberry Pi 5 — Yocto          │"
echo "├─────────────────────────────────────────┤"
found=0
for iface in eth0 eth1 end0 wlan0; do
    IP=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / { split($2, a, "/"); print a[1] }')
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
