SUMMARY = "Ollama local LLM runner con TinyLlama preinstalado"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ollama-linux-amd64.tgz;subdir=ollama-release \
    file://ollama.service \
    file://gemma2-2b-prebaked.tar.gz;unpack=0 \
"
# subdir=ollama-release: extrae el tgz en su propia carpeta para no mezclar archivos
# unpack=0 en el modelo: BitBake descomprime automáticamente los .tar.gz,
# pero aquí necesitamos controlarlo para elegir el destino correcto

S = "${WORKDIR}"

# patchelf-native permite reescribir el PT_INTERP del ELF del binario de Ollama
# durante el build, antes de que entre a la imagen
DEPENDS += "patchelf-native"

# "inherit systemd" activa el soporte para instalar y habilitar servicios systemd
inherit systemd

# Nombre del archivo .service que systemd debe manejar
SYSTEMD_SERVICE:${PN} = "ollama.service"

# "enable" hace que el servicio arranque en cada boot sin necesidad de correr systemctl enable
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Instala el binario de Ollama en /usr/bin/
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

    # El binario precompilado de Ollama viene de Ubuntu y tiene hardcodeado
    # /lib64/ld-linux-x86-64.so.2 como intérprete ELF (PT_INTERP).
    # Yocto con usrmerge coloca el loader en /usr/lib/ld-linux-x86-64.so.2
    # y no crea /lib64/, por lo que el kernel no puede arrancar el binario.
    # patchelf reescribe el PT_INTERP para que apunte a la ruta correcta de Yocto.
    patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 \
        ${D}${bindir}/ollama

    # Symlink /lib64 → /usr/lib como red de seguridad para cualquier otra
    # librería dinámica que el binario busque bajo /lib64/ en tiempo de ejecución
    ln -sf /usr/lib ${D}/lib64

    # lib/ollama/ no se instala: contiene solo runners CUDA/ROCm
    # que requieren libcuda.so o librocm, las cuales no existen en una VM sin GPU

    # Instala el servicio en el directorio estándar de systemd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/

    # Extrae los pesos del modelo en /root/.ollama/
    # --no-same-owner: descarta el UID/GID original del tar para evitar errores de QA
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/gemma2-2b-prebaked.tar.gz \
        -C ${D}/root/.ollama/
}

# Lista todos los archivos que pertenecen a este paquete
FILES:${PN} += " \
    ${bindir}/ollama \
    ${systemd_system_unitdir}/ollama.service \
    /root/.ollama/ \
    /lib64 \
"

# El binario viene precompilado y sin símbolos de debug.
# Sin esta línea, BitBake lanzaría un error de QA al detectarlo.
# "arch" se agrega porque patchelf modifica el ELF y BitBake podría
# quejarse de arquitectura no reconocida en el binario parcheado.
INSANE_SKIP:${PN} = "already-stripped arch"
