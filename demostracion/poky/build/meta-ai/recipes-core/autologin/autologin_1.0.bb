# ================================================================
#  meta-ai/recipes-core/autologin/autologin_1.0.bb
#
#  Instala cuatro archivos:
#    - /etc/systemd/system/getty@tty1.service.d/autologin.conf
#    - /root/.xinitrc
#    - /root/.bash_profile
#    - /etc/X11/xorg.conf   ← NUEVO: config correcta para RPi5
# ================================================================

SUMMARY = "Autologin de root en tty1, arranque automático de X11 y xorg.conf para RPi5"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://autologin.conf \
    file://xinitrc \
    file://bash_profile \
    file://xorg.conf \
"

S = "${WORKDIR}"

do_install() {
    # --- Drop-in de systemd para getty@tty1 (autologin) ---
    install -d ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/
    install -m 0644 ${WORKDIR}/autologin.conf \
        ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf

    # --- Archivos de sesión de root ---
    install -d ${D}/root
    install -m 0755 ${WORKDIR}/xinitrc     ${D}/root/.xinitrc
    install -m 0644 ${WORKDIR}/bash_profile ${D}/root/.bash_profile

    # --- xorg.conf para RPi5 ---
    # Reemplaza cualquier xorg.conf previo instalado por xserver-xorg
    # que pueda estar configurado para framebuffer (incompatible con RPi5 DRM).
    install -d ${D}${sysconfdir}/X11
    install -m 0644 ${WORKDIR}/xorg.conf ${D}${sysconfdir}/X11/xorg.conf
}

FILES:${PN} = " \
    ${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf \
    ${sysconfdir}/X11/xorg.conf \
    /root/.xinitrc \
    /root/.bash_profile \
"

CONFFILES:${PN} = " \
    ${sysconfdir}/X11/xorg.conf \
    /root/.xinitrc \
    /root/.bash_profile \
"
