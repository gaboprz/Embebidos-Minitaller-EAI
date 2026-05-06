SUMMARY = "Muestra la dirección IP al iniciar sesión"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://99-show-ip.sh"
S = "${WORKDIR}"
do_install() {
    install -d ${D}${sysconfdir}/profile.d/
    install -m 0755 ${WORKDIR}/99-show-ip.sh ${D}${sysconfdir}/profile.d/99-show-ip.sh
}
FILES:${PN} = "${sysconfdir}/profile.d/99-show-ip.sh"
RDEPENDS:${PN} = "iproute2"
