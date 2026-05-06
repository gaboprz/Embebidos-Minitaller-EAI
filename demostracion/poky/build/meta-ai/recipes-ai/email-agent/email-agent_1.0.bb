SUMMARY = "Agente de email — asistente de ventas"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://agent.py file://email-agent.service file://store_info.md file://config.env"
S = "${WORKDIR}"
inherit systemd
SYSTEMD_SERVICE:${PN} = "email-agent.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
do_install() {
    install -d ${D}/usr/bin/email-agent/
    install -m 0755 ${WORKDIR}/agent.py ${D}/usr/bin/email-agent/agent.py
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/email-agent.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}/email-agent/
    install -m 0640 ${WORKDIR}/config.env    ${D}${sysconfdir}/email-agent/config.env
    install -m 0644 ${WORKDIR}/store_info.md ${D}${sysconfdir}/email-agent/store_info.md
}
FILES:${PN} = "/usr/bin/email-agent/agent.py ${systemd_system_unitdir}/email-agent.service ${sysconfdir}/email-agent/config.env ${sysconfdir}/email-agent/store_info.md"
CONFFILES:${PN} = "${sysconfdir}/email-agent/config.env ${sysconfdir}/email-agent/store_info.md"
RDEPENDS:${PN} = "python3 python3-requests python3-email python3-netclient python3-logging python3-json"
