IMAGE_INSTALL:append = " autologin show-ip email-agent"

ROOTFS_POSTPROCESS_COMMAND:append = " configure_sshd; enable_timesyncd; configure_wifi;"

configure_sshd() {
    SSHD_CONFIG="${IMAGE_ROOTFS}/etc/ssh/sshd_config"
    if [ ! -f "${SSHD_CONFIG}" ]; then
        bbwarn "sshd_config no encontrado, omitiendo."; return 0
    fi
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'          "${SSHD_CONFIG}"
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' "${SSHD_CONFIG}"
    sed -i 's/^#*UsePAM.*/UsePAM no/'                             "${SSHD_CONFIG}"
    grep -q "^PermitRootLogin"      "${SSHD_CONFIG}" || echo "PermitRootLogin yes"      >> "${SSHD_CONFIG}"
    grep -q "^PermitEmptyPasswords" "${SSHD_CONFIG}" || echo "PermitEmptyPasswords yes" >> "${SSHD_CONFIG}"
    grep -q "^UsePAM"               "${SSHD_CONFIG}" || echo "UsePAM no"                >> "${SSHD_CONFIG}"
}

enable_timesyncd() {
    WANTS_DIR="${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants"
    UNIT="${IMAGE_ROOTFS}/usr/lib/systemd/system/systemd-timesyncd.service"
    if [ -f "${UNIT}" ]; then
        install -d "${WANTS_DIR}"
        ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
               "${WANTS_DIR}/systemd-timesyncd.service"
    else
        bbwarn "systemd-timesyncd.service no encontrado."
    fi
}

configure_wifi() {
    WPA_DIR="${IMAGE_ROOTFS}/etc/wpa_supplicant"
    install -d "${WPA_DIR}"

    WPA_CONF="${WPA_DIR}/wpa_supplicant-wlan0.conf"
    printf 'ctrl_interface=/var/run/wpa_supplicant\n'  >  "${WPA_CONF}"
    printf 'ctrl_interface_group=0\n'                  >> "${WPA_CONF}"
    printf 'update_config=1\n'                         >> "${WPA_CONF}"
    printf '\n'                                        >> "${WPA_CONF}"
    printf 'network={\n'                               >> "${WPA_CONF}"
    printf '    ssid="Iphone de Gabriel"\n'            >> "${WPA_CONF}"
    printf '    psk="unodostres456"\n'                 >> "${WPA_CONF}"
    printf '    key_mgmt=WPA-PSK\n'                   >> "${WPA_CONF}"
    printf '    priority=1\n'                          >> "${WPA_CONF}"
    printf '}\n'                                       >> "${WPA_CONF}"

    chmod 0600 "${WPA_CONF}"

    WANTS_DIR="${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants"
    UNIT="${IMAGE_ROOTFS}/usr/lib/systemd/system/wpa_supplicant@.service"
    if [ -f "${UNIT}" ]; then
        install -d "${WANTS_DIR}"
        ln -sf /usr/lib/systemd/system/wpa_supplicant@.service \
               "${WANTS_DIR}/wpa_supplicant@wlan0.service"
        bbdebug 1 "configure_wifi: wpa_supplicant@wlan0 habilitado."
    else
        bbwarn "configure_wifi: wpa_supplicant@.service no encontrado en el rootfs."
    fi
}
