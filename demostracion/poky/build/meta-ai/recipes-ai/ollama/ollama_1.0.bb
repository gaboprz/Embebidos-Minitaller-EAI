SUMMARY = "Ollama local AI model runner con qwen2.5:3b preinstalado"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = " \
    file://ollama-linux-arm64.tar.zst;subdir=ollama-release \
    file://ollama.service \
    file://qwen3-4b-prebaked.tar.gz;unpack=0 \
"
S = "${WORKDIR}"
inherit systemd
SYSTEMD_SERVICE:${PN} = "ollama.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/qwen3-4b-prebaked.tar.gz \
    -C ${D}/root/.ollama/
}
FILES:${PN} += " \
    ${bindir}/ollama \
    ${systemd_system_unitdir}/ollama.service \
    /root/.ollama/ \
"
INSANE_SKIP:${PN} = "already-stripped"
