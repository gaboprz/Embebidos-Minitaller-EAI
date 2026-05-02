SUMMARY = "Agente de email — asistente de ventas de tienda de electrónica"
DESCRIPTION = "Script Python que monitorea Gmail, consulta Ollama y responde \
               correos de clientes automáticamente usando el LLM local."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://agent.py \
    file://email-agent.service \
    file://store_info.md \
    file://config.env \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "email-agent.service"
# "enable" hace que el servicio arranque en cada boot automáticamente
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # ── 1. Script principal ────────────────────────────────────
    # Se instala en su propio directorio para no mezclar con otros binarios del sistema
    install -d ${D}/usr/bin/email-agent/
    install -m 0755 ${WORKDIR}/agent.py ${D}/usr/bin/email-agent/agent.py

    # ── 2. Servicio systemd ────────────────────────────────────
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/email-agent.service ${D}${systemd_system_unitdir}/

    # ── 3. Archivos de configuración ───────────────────────────
    # Se instalan en /etc/email-agent/ para que el usuario los edite
    # fácilmente desde SSH sin tocar el binario
    install -d ${D}${sysconfdir}/email-agent/
    install -m 0640 ${WORKDIR}/config.env   ${D}${sysconfdir}/email-agent/config.env
    install -m 0644 ${WORKDIR}/store_info.md ${D}${sysconfdir}/email-agent/store_info.md
}

FILES:${PN} = " \
    /usr/bin/email-agent/agent.py \
    ${systemd_system_unitdir}/email-agent.service \
    ${sysconfdir}/email-agent/config.env \
    ${sysconfdir}/email-agent/store_info.md \
"

# config.env y store_info.md son archivos de configuración del usuario.
# CONFFILES indica al gestor de paquetes que no los sobreescriba
# si el paquete se actualiza y el usuario ya los editó.
CONFFILES:${PN} = " \
    ${sysconfdir}/email-agent/config.env \
    ${sysconfdir}/email-agent/store_info.md \
"

# Dependencias en tiempo de ejecución:
# python3           — intérprete y stdlib (incluye imaplib, smtplib, email, json, logging)
# python3-requests  — para llamar a la API HTTP de Ollama (de meta-openembedded/meta-python)
RDEPENDS:${PN} = " \
    python3 \
    python3-requests \
    python3-email \
    python3-netclient \
    python3-logging \
    python3-json \
    python3-threading \
"
