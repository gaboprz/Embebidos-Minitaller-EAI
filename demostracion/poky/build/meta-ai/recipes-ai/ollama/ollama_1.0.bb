SUMMARY = "Ollama local AI model runner con qwen2.5:3b preinstalado"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ollama-linux-arm64.tgz;subdir=ollama-release \
    file://ollama.service \
    file://qwen2.5-3b-prebaked.tar.gz;unpack=0 \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "ollama.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Binario principal de Ollama
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

    # lib/ollama/ no se instala: solo contiene runners CUDA/ROCm
    # que no existen en el RPi5

    # Servicio systemd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/

    # Modelo qwen2.5:3b pre-baked
    # --no-same-owner: descarta el UID/GID original del tar para evitar errores de QA
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/qwen2.5-3b-prebaked.tar.gz \
        -C ${D}/root/.ollama/
}

FILES:${PN} += " \
    ${bindir}/ollama \
    ${systemd_system_unitdir}/ollama.service \
    /root/.ollama/ \
"

INSANE_SKIP:${PN} = "already-stripped"
