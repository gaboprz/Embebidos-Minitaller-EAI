IMAGE_INSTALL:append = " autologin show-ip email-agent"

ROOTFS_POSTPROCESS_COMMAND:append = " configure_sshd; enable_timesyncd;"

configure_sshd() {
    SSHD_CONFIG="${IMAGE_ROOTFS}/etc/ssh/sshd_config"

    if [ ! -f "${SSHD_CONFIG}" ]; then
        bbwarn "configure_sshd: ${SSHD_CONFIG} no encontrado, omitiendo."
        return 0
    fi

    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'          "${SSHD_CONFIG}"
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' "${SSHD_CONFIG}"
    sed -i 's/^#*UsePAM.*/UsePAM no/'                             "${SSHD_CONFIG}"

    grep -q "^PermitRootLogin"      "${SSHD_CONFIG}" || echo "PermitRootLogin yes"      >> "${SSHD_CONFIG}"
    grep -q "^PermitEmptyPasswords" "${SSHD_CONFIG}" || echo "PermitEmptyPasswords yes" >> "${SSHD_CONFIG}"
    grep -q "^UsePAM"               "${SSHD_CONFIG}" || echo "UsePAM no"                >> "${SSHD_CONFIG}"
}

enable_timesyncd() {
    # systemd-timesyncd viene dentro del paquete systemd pero no está habilitado
    # por defecto en imágenes mínimas. Este symlink es el equivalente a
    # correr "systemctl enable systemd-timesyncd" pero en tiempo de build.
    WANTS_DIR="${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants"
    UNIT="${IMAGE_ROOTFS}/usr/lib/systemd/system/systemd-timesyncd.service"

    if [ -f "${UNIT}" ]; then
        install -d "${WANTS_DIR}"
        ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
               "${WANTS_DIR}/systemd-timesyncd.service"
        bbdebug 1 "enable_timesyncd: servicio NTP habilitado."
    else
        bbwarn "enable_timesyncd: systemd-timesyncd.service no encontrado en el rootfs."
    fi
}
