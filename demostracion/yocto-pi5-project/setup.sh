#!/bin/bash
# ================================================================
#  setup.sh — Configuración automática del workspace de Yocto
#
#  Se ejecuta UNA SOLA VEZ durante el primer arranque del contenedor,
#  cuando el volumen del host está vacío. Hace todo lo que normalmente
#  se haría manualmente:
#    - Clona Poky y las capas adicionales
#    - Inicializa el entorno de build
#    - Registra todas las capas en bblayers.conf
#    - Crea la capa meta-ai con toda su estructura
#    - Escribe todos los archivos de recetas, configuración y servicios
#    - Escribe local.conf con la configuración final del proyecto
#
#  Al terminar, el workspace está completamente listo. Solo faltan
#  los dos archivos binarios pesados que el usuario copia aparte:
#    - ollama-linux-arm64.tar.zst  (binario de Ollama v0.22.1 ARM64)
#    - gemma3-4b-prebaked.tar.gz    (pesos del modelo gemma3:4b)
# ================================================================

set -e  # El script se detiene si cualquier comando falla

# ── Rutas absolutas ───────────────────────────────────────────────
# Todo el script usa estas variables para evitar errores de directorio.
# Cambiar el directorio de trabajo nunca afecta las rutas.
WORKSPACE=/home/yoctouser/yocto-workspace
POKY=$WORKSPACE/poky
BUILD=$POKY/build
META_AI=$BUILD/meta-ai

# ── Paso 1: Clonar repositorios ───────────────────────────────────
echo ">>> Clonando Poky (rama scarthgap)..."
# Poky: núcleo de Yocto — incluye BitBake, recetas base y toolchain
git clone -b scarthgap https://git.yoctoproject.org/poky.git $POKY

echo ">>> Clonando meta-raspberrypi..."
# BSP para Raspberry Pi: kernel, firmware, device tree del RPi5
git clone -b scarthgap https://git.yoctoproject.org/meta-raspberrypi $POKY/meta-raspberrypi

echo ">>> Clonando meta-openembedded..."
# Colección de capas con recetas extra:
# meta-oe: librerías del sistema, meta-python: módulos Python,
# meta-networking: dhcpcd, net-tools, wpa-supplicant
git clone -b scarthgap https://github.com/openembedded/meta-openembedded.git $POKY/meta-openembedded

# ── Paso 2: Inicializar el entorno de build ───────────────────────
# source oe-init-build-env modifica PATH y variables de entorno del shell.
# Requiere que el directorio actual sea poky/. Es el único cd del script.
# Después de este comando, el directorio activo es $BUILD (poky/build/).
echo ">>> Inicializando entorno de build..."
cd $POKY
source oe-init-build-env build

# ── Paso 3: Verificar que los clones quedaron bien ────────────────
# Falla con mensaje claro si alguna capa no existe,
# en lugar de producir errores crípticos de bitbake-layers más adelante.
echo ">>> Verificando rutas de capas..."
for dir in \
    "$POKY/meta-openembedded/meta-oe" \
    "$POKY/meta-openembedded/meta-python" \
    "$POKY/meta-openembedded/meta-networking" \
    "$POKY/meta-raspberrypi"; do
    if [ ! -d "$dir" ]; then
        echo "ERROR: no existe $dir"; exit 1
    fi
    echo "  OK: $dir"
done

# ── Paso 4: Registrar capas en bblayers.conf ──────────────────────
# Rutas absolutas para que bblayers.conf quede con paths completos.
# El orden importa: meta-oe antes que meta-python y meta-networking
# porque estos últimos dependen de recetas de meta-oe.
echo ">>> Registrando capas..."
bitbake-layers add-layer $POKY/meta-openembedded/meta-oe
bitbake-layers add-layer $POKY/meta-openembedded/meta-python
bitbake-layers add-layer $POKY/meta-openembedded/meta-networking
bitbake-layers add-layer $POKY/meta-raspberrypi

# Crear meta-ai con la estructura mínima requerida (conf/layer.conf, README)
# y registrarla en bblayers.conf en un solo comando
echo ">>> Creando capa meta-ai..."
bitbake-layers create-layer $META_AI
bitbake-layers add-layer $META_AI

# ── Paso 5: Crear estructura de directorios ───────────────────────
echo ">>> Creando directorios..."
mkdir -p $META_AI/recipes-ai/ollama/files
mkdir -p $META_AI/recipes-ai/email-agent/files
mkdir -p $META_AI/recipes-core/autologin/files
mkdir -p $META_AI/recipes-core/images
mkdir -p $META_AI/recipes-core/show-ip/files

# ── Paso 6: Escribir archivos de recetas ─────────────────────────
# Los heredocs usan delimitador entre comillas simples ('EOF').
# Con esa sintaxis bash NO interpreta el contenido: los $, las llaves
# de BitBake (${D}, ${PN}), las f-strings de Python y todo lo demás
# se escriben literalmente tal como están.
echo ">>> Escribiendo archivos de recetas..."

# ── layer.conf ───────────────────────────────────────────────────
# Define la identidad de la capa ante BitBake. Sin él, BitBake
# no sabe que meta-ai existe ni qué recetas contiene.
cat > $META_AI/conf/layer.conf << 'EOF'
# Agrega esta capa al BBPATH para que BitBake encuentre sus archivos
BBPATH .= ":${LAYERDIR}"

# Registra todos los archivos .bb y .bbappend dentro de carpetas recipes-*
BBFILES += "${LAYERDIR}/recipes-*/*/*.bb \
            ${LAYERDIR}/recipes-*/*/*.bbappend"

BBFILE_COLLECTIONS += "meta-ai"
BBFILE_PATTERN_meta-ai = "^${LAYERDIR}/"

# Prioridad 10: si hay conflicto con otra capa, gana esta
BBFILE_PRIORITY_meta-ai = "10"

# Capas requeridas para que meta-ai funcione
LAYERDEPENDS_meta-ai = "core raspberrypi"

# Compatibilidad declarada con Yocto Scarthgap (versión 5.0.x)
LAYERSERIES_COMPAT_meta-ai = "scarthgap"
EOF

# ── ollama_1.0.bb ─────────────────────────────────────────────────
# Instala el binario de Ollama, el servicio systemd y los pesos
# del modelo gemma3:4b en la imagen.
# El formato del binario es .tar.zst (Ollama v0.22.1+), no .tgz.
cat > $META_AI/recipes-ai/ollama/ollama_1.0.bb << 'EOF'
SUMMARY = "Ollama local AI model runner con gemma3:4b preinstalado"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ollama-linux-arm64.tar.zst;subdir=ollama-release \
    file://ollama.service \
    file://gemma3-4b-prebaked.tar.gz;unpack=0 \
"
# subdir=ollama-release: extrae el tar.zst en su propia carpeta
# unpack=0 en el modelo: se extrae manualmente para controlar el destino

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "ollama.service"
# enable: el servicio arranca automáticamente en cada boot
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Crea el directorio /usr/bin/ dentro del staging si no existe.
    install -d ${D}${bindir}
    
    # Copia el binario de Ollama al staging en /usr/bin/ollama.
    # -m 0755 establece los permisos: el dueño puede leer/escribir/ejecutar,
    # el resto solo puede leer y ejecutar. Necesario para que sea ejecutable.
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

    # Crea el directorio de unidades systemd dentro del staging.
    install -d ${D}${systemd_system_unitdir}
    
    # Copia el archivo ollama.service al directorio de systemd en el staging.
    # -m 0644: el dueño puede leer/escribir, el resto solo puede leer.
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/

    # Extrae el tar.gz del modelo directamente en /root/.ollama/ del staging.
    # Esto "hornea" los pesos del modelo dentro de la imagen — al arrancar
    # la Pi, el modelo ya está disponible sin necesitar descargarlo.
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/gemma3-4b-prebaked.tar.gz \
        -C ${D}/root/.ollama/
}

FILES:${PN} += " \
    ${bindir}/ollama \
    ${systemd_system_unitdir}/ollama.service \
    /root/.ollama/ \
"

# El binario viene precompilado y sin símbolos de debug
INSANE_SKIP:${PN} = "already-stripped"
EOF

# ── ollama.service ────────────────────────────────────────────────
# Define cómo systemd arranca Ollama. Las variables de entorno son
# críticas: un servicio systemd no hereda el entorno del usuario,
# por lo que HOME y OLLAMA_MODELS deben definirse explícitamente.
cat > $META_AI/recipes-ai/ollama/files/ollama.service << 'EOF'
[Unit]
Description=Ollama Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=root

# Ollama busca modelos en $HOME/.ollama/models
# Sin esta variable, el servicio no encuentra los modelos
Environment=HOME=/root
Environment=OLLAMA_MODELS=/root/.ollama/models

# Escucha en todas las interfaces (necesario para llamadas locales del agente)
Environment=OLLAMA_HOST=0.0.0.0:11434

# Sin límite de tiempo para detener: un modelo grande puede tardar en cerrarse
TimeoutStopSec=infinity
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ── autologin_1.0.bb ──────────────────────────────────────────────
# Instala el drop-in de systemd que hace autologin de root en tty1.
cat > $META_AI/recipes-core/autologin/autologin_1.0.bb << 'EOF'
SUMMARY = "Autologin de root en tty1 sin contraseña"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://autologin.conf"
S = "${WORKDIR}"
do_install() {
    install -d ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/
    install -m 0644 ${WORKDIR}/autologin.conf \
        ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf
}
FILES:${PN} = "${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf"
EOF

# ── autologin.conf ────────────────────────────────────────────────
# Drop-in de systemd para getty@tty1. La primera línea ExecStart vacía
# borra el comando original de getty antes de definir el nuevo con
# --autologin. Sin borrar el original, systemd acumularía dos comandos.
cat > $META_AI/recipes-core/autologin/files/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF

# ── show-ip_1.0.bb ────────────────────────────────────────────────
cat > $META_AI/recipes-core/show-ip/show-ip_1.0.bb << 'EOF'
SUMMARY = "Muestra la dirección IP al iniciar sesión"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://99-show-ip.sh"
S = "${WORKDIR}"
do_install() {
    # /etc/profile.d/ se ejecuta en cada login interactivo (consola y SSH)
    install -d ${D}${sysconfdir}/profile.d/
    install -m 0755 ${WORKDIR}/99-show-ip.sh \
        ${D}${sysconfdir}/profile.d/99-show-ip.sh
}
FILES:${PN} = "${sysconfdir}/profile.d/99-show-ip.sh"
RDEPENDS:${PN} = "iproute2"
EOF

# ── 99-show-ip.sh ─────────────────────────────────────────────────
# Muestra las IPs de todas las interfaces activas al hacer login.
# Incluye wlan0 para mostrar la IP WiFi cuando la Pi usa hotspot.
cat > $META_AI/recipes-core/show-ip/files/99-show-ip.sh << 'EOF'
#!/bin/sh
echo ""
echo "┌─────────────────────────────────────────┐"
echo "│         Raspberry Pi 5 — Yocto          │"
echo "├─────────────────────────────────────────┤"
found=0
# Itera las interfaces más comunes del RPi5
# eth0/end0: Ethernet, wlan0: WiFi
for iface in eth0 eth1 end0 wlan0; do
    IP=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / { split($2, a, "/"); print a[1] }')
    if [ -n "$IP" ]; then
        printf "│  %-6s  →  ssh root@%-18s │\n" "$iface" "$IP"
        found=1
    fi
done
if [ "$found" -eq 0 ]; then
    echo "│  Sin IP asignada aún. Esperando DHCP... │"
fi
echo "└─────────────────────────────────────────┘"
echo ""
EOF

# ── core-image-base.bbappend ──────────────────────────────────────
# Extiende core-image-base para agregar los paquetes propios y
# ejecutar tres funciones de configuración sobre el rootfs:
#   - configure_sshd: habilita SSH sin contraseña
#   - enable_timesyncd: habilita NTP (necesario para SSL con Gmail)
#   - configure_wifi: instala credenciales WiFi y habilita wpa_supplicant
cat > $META_AI/recipes-core/images/core-image-base.bbappend << 'EOF'
IMAGE_INSTALL:append = " autologin show-ip email-agent"

ROOTFS_POSTPROCESS_COMMAND:append = " configure_sshd; enable_timesyncd; configure_wifi;"

configure_sshd() {
    SSHD_CONFIG="${IMAGE_ROOTFS}/etc/ssh/sshd_config"
    if [ ! -f "${SSHD_CONFIG}" ]; then
        bbwarn "sshd_config no encontrado, omitiendo."; return 0
    fi
    # Permite login de root (bloqueado por defecto en OpenSSH)
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'          "${SSHD_CONFIG}"
    # Permite contraseñas vacías
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' "${SSHD_CONFIG}"
    # Desactiva PAM: con PAM activo rechaza contraseñas vacías
    # aunque OpenSSH las permitiría
    sed -i 's/^#*UsePAM.*/UsePAM no/'                             "${SSHD_CONFIG}"
    grep -q "^PermitRootLogin"      "${SSHD_CONFIG}" || echo "PermitRootLogin yes"      >> "${SSHD_CONFIG}"
    grep -q "^PermitEmptyPasswords" "${SSHD_CONFIG}" || echo "PermitEmptyPasswords yes" >> "${SSHD_CONFIG}"
    grep -q "^UsePAM"               "${SSHD_CONFIG}" || echo "UsePAM no"                >> "${SSHD_CONFIG}"
}

enable_timesyncd() {
    # systemd-timesyncd viene dentro del paquete systemd pero no está
    # habilitado por defecto en imágenes mínimas de Yocto.
    # Este symlink es el equivalente de "systemctl enable systemd-timesyncd"
    # aplicado en tiempo de build. Se enlaza en sysinit.target porque
    # debe arrancar antes de que los servicios de red necesiten hora correcta.
    # Sin NTP activo los certificados SSL de Gmail fallan.
    WANTS_DIR="${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants"
    UNIT="${IMAGE_ROOTFS}/usr/lib/systemd/system/systemd-timesyncd.service"
    if [ -f "${UNIT}" ]; then
        install -d "${WANTS_DIR}"
        ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
               "${WANTS_DIR}/systemd-timesyncd.service"
    else
        bbwarn "systemd-timesyncd.service no encontrado."
    fi
}

configure_wifi() {
    # Instala las credenciales WiFi del hotspot del iPhone.
    # El nombre del archivo wpa_supplicant-wlan0.conf es estándar de systemd:
    # la parte "wlan0" indica la interfaz que gestiona este archivo.
    # wpa_supplicant@wlan0.service lo lee automáticamente al arrancar.
    #
    # Se usa printf en lugar de heredoc porque BitBake no soporta
    # heredocs (<<) dentro de funciones shell del bbappend.
    WPA_DIR="${IMAGE_ROOTFS}/etc/wpa_supplicant"
    install -d "${WPA_DIR}"

    WPA_CONF="${WPA_DIR}/wpa_supplicant-wlan0.conf"
    printf 'ctrl_interface=/var/run/wpa_supplicant\n'  >  "${WPA_CONF}"
    printf 'ctrl_interface_group=0\n'                  >> "${WPA_CONF}"
    printf 'update_config=1\n'                         >> "${WPA_CONF}"
    printf '\n'                                        >> "${WPA_CONF}"
    printf 'network={\n'                               >> "${WPA_CONF}"
    printf '    ssid="iPhone de Gabriel"\n'            >> "${WPA_CONF}"
    printf '    psk="unodostres456"\n'                 >> "${WPA_CONF}"
    printf '    key_mgmt=WPA-PSK\n'                    >> "${WPA_CONF}"
    printf '    priority=1\n'                          >> "${WPA_CONF}"
    printf '}\n'                                       >> "${WPA_CONF}"

    # 0600: solo root puede leer el archivo (contiene contraseña en texto plano)
    chmod 0600 "${WPA_CONF}"

    # Habilita wpa_supplicant@wlan0 enlazándolo en multi-user.target.
    # Es el equivalente de "systemctl enable wpa_supplicant@wlan0" en build time.
    # Se enlaza en multi-user (no sysinit) porque necesita la red básica ya activa.
    WANTS_DIR="${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants"
    UNIT="${IMAGE_ROOTFS}/usr/lib/systemd/system/wpa_supplicant@.service"
    if [ -f "${UNIT}" ]; then
        install -d "${WANTS_DIR}"
        ln -sf /usr/lib/systemd/system/wpa_supplicant@.service \
               "${WANTS_DIR}/wpa_supplicant@wlan0.service"
        bbdebug 1 "configure_wifi: wpa_supplicant@wlan0 habilitado."
    else
        bbwarn "configure_wifi: wpa_supplicant@.service no encontrado."
    fi
}
EOF

# ── email-agent_1.0.bb ────────────────────────────────────────────
cat > $META_AI/recipes-ai/email-agent/email-agent_1.0.bb << 'EOF'
SUMMARY = "Agente de email — asistente de ventas de tienda de electrónica"
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
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}/usr/bin/email-agent/
    install -m 0755 ${WORKDIR}/agent.py ${D}/usr/bin/email-agent/agent.py
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/email-agent.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}/email-agent/
    # 0640: solo root puede escribir las credenciales
    install -m 0640 ${WORKDIR}/config.env    ${D}${sysconfdir}/email-agent/config.env
    install -m 0644 ${WORKDIR}/store_info.md ${D}${sysconfdir}/email-agent/store_info.md
}

FILES:${PN} = " \
    /usr/bin/email-agent/agent.py \
    ${systemd_system_unitdir}/email-agent.service \
    ${sysconfdir}/email-agent/config.env \
    ${sysconfdir}/email-agent/store_info.md \
"

# CONFFILES: el gestor de paquetes no sobreescribe estos archivos
# si el paquete se actualiza y el usuario ya los editó en la Pi
CONFFILES:${PN} = " \
    ${sysconfdir}/email-agent/config.env \
    ${sysconfdir}/email-agent/store_info.md \
"

RDEPENDS:${PN} = " \
    python3 \
    python3-requests \
    python3-email \
    python3-netclient \
    python3-logging \
    python3-json \
"
EOF

# ── email-agent.service ───────────────────────────────────────────
cat > $META_AI/recipes-ai/email-agent/files/email-agent.service << 'EOF'
[Unit]
Description=Email Sales Agent - Asistente de ventas por correo
# Requiere que ollama esté corriendo antes de arrancar.
# Esto evita que el agente intente llamar a Ollama antes de que
# el modelo esté disponible.
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/bin/email-agent/agent.py
User=root
Environment=HOME=/root
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ── agent.py ──────────────────────────────────────────────────────
cat > $META_AI/recipes-ai/email-agent/files/agent.py << 'EOF'
#!/usr/bin/env python3
"""
agent.py — Asistente de ventas automatizado para TecnoPartes S.A.

Este script corre como un servicio de systemd en la Raspberry Pi 5.
Su trabajo es monitorear una bandeja de Gmail, leer los correos entrantes,
consultar al modelo de lenguaje (Ollama) para generar una respuesta basada
en el inventario de la tienda, y enviar esa respuesta al remitente.

Dependencias externas (no vienen con Python estándar):
    - requests: para hacer llamadas HTTP a la API de Ollama

Todo lo demás (imaplib, smtplib, email, logging) es parte de la
libreria estandar de Python y no requiere instalacion adicional.
"""

import imaplib   # Protocolo IMAP: permite leer correos desde un servidor de email
import smtplib   # Protocolo SMTP: permite enviar correos
import email     # Herramientas para parsear el contenido de un mensaje de email
import time      # Para medir tiempos y hacer pausas entre revisiones
import logging   # Para escribir mensajes de actividad en el archivo de log
import requests  # Para hacer peticiones HTTP a la API REST de Ollama

from email.mime.text      import MIMEText        # Crea el cuerpo del email de respuesta
from email.mime.multipart import MIMEMultipart   # Arma el email completo con sus headers
from email.header         import decode_header   # Decodifica asuntos con caracteres especiales

# Rutas fijas de los archivos de configuracion en la Pi
CONFIG_FILE     = "/etc/email-agent/config.env"     # Credenciales y parametros del agente
STORE_INFO_FILE = "/etc/email-agent/store_info.md"  # Inventario y datos de la tienda
LOG_FILE        = "/var/log/email-agent.log"        # Archivo donde se registra la actividad


# ===================================================================
# BLOQUE 1 — CARGA DE ARCHIVOS DE CONFIGURACION
# ===================================================================

def load_config():
    """
    Lee el archivo config.env y devuelve un diccionario con todos sus valores.

    El archivo tiene el formato CLAVE=valor, una por linea.
    Las lineas vacias y las que empiezan con # se ignoran.

    Ejemplo de contenido:
        GMAIL_USER=ventas@tecnopartes.cr
        GMAIL_APP_PASSWORD=abcdabcdabcdabcd
        OLLAMA_MODEL=gemma3:4b

    Retorna un diccionario como:
        {'GMAIL_USER': 'ventas@...', 'OLLAMA_MODEL': 'gemma3:4b', ...}
    """
    config = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            # Ignorar lineas vacias y comentarios
            if line and not line.startswith('#') and '=' in line:
                # split con maxsplit=1 divide solo en el primer '='
                # para manejar valores que puedan contener '=' (como contrasenas)
                key, val = line.split('=', 1)
                config[key.strip()] = val.strip()
    return config


def load_store_info():
    """
    Lee el archivo store_info.md completo y lo devuelve como texto.

    Este archivo contiene el inventario, precios, datos de la sucursal
    y horarios de la tienda. Se inyecta completo en el prompt del LLM
    para que el modelo tenga todo el contexto necesario al responder.

    Se llama en CADA ciclo del bucle principal, no solo al arrancar.
    Esto permite editar el inventario en la Pi sin reiniciar el servicio:
    el cambio toma efecto en el proximo ciclo de revision automaticamente.
    """
    with open(STORE_INFO_FILE) as f:
        return f.read()


# ===================================================================
# BLOQUE 2 — UTILIDADES PARA PROCESAR EMAILS ENTRANTES
# ===================================================================

def decode_str(s):
    """
    Decodifica campos de email que vienen codificados.

    Los campos Subject y From pueden venir en formato codificado cuando
    contienen tildes, n con tilde u otros caracteres especiales. Por ejemplo:
        =?UTF-8?Q?Consulta_de_componentes?=

    decode_header() los convierte a texto legible.
    Si el campo ya es texto plano, lo retorna sin cambios.
    """
    parts = []
    for part, enc in decode_header(s):
        if isinstance(part, bytes):
            # El fragmento esta codificado — decodificar con su charset
            parts.append(part.decode(enc or 'utf-8', errors='replace'))
        else:
            # Ya es texto plano
            parts.append(part)
    return ''.join(parts)


def get_email_body(msg):
    """
    Extrae unicamente el cuerpo en texto plano de un mensaje de email.

    Los emails modernos son "multipart": traen el mismo contenido en
    dos versiones, una en texto plano y otra en HTML.
    El agente solo necesita el texto plano para enviarlo al LLM.

    Si el email es simple (no multipart), extrae el contenido directo.
    Si no encuentra ninguna parte de texto, retorna una cadena vacia.
    """
    if msg.is_multipart():
        # Recorrer todas las partes del mensaje buscando text/plain
        for part in msg.walk():
            if part.get_content_type() == 'text/plain':
                payload = part.get_payload(decode=True)
                if payload:
                    charset = part.get_content_charset() or 'utf-8'
                    return payload.decode(charset, errors='replace')
    else:
        # Email simple con una sola parte
        payload = msg.get_payload(decode=True)
        if payload:
            charset = msg.get_content_charset() or 'utf-8'
            return payload.decode(charset, errors='replace')
    return ""


def extract_sender_address(from_header):
    """
    Extrae solo la direccion de email del campo From.

    El campo From puede venir en dos formatos:
        1. Solo la direccion:       cliente@gmail.com
        2. Nombre mas la direccion: Juan Perez <cliente@gmail.com>

    Esta funcion detecta el formato y siempre retorna solo la direccion,
    que es lo que se necesita para enviar la respuesta correctamente.
    """
    if '<' in from_header and '>' in from_header:
        # Formato "Nombre <email>" — extraer lo que esta entre < y >
        return from_header.split('<')[1].split('>')[0].strip()
    # Formato solo direccion — retornar directamente
    return from_header.strip()


# ===================================================================
# BLOQUE 3 — CONSTRUCCION DEL PROMPT Y CONSULTA AL LLM
# ===================================================================

def build_prompt(store_info, personality, subject, body):
    """
    Construye el texto completo que se enviara al modelo de lenguaje.

    El LLM no sabe nada de la tienda por si solo. Toda la informacion
    se la proporcionamos en este prompt. El modelo lee el texto y genera
    una respuesta basandose EXCLUSIVAMENTE en lo que recibe aqui.

    Estructura del prompt:
        1. Rol: define quien es el asistente
        2. Inventario: el contenido completo de store_info.md
        3. Reglas: instrucciones especificas para no inventar informacion
        4. Correo del cliente: asunto y cuerpo (truncado a 600 caracteres)
        5. Personalidad: tono y firma (viene de config.env)

    Por que truncar el cuerpo a 600 caracteres:
        Los modelos tienen un limite de tokens. Un email muy largo
        consumiria tokens que se necesitan para el inventario y las reglas.

    Por que las reglas son tan especificas:
        Los modelos pequenos (3-4B parametros) tienden a alucinar,
        es decir, inventan informacion plausible cuando no la encuentran.
        Reglas explicitas como "si no esta en la lista, di que no lo manejamos"
        reducen significativamente ese comportamiento.
    """
    # Limitar el cuerpo del correo a 600 caracteres
    body_truncated = body.strip()[:600]

    return f"""Eres un vendedor de TecnoPartes S.A. Responde el email del cliente usando exclusivamente la informacion textual de la lista de abajo.

LISTA DE LA TIENDA:
{store_info}

REGLAS:
1. Para cada producto que pida el cliente, busca su nombre en la lista de arriba.
2. Luego de encontrar el nombre exacto del producto, buscar la palabra "DISPONIBLE" o "AGOTADO".
3. Si dice DISPONIBLE: confirma que esta disponible y da el precio exacto de la lista.
4. Si dice AGOTADO: indica que esta agotado. No inventes precio ni fecha.
5. Si el producto no esta en la lista: indica que no lo manejamos. No lo inventes.
6. Para ubicacion y horarios: usa solo lo que dice la lista. No inventes direcciones.
7. Escribe la respuesta como un email normal.
8. Asegurate de que toda la informacion que brindes exista dentro de la "LISTA DE LA TIENDA". Si no encuentras algo dentro de esta, indica que no lo manejamos.

EMAIL DEL CLIENTE:
Asunto: {subject}
Mensaje: {body_truncated}

{personality}
Respuesta:"""


def query_ollama(prompt, model, ollama_url, logger):
    """
    Envia el prompt a la API de Ollama y espera la respuesta completa.

    Ollama expone una API REST en el puerto 11434.
    El endpoint /api/generate acepta el prompt y retorna el texto generado.

    Parametros importantes:
        stream=False:
            Con True Ollama envia tokens uno a uno conforme los genera.
            Con False espera a terminar y envia la respuesta completa.
            Se usa False para simplificar el procesamiento.

        temperature=0.1:
            Controla la creatividad del modelo.
            0.0 = completamente deterministico, siempre la misma respuesta.
            1.0 = muy creativo, propenso a inventar informacion.
            0.1 es casi deterministico: el modelo se cine al contexto
            dado, reduciendo las alucinaciones de datos inventados.

        num_predict=1200:
            Limite maximo de tokens en la respuesta.
            Con poco espacio el modelo truncaba antes de responder
            todas las preguntas (productos + ubicacion + horarios).

        timeout=600:
            10 minutos de espera maxima.
            qwen3:4b en CPU puro puede tardar entre 5 y 9 minutos.
    """
    url = f"{ollama_url}/api/generate"
    payload = {
        "model":  model,
        "prompt": prompt,
        "stream": False,
        "options": {"num_predict": 1200, "temperature": 0.1}
    }

    logger.info(f"Enviando prompt a Ollama ({len(prompt)} chars)...")
    start    = time.time()
    response = requests.post(url, json=payload, timeout=600)

    # raise_for_status lanza excepcion si el servidor retorno un error HTTP
    # (por ejemplo 404 si el modelo no esta cargado, 500 si hay un fallo interno)
    response.raise_for_status()

    result = response.json()["response"].strip()
    logger.info(f"Respuesta en {time.time()-start:.1f}s")
    return result


# ===================================================================
# BLOQUE 4 — INICIALIZACION Y WARMUP DE OLLAMA
# ===================================================================

def warmup_ollama(model, ollama_url, logger):
    """
    Hace una inferencia pequena para confirmar que el modelo esta en RAM.

    Problema que resuelve:
        Ollama arranca como servicio y su API responde en segundos,
        pero cargar el modelo completo en RAM puede tardar 30-60 segundos mas.
        Si el agente envia un correo real antes de que el modelo este listo,
        la inferencia falla silenciosamente con un error 404.

    Solucion:
        Enviar un prompt trivial con num_predict=5 (pocas palabras).
        Esto fuerza la carga completa del modelo en RAM.
        Cuando retorna exitosamente el modelo esta listo para correos reales.

    Si el warmup falla el agente continua de todas formas.
    Es mejor intentar procesar correos que bloquearse indefinidamente.
    """
    logger.info("Calentando el modelo...")
    payload = {
        "model":   model,
        "prompt":  "Di solo: OK",
        "stream":  False,
        "options": {"num_predict": 5}
    }
    try:
        response = requests.post(
            f"{ollama_url}/api/generate",
            json=payload,
            timeout=180  # 3 minutos maximo para el warmup
        )
        response.raise_for_status()
        logger.info("Warmup completado.")
        return True
    except Exception as e:
        logger.error(f"Warmup fallo: {e}")
        return False


def wait_for_ollama(ollama_url, logger, retries=15, delay=20):
    """
    Espera a que la API de Ollama este respondiendo antes de continuar.

    Ollama y el agente arrancan juntos con systemd. Aunque el servicio
    del agente tiene Requires=ollama.service, systemd solo garantiza
    que Ollama arranco, no que su API HTTP este lista para recibir peticiones.
    Esta funcion resuelve esa condicion de carrera.

    Logica:
        Consulta /api/tags (lista de modelos instalados) cada 20 segundos.
        Reintenta hasta 15 veces (5 minutos en total).
        Si responde HTTP 200 el servidor esta activo.
        Si todos los intentos fallan el agente aborta.
    """
    for i in range(retries):
        try:
            r = requests.get(f"{ollama_url}/api/tags", timeout=5)
            if r.status_code == 200:
                logger.info("Ollama responde.")
                return True
        except Exception:
            # Ollama aun no esta listo, intentar de nuevo
            pass
        logger.info(f"Esperando Ollama... {i+1}/{retries}")
        time.sleep(delay)

    logger.error("Ollama no respondio.")
    return False


# ===================================================================
# BLOQUE 5 — ENVIO DE RESPUESTA POR CORREO
# ===================================================================

def send_reply(config, to_address, subject, body, logger):
    """
    Envia la respuesta generada por el LLM al remitente via Gmail SMTP.

    Protocolo: SMTP sobre SSL en el puerto 465.
        SMTP_SSL establece la conexion cifrada desde el inicio.
        Se usa App Password de Google, no la contrasena normal.
        Google bloquea IMAP/SMTP con contrasena normal cuando 2FA esta activo.

    El asunto lleva "Re: " al principio para que el cliente sepa
    que es una respuesta a su correo original.
    utf-8 garantiza que tildes y caracteres especiales se transmitan bien.
    """
    # Agregar "Re: " al asunto si no lo tiene ya
    reply_subject = subject if subject.startswith("Re:") else f"Re: {subject}"

    # Construir el mensaje de email con sus headers
    msg = MIMEMultipart()
    msg['From']    = config['GMAIL_USER']
    msg['To']      = to_address
    msg['Subject'] = reply_subject
    msg.attach(MIMEText(body, 'plain', 'utf-8'))

    logger.info(f"Enviando a {to_address}...")
    # SMTP_SSL abre la conexion ya cifrada desde el inicio (puerto 465)
    with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=30) as server:
        server.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        server.send_message(msg)
    logger.info("Enviado.")


# ===================================================================
# BLOQUE 6 — CICLO PRINCIPAL DE PROCESAMIENTO DE CORREOS
# ===================================================================

def process_unread_emails(config, store_info, logger):
    """
    Conecta a Gmail via IMAP, lee todos los correos no leidos,
    genera una respuesta con el LLM para cada uno y la envia.

    IMAP (Internet Message Access Protocol):
        Permite leer correos dejandolos en el servidor.
        Se conecta por SSL en el puerto 993.

    Flag UNSEEN:
        Gmail marca internamente cada correo con flags.
        UNSEEN = no leido. Se buscan solo estos para no reprocesar correos.

    Flag Seen:
        Al terminar cada correo se marca como leido con el flag Seen.
        Esto evita que aparezca como UNSEEN en el proximo ciclo.

    Manejo de errores:
        Si un correo falla se marca como leido igualmente.
        Evita bucles infinitos donde el mismo correo falla repetidamente.
    """
    ollama_url  = config.get('OLLAMA_URL', 'http://localhost:11434')
    model       = config.get('OLLAMA_MODEL', 'gemma3:4b')
    personality = config.get('PERSONALITY', 'Firma como "Equipo de Ventas - TecnoPartes S.A."')

    # ── Conexion IMAP ─────────────────────────────────────────────
    logger.info("Conectando a Gmail IMAP...")
    try:
        # Conexion segura al servidor de Gmail en el puerto 993
        mail = imaplib.IMAP4_SSL('imap.gmail.com', timeout=30)
    except Exception as e:
        logger.error(f"Fallo conexion: {e}"); return

    try:
        mail.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        logger.info("Autenticacion IMAP ok.")
    except imaplib.IMAP4.error as e:
        logger.error(f"Error auth IMAP: {e}"); mail.logout(); return

    # Seleccionar la carpeta de entrada
    mail.select('inbox')

    # ── Buscar correos no leidos ──────────────────────────────────
    # search retorna lista de IDs de correos que coinciden con UNSEEN
    status, messages = mail.search(None, 'UNSEEN')
    if status != 'OK' or not messages[0]:
        logger.info("Sin correos nuevos."); mail.logout(); return

    # messages[0] es una cadena de IDs: b'1 2 3' -> [b'1', b'2', b'3']
    email_ids = messages[0].split()
    logger.info(f"Correos no leidos: {len(email_ids)}")

    # ── Procesar cada correo no leido ─────────────────────────────
    for email_id in email_ids:
        try:
            # RFC822: descarga el mensaje completo con headers y cuerpo
            status, data = mail.fetch(email_id, '(RFC822)')
            if status != 'OK': continue

            # Parsear los bytes a un objeto email de Python
            msg = email.message_from_bytes(data[0][1])

            # Extraer los campos del mensaje
            sender  = msg.get('From', '')
            subject = decode_str(msg.get('Subject', '(Sin asunto)'))
            body    = get_email_body(msg)
            sender_address = extract_sender_address(sender)
            logger.info(f"--- De: {sender_address} | {subject}")

            # Paso 1: construir el prompt con inventario + correo del cliente
            prompt = build_prompt(store_info, personality, subject, body)

            # Paso 2: enviar el prompt a Ollama y esperar la respuesta del LLM
            reply_text = query_ollama(prompt, model, ollama_url, logger)

            # Paso 3: enviar la respuesta al remitente por Gmail SMTP
            send_reply(config, sender_address, subject, reply_text, logger)

            # Paso 4: marcar el correo como leido para no reprocesarlo
            # '+FLAGS' agrega el flag al correo sin borrar los existentes
            mail.store(email_id, '+FLAGS', '\\Seen')
            logger.info(f"Correo {email_id} leido.")

        except Exception as e:
            logger.error(f"Error correo {email_id}: {e}")
            # Marcar como leido aunque haya error — evita bucles de reintento
            try: mail.store(email_id, '+FLAGS', '\\Seen')
            except: pass

    mail.logout()


# ===================================================================
# BLOQUE 7 — PUNTO DE ENTRADA PRINCIPAL
# ===================================================================

def main():
    """
    Punto de entrada del script cuando systemd lo arranca como servicio.

    Secuencia de arranque:
        1. Configura el sistema de logging (archivo con timestamp)
        2. Carga la configuracion desde config.env
        3. Espera a que Ollama este disponible
        4. Carga el modelo en RAM con una inferencia de prueba (warmup)
        5. Entra al bucle infinito de revision de correos

    El bucle lee store_info.md fresco en cada iteracion para que los
    cambios en el inventario tomen efecto sin reiniciar el servicio.
    Si una iteracion falla, el error se loguea y el bucle continua.
    El agente nunca se detiene por un error puntual.
    """
    # Configurar logging: escribe en archivo con timestamp en cada linea
    # Formato ejemplo: 2026-05-05 11:28:43,595 [INFO] Ollama responde.
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s'
    )
    logger = logging.getLogger(__name__)
    logger.info("=== Email agent iniciado ===")

    config         = load_config()
    check_interval = int(config.get('CHECK_INTERVAL', '60'))  # segundos entre revisiones
    ollama_url     = config.get('OLLAMA_URL', 'http://localhost:11434')
    model          = config.get('OLLAMA_MODEL', 'gemma3:4b')

    # Esperar a que Ollama este listo antes de hacer cualquier cosa
    if not wait_for_ollama(ollama_url, logger):
        logger.error("Abortando — Ollama no disponible.")
        return  # systemd reiniciara el servicio segun RestartSec=30

    # Calentar el modelo para que este en RAM al llegar el primer correo
    if not warmup_ollama(model, ollama_url, logger):
        logger.warning("Warmup fallo — el primer correo puede tardar mas.")

    logger.info(f"Agente listo. Revisando cada {check_interval}s.")

    # Bucle principal infinito
    while True:
        try:
            # Leer inventario fresco en cada ciclo
            store_info = load_store_info()
            process_unread_emails(config, store_info, logger)
        except Exception as e:
            logger.error(f"Error ciclo: {e}")
        # Pausar antes de la proxima revision
        time.sleep(check_interval)


# Garantiza que main() solo se ejecute cuando el script
# se corre directamente, no cuando se importa como modulo
if __name__ == '__main__':
    main()

EOF

# ── config.env ────────────────────────────────────────────────────
# Plantilla de configuración. Las credenciales se editan en la Pi
# después del primer arranque via SSH. Nunca hornear credenciales reales.
cat > $META_AI/recipes-ai/email-agent/files/config.env << 'EOF'
GMAIL_USER=tu_correo@gmail.com
GMAIL_APP_PASSWORD=xxxx xxxx xxxx xxxx
CHECK_INTERVAL=60
OLLAMA_MODEL=qwen3:4b
OLLAMA_URL=http://localhost:11434
PERSONALITY=Responde de forma profesional y amigable. Firma como "Equipo de Ventas - TecnoPartes S.A."
EOF

# ── store_info.md ─────────────────────────────────────────────────
cat > $META_AI/recipes-ai/email-agent/files/store_info.md << 'EOF'
# TecnoPartes S.A.
Telefono: +506 2234-5678 | Correo: ventas@tecnopartes.cr

SUCURSAL:
Direccion: De la Rotonda de la Hispanidad, 200 metros al este, local 4B, San Pedro, San Jose
Horario: Lunes a viernes 8:00 AM - 6:30 PM | Sabados 9:00 AM - 3:00 PM | Domingos cerrado

INVENTARIO:
- Resistencia 220 ohm 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 1k ohm 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 10k ohm 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 100 ohm 2W 5porciento: AGOTADO
- Resistencia 1k ohm 2W 5porciento: DISPONIBLE, $0.25 por unidad
- Condensador ceramico 10nF 50V: DISPONIBLE, $0.09 por unidad
- Condensador ceramico 100nF 50V: DISPONIBLE, $0.09 por unidad
- Condensador electrolitico 10uF 25V: DISPONIBLE, $0.21 por unidad
- Condensador electrolitico 100uF 25V: DISPONIBLE, $0.29 por unidad
- Transistor NPN BC547: DISPONIBLE, $0.44 por unidad
- Transistor PNP BC557: DISPONIBLE, $0.44 por unidad
- Transistor NPN 2N2222A: DISPONIBLE, $0.54 por unidad
- Transistor potencia TIP31C NPN: DISPONIBLE, $1.44 por unidad
- MOSFET IRF540N canal N: DISPONIBLE, $2.21 por unidad
- Amplificador operacional LM358: DISPONIBLE, $0.90 por unidad
- Amplificador operacional LM741: DISPONIBLE, $0.83 por unidad
- Amplificador operacional LM324: DISPONIBLE, $1.06 por unidad
- Temporizador NE555: DISPONIBLE, $0.73 por unidad
- Regulador de voltaje LM7805 5V: DISPONIBLE, $0.81 por unidad
- Regulador ajustable LM317: DISPONIBLE, $0.96 por unidad
- Driver de motores L293D: DISPONIBLE, $2.79 por unidad
- Arduino Uno R3: DISPONIBLE, $12.00 por unidad
- Arduino Nano: DISPONIBLE, $8.27 por unidad
- Arduino Mega 2560: DISPONIBLE, $18.27 por unidad
- ESP32 DevKit V1: DISPONIBLE, $10.19 por unidad
- ESP8266 NodeMCU: DISPONIBLE, $6.54 por unidad
- Raspberry Pi Pico: DISPONIBLE, $9.23 por unidad
- Modulo GPS NEO-6M: AGOTADO
- Sensor DHT22 temperatura y humedad: DISPONIBLE, $4.62 por unidad
- Sensor ultrasonido HC-SR04: DISPONIBLE, $3.37 por unidad
- LED rojo 5mm: DISPONIBLE, $0.05 por unidad
- LED verde 5mm: DISPONIBLE, $0.05 por unidad
- LED azul 5mm: DISPONIBLE, $0.09 por unidad
- Pantalla OLED 0.96in I2C: DISPONIBLE, $5.96 por unidad
- Pantalla LCD 16x2 con I2C: DISPONIBLE, $8.08 por unidad
- Modulo relay 1 canal: DISPONIBLE, $2.79 por unidad
- Modulo relay 4 canales: AGOTADO
- Servomotor SG90: DISPONIBLE, $4.23 por unidad
- Protoboard 830 puntos: DISPONIBLE, $4.62 por unidad
- Cables dupont MM 40 unidades: DISPONIBLE, $2.21 por paquete
- Cables dupont MF 40 unidades: DISPONIBLE, $2.21 por paquete
- Estano 60-40 rollo 100g: DISPONIBLE, $5.19 por rollo
- Soldador 30W: DISPONIBLE, $15.77 por unidad
- Multimetro digital: DISPONIBLE, $17.69 por unidad
EOF

# ── Paso 7: Escribir local.conf ───────────────────────────────────
# Reemplaza el local.conf generado por defecto por oe-init-build-env
echo ">>> Escribiendo local.conf..."
cat > $BUILD/conf/local.conf << 'EOF'
# CONFIGURACIÓN DE HARDWARE Y SISTEMA BASE
# =================================================================

# Define el hardware objetivo (Raspberry Pi 5) para compilar los drivers y kernel específicos.
MACHINE = "raspberrypi5"

# Utiliza la distribución de referencia del Proyecto Yocto.
DISTRO = "poky"

# Formato de paquetes .ipk (ligero), ideal para optimizar espacio en sistemas embebidos.
PACKAGE_CLASSES = "package_ipk"

# =================================================================
# GESTIÓN DE INICIO Y SERVICIOS (SYSTEMD)
# =================================================================

# Habilita systemd como el gestor de sistema para un arranque y control de servicios moderno.
DISTRO_FEATURES:append = " systemd"

# Fusiona directorios de binarios (/bin a /usr/bin) siguiendo estándares modernos de Linux.
DISTRO_FEATURES:append = " usrmerge"

# Define systemd como el manejador de ejecución en tiempo de funcionamiento.
VIRTUAL-RUNTIME_init_manager = "systemd"

# Ignora scripts de inicio antiguos (SysVinit) para evitar conflictos de redundancia.
DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"

# =================================================================
# CONFIGURACIÓN LOCAL Y PERIFÉRICOS
# =================================================================

# Establece la hora y región local para logs y cronogramas internos.
DEFAULT_TIMEZONE = "America/Costa_Rica"

# Arranca directamente desde el kernel, omitiendo U-Boot para reducir el tiempo de inicio.
RPI_USE_U_BOOT = "0"

# Habilita la comunicación serie por hardware (pines GPIO) para debugeo físico.
ENABLE_UART = "1"

# Activa los buses de comunicación para sensores o dispositivos externos (I2C y SPI).
ENABLE_SPI_BUS = "1"
ENABLE_I2C = "1"

# =================================================================
# ACCESO Y SEGURIDAD DE LA IMAGEN
# =================================================================

# Agrega servidor SSH para acceso remoto y permite acceso 'root' sin clave en desarrollo.
EXTRA_IMAGE_FEATURES += " \
    empty-root-password \
    ssh-server-openssh \
    allow-empty-password \
"

# =================================================================
# RED Y CONECTIVIDAD
# =================================================================

# Paquetes para gestión de red (IP dinámica, rutas y herramientas de diagnóstico).
IMAGE_INSTALL:append = " \
    dhcpcd \
    iproute2 \
    iputils \
    net-tools \
"

# Soporte para actualización de zona horaria y certificados de seguridad web.
IMAGE_INSTALL:append = " tzdata ca-certificates"

# Habilita el stack de WiFi y añade el firmware necesario para el chip inalámbrico de la RPi5.
DISTRO_FEATURES:append = " wifi"
IMAGE_INSTALL:append = " \
    linux-firmware \
    wpa-supplicant \
"

# =================================================================
# UTILIDADES DE TERMINAL Y SISTEMA
# =================================================================

# Instala shell Bash, editores y monitores de recursos (CPU/RAM) esenciales.
IMAGE_INSTALL:append = " \
    bash \
    vim \
    htop \
    procps \
    coreutils \
"

# =================================================================
# MOTOR DE INTELIGENCIA ARTIFICIAL (OLLAMA)
# =================================================================

# Instala Ollama y librerías de C++/computación necesarias para ejecutar modelos LLM.
# numactl optimiza el acceso a la memoria para procesos de alta carga computacional.
IMAGE_INSTALL:append = " ollama libstdc++ libgcc libgomp numactl"

# =================================================================
# ALMACENAMIENTO Y GENERACIÓN DE IMAGEN
# =================================================================

# Genera un archivo .wic comprimido, listo para ser flasheado en una tarjeta MicroSD.
IMAGE_FSTYPES = "wic.bz2"

# Reserva 8GB extras en la partición raíz para alojar modelos de IA y datos de usuario.
IMAGE_ROOTFS_EXTRA_SPACE = "8388608"

# Acepta licencias comerciales/restringidas requeridas para el firmware del WiFi.
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch commercial"

# =================================================================
# OPTIMIZACIÓN DEL HOST DE COMPILACIÓN (DOCKER/PC)
# =================================================================

# Limita la cantidad de núcleos usados en el build para evitar colapsar la RAM del PC.
BB_NUMBER_PARSE_THREADS = "2"
BB_NUMBER_THREADS = "4"
PARALLEL_MAKE = "-j 4"

# Define rutas para descargas y caché de compilación (ayuda a la persistencia en Docker).
DL_DIR ?= "${TOPDIR}/../downloads"
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache"
TMPDIR = "${TOPDIR}/tmp"

# Versión del archivo para compatibilidad con la versión actual de BitBake.
CONF_VERSION = "2"

# Desactiva la creación de documentos de licencias SPDX para reducir el tiempo de build.
INHERIT:remove = "create-spdx"==========="
EOF

echo ""
echo "=================================================="
echo "  Setup completo. Workspace listo."
echo ""
echo "  Pasos pendientes antes de bitbake:"
echo "  1. Copiar ollama-linux-arm64.tar.zst a:"
echo "     $META_AI/recipes-ai/ollama/files/"
echo "  2. Copiar qwen3-4b-prebaked.tar.gz a:"
echo "     $META_AI/recipes-ai/ollama/files/"
echo ""
echo "  Luego dentro del contenedor:"
echo "  bitbake core-image-base"
echo "=======================================# =================================================================

