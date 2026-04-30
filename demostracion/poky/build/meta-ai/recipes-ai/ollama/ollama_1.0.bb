# ================================================================
#  meta-ai/recipes-ai/ollama/ollama_1.0.bb
#
#  Usa file:// para el tgz porque ya está descargado localmente.
#  Esto evita que bitbake intente descargarlo de internet y elimina
#  la necesidad de calcular el SHA256 del tgz.
#
#  Estructura del ollama-linux-arm64.tgz:
#    bin/
#      ollama                    ← binario principal
#    lib/
#      ollama/
#        runners/
#          cpu/
#            ollama_llama_server ← runner que ejecuta el modelo
#
#  El runner es crítico. Sin él, ollama serve arranca pero cualquier
#  modelo falla con "llama runner process no longer running: -1".
# ================================================================

SUMMARY = "Ollama local AI model runner"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ollama-linux-arm64.tgz;subdir=ollama-release \
    file://ollama.service \
    file://gemma2-2b-prebaked.tar.gz;unpack=0 \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "ollama.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # 1. Binario principal (contiene la inferencia CPU integrada)
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

    # lib/ollama/ NO se instala: contiene solo librerías y runners CUDA
    # (libcudart, libcublas, cuda_v11, cuda_v12). El RPi5 no tiene
    # GPU NVIDIA, instalarlos causaría el error de QA por libcuda.so.

    # 2. Servicio systemd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/

    # 3. Modelo pre-baked
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/gemma2-2b-prebaked.tar.gz \
        -C ${D}/root/.ollama/
}

FILES:${PN} += " \
    ${bindir}/ollama \
    ${systemd_system_unitdir}/ollama.service \
    /root/.ollama/ \
"

INSANE_SKIP:${PN} = "already-stripped"
