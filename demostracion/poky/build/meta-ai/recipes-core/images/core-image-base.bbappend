# ================================================================
#  meta-ai/recipes-core/images/core-image-base.bbappend
# ================================================================

IMAGE_INSTALL:append = " autologin show-ip"

ROOTFS_POSTPROCESS_COMMAND:append = " configure_sshd;"

# ----------------------------------------------------------------
# configure_sshd
#
# Modifica /etc/ssh/sshd_config para permitir login de root
# sin contraseña por SSH. Tres directivas necesarias:
#
#   PermitRootLogin yes      : permite que root se conecte por SSH.
#                              Por defecto es "prohibit-password".
#
#   PermitEmptyPasswords yes : acepta autenticación con contraseña
#                              vacía. Por defecto está desactivado.
#
#   UsePAM no                : desactiva PAM como método de auth.
#                              Con PAM activo, pam_unix rechaza
#                              contraseñas vacías incluso si OpenSSH
#                              las permitiría.
#
# NOTA: enable_sshd_service fue eliminado.
# ssh-server-openssh IMAGE_FEATURE habilita sshd automáticamente
# via su propia integración systemd (sshd.socket). No se necesita
# crear el symlink manualmente.
# ----------------------------------------------------------------
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
