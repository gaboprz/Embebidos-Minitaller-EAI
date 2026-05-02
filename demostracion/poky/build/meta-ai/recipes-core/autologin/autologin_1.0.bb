SUMMARY = "Autologin de root en tty1 sin contraseña"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Solo se necesita el drop-in de getty; los archivos de sesión X11 ya no aplican
SRC_URI = "file://autologin.conf"

S = "${WORKDIR}"

do_install() {
    # Crea el directorio del drop-in de systemd para el servicio getty@tty1
    install -d ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/
    install -m 0644 ${WORKDIR}/autologin.conf \
        ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf
}

FILES:${PN} = " \
    ${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf \
"
