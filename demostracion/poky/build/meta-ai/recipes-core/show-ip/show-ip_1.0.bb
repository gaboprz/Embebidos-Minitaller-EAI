# ================================================================
#  meta-custom/recipes-core/show-ip/show-ip_1.0.bb
#
#  Instala un script en /etc/profile.d/ que se ejecuta
#  automáticamente en CUALQUIER login interactivo (consola o SSH)
#  y muestra las IPs de las interfaces de red activas junto con
#  el comando SSH listo para copiar y pegar.
# ================================================================

SUMMARY = "Muestra la dirección IP al iniciar sesión"
DESCRIPTION = "Instala /etc/profile.d/99-show-ip.sh para mostrar \
               las IPs de red disponibles en cada login."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-show-ip.sh"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/profile.d/
    install -m 0755 ${WORKDIR}/99-show-ip.sh \
        ${D}${sysconfdir}/profile.d/99-show-ip.sh
}

FILES:${PN} = "${sysconfdir}/profile.d/99-show-ip.sh"

# iproute2 provee el comando "ip" que usa el script
RDEPENDS:${PN} = "iproute2"
