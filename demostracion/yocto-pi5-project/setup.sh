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
agent.py — Asistente de ventas automatizado para tienda de electrónica.

Flujo principal:
  1. wait_for_ollama: espera a que la API de Ollama responda (/api/tags)
  2. warmup_ollama: hace una inferencia pequeña para cargar el modelo en RAM
  3. Bucle cada CHECK_INTERVAL segundos:
     a. Lee store_info.md fresco (permite cambios sin reiniciar el servicio)
     b. Conecta a Gmail via IMAP SSL, busca correos no leídos (UNSEEN)
     c. Por cada correo: construye prompt, llama a Ollama, envía respuesta
     d. Marca el correo como leído para no procesarlo dos veces
"""

import imaplib, smtplib, email, time, logging, requests
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import decode_header

CONFIG_FILE     = "/etc/email-agent/config.env"
STORE_INFO_FILE = "/etc/email-agent/store_info.md"
LOG_FILE        = "/var/log/email-agent.log"


def load_config():
    """
    Lee config.env y devuelve un diccionario clave=valor.
    Ignora líneas vacías y comentarios (# al inicio).
    Divide solo en el primer '=' para manejar valores que contengan '='.
    """
    config = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, val = line.split('=', 1)
                config[key.strip()] = val.strip()
    return config


def load_store_info():
    """
    Lee store_info.md completo y lo devuelve como string.
    Se llama en cada iteración del bucle principal para que los cambios
    en el inventario tomen efecto sin reiniciar el servicio.
    """
    with open(STORE_INFO_FILE) as f:
        return f.read()


def decode_str(s):
    """
    Decodifica campos de email codificados en base64 o quoted-printable.
    Los asuntos con tildes, ñ u otros caracteres especiales llegan así:
    =?UTF-8?Q?Consulta_de_componentes?=
    Esta función los convierte a texto legible.
    """
    parts = []
    for part, enc in decode_header(s):
        if isinstance(part, bytes):
            parts.append(part.decode(enc or 'utf-8', errors='replace'))
        else:
            parts.append(part)
    return ''.join(parts)


def get_email_body(msg):
    """
    Extrae el cuerpo en texto plano del mensaje.
    Los emails modernos son multipart (texto + HTML). Solo se necesita
    la parte text/plain para enviarla al LLM.
    """
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == 'text/plain':
                payload = part.get_payload(decode=True)
                if payload:
                    return payload.decode(part.get_content_charset() or 'utf-8', errors='replace')
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            return payload.decode(msg.get_content_charset() or 'utf-8', errors='replace')
    return ""


def extract_sender_address(from_header):
    """
    Extrae solo la dirección de email del campo From.
    Maneja dos formatos:
      - "Nombre Apellido <email@dominio.com>" → retorna email@dominio.com
      - "email@dominio.com" → retorna directamente
    """
    if '<' in from_header and '>' in from_header:
        return from_header.split('<')[1].split('>')[0].strip()
    return from_header.strip()


def build_prompt(store_info, personality, subject, body):
    """
    Construye el texto completo que recibe el LLM.

    El inventario va ANTES de las reglas para que el modelo lo tenga
    en contexto cuando procesa las instrucciones.

    Las reglas están numeradas y son específicas. Modelos pequeños
    siguen mejor reglas concretas ("busca DISPONIBLE o AGOTADO")
    que instrucciones genéricas ("usa solo el inventario").

    El cuerpo del correo se trunca a 600 caracteres para no desperdiciar
    tokens del contexto limitado del modelo en emails muy largos.

    La variable personality viene de config.env y permite cambiar
    el tono del asistente sin modificar el código.
    """
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
    Envía el prompt a la API REST de Ollama y espera la respuesta completa.

    stream=False: espera a que el modelo termine antes de retornar.
    temperature=0.1: mínima creatividad. Con valores más altos el modelo
      tiende a "rellenar" con información inventada cuando no la encuentra
      en el contexto — exactamente lo que causa falsos positivos.
    num_predict=1200: suficiente para responder múltiples preguntas
      (productos + ubicación + horarios) sin truncarse.
    timeout=600: 10 minutos. qwen3:4b en CPU puede tardar 5-8 minutos.
    """
    url = f"{ollama_url}/api/generate"
    payload = {"model": model, "prompt": prompt, "stream": False,
               "options": {"num_predict": 1200, "temperature": 0.1}}
    logger.info(f"Enviando prompt a Ollama ({len(prompt)} chars)...")
    start = time.time()
    response = requests.post(url, json=payload, timeout=600)
    response.raise_for_status()
    result = response.json()["response"].strip()
    logger.info(f"Respuesta en {time.time()-start:.1f}s")
    return result


def warmup_ollama(model, ollama_url, logger):
    """
    Hace una inferencia pequeña para confirmar que el modelo está en RAM.

    Problema que resuelve: /api/tags responde en cuanto Ollama arranca,
    pero el modelo puede tardar 30-60 segundos más en cargarse. Si el
    agente hace una solicitud real antes de que el modelo esté listo,
    la inferencia falla silenciosamente con un error 404.
    Un warmup con num_predict=5 fuerza la carga completa del modelo.
    """
    logger.info("Calentando el modelo...")
    payload = {"model": model, "prompt": "Di solo: OK",
               "stream": False, "options": {"num_predict": 5}}
    try:
        response = requests.post(f"{ollama_url}/api/generate", json=payload, timeout=180)
        response.raise_for_status()
        logger.info("Warmup completado.")
        return True
    except Exception as e:
        logger.error(f"Warmup fallo: {e}")
        return False


def wait_for_ollama(ollama_url, logger, retries=15, delay=20):
    """
    Espera hasta 5 minutos (15 intentos × 20 segundos) a que Ollama responda.
    Consulta /api/tags que lista los modelos instalados — si responde con
    HTTP 200, el servidor está activo (aunque el modelo puede seguir cargando).
    """
    for i in range(retries):
        try:
            r = requests.get(f"{ollama_url}/api/tags", timeout=5)
            if r.status_code == 200:
                logger.info("Ollama responde.")
                return True
        except Exception:
            pass
        logger.info(f"Esperando Ollama... {i+1}/{retries}")
        time.sleep(delay)
    logger.error("Ollama no respondio.")
    return False


def send_reply(config, to_address, subject, body, logger):
    """
    Envía la respuesta via Gmail SMTP sobre SSL en el puerto 465.
    Usa App Password de Google (no la contraseña normal):
    Google bloquea IMAP/SMTP con contraseña normal cuando 2FA está activo.
    """
    reply_subject = subject if subject.startswith("Re:") else f"Re: {subject}"
    msg = MIMEMultipart()
    msg['From'] = config['GMAIL_USER']
    msg['To'] = to_address
    msg['Subject'] = reply_subject
    # utf-8 garantiza que las tildes y caracteres especiales se envíen correctamente
    msg.attach(MIMEText(body, 'plain', 'utf-8'))
    logger.info(f"Enviando a {to_address}...")
    with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=30) as server:
        server.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        server.send_message(msg)
    logger.info("Enviado.")


def process_unread_emails(config, store_info, logger):
    """
    Ciclo principal de procesamiento:
      1. Conecta a Gmail via IMAP SSL (puerto 993)
      2. Busca correos no leídos (flag UNSEEN)
      3. Por cada correo: genera respuesta con Ollama y la envía por SMTP
      4. Marca el correo como leído (flag Seen) para no procesarlo de nuevo

    Si un correo falla, se marca como leído igualmente para evitar
    un bucle infinito donde el mismo correo fallido se reintenta siempre.
    """
    ollama_url  = config.get('OLLAMA_URL', 'http://localhost:11434')
    model       = config.get('OLLAMA_MODEL', 'qwen3:4b')
    personality = config.get('PERSONALITY', 'Firma como "Equipo de Ventas - TecnoPartes S.A."')

    logger.info("Conectando a Gmail IMAP...")
    try:
        mail = imaplib.IMAP4_SSL('imap.gmail.com', timeout=30)
    except Exception as e:
        logger.error(f"Fallo conexion: {e}"); return

    try:
        mail.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        logger.info("Autenticacion IMAP ok.")
    except imaplib.IMAP4.error as e:
        logger.error(f"Error auth IMAP: {e}"); mail.logout(); return

    mail.select('inbox')
    status, messages = mail.search(None, 'UNSEEN')
    if status != 'OK' or not messages[0]:
        logger.info("Sin correos nuevos."); mail.logout(); return

    email_ids = messages[0].split()
    logger.info(f"Correos no leidos: {len(email_ids)}")

    for email_id in email_ids:
        try:
            status, data = mail.fetch(email_id, '(RFC822)')
            if status != 'OK': continue
            msg       = email.message_from_bytes(data[0][1])
            sender    = msg.get('From', '')
            subject   = decode_str(msg.get('Subject', '(Sin asunto)'))
            body      = get_email_body(msg)
            sender_address = extract_sender_address(sender)
            logger.info(f"--- De: {sender_address} | {subject}")
            prompt     = build_prompt(store_info, personality, subject, body)
            reply_text = query_ollama(prompt, model, ollama_url, logger)
            send_reply(config, sender_address, subject, reply_text, logger)
            mail.store(email_id, '+FLAGS', '\\Seen')
            logger.info(f"Correo {email_id} leido.")
        except Exception as e:
            logger.error(f"Error correo {email_id}: {e}")
            try: mail.store(email_id, '+FLAGS', '\\Seen')
            except: pass

    mail.logout()


def main():
    """
    Punto de entrada del servicio. Configura el sistema de logging,
    espera a Ollama, calienta el modelo y entra al bucle infinito.

    El bucle lee store_info.md en cada iteración para que los cambios
    en el inventario tomen efecto sin reiniciar el servicio.
    """
    logging.basicConfig(filename=LOG_FILE, level=logging.INFO,
                        format='%(asctime)s [%(levelname)s] %(message)s')
    logger = logging.getLogger(__name__)
    logger.info("=== Email agent iniciado ===")

    config         = load_config()
    check_interval = int(config.get('CHECK_INTERVAL', '60'))
    ollama_url     = config.get('OLLAMA_URL', 'http://localhost:11434')
    model          = config.get('OLLAMA_MODEL', 'qwen3:4b')

    if not wait_for_ollama(ollama_url, logger):
        logger.error("Abortando."); return
    if not warmup_ollama(model, ollama_url, logger):
        logger.warning("Warmup fallo.")

    logger.info(f"Agente listo. Revisando cada {check_interval}s.")

    while True:
        try:
            store_info = load_store_info()
            process_unread_emails(config, store_info, logger)
        except Exception as e:
            logger.error(f"Error ciclo: {e}")
        time.sleep(check_interval)


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
MACHINE = "raspberrypi5"
DISTRO = "poky"
PACKAGE_CLASSES = "package_ipk"

# systemd como sistema de init (reemplaza SysVinit)
DISTRO_FEATURES:append = " systemd"
# usrmerge: requerido por systemd en Scarthgap para proveer udev
# Sin esto el build falla con "Nothing PROVIDES udev"
DISTRO_FEATURES:append = " usrmerge"
# wifi: activa el subsistema WiFi en toda la distro (kernel, firmware, herramientas)
DISTRO_FEATURES:append = " wifi"
VIRTUAL-RUNTIME_init_manager = "systemd"
DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"

# Zona horaria de Costa Rica (UTC-6, sin horario de verano)
# Variable nativa de Yocto: instala tzdata y crea /etc/localtime
DEFAULT_TIMEZONE = "America/Costa_Rica"

RPI_USE_U_BOOT = "0"
ENABLE_UART = "1"
ENABLE_SPI_BUS = "1"
ENABLE_I2C = "1"

EXTRA_IMAGE_FEATURES += " \
    empty-root-password \
    ssh-server-openssh \
    allow-empty-password \
"

IMAGE_INSTALL:append = " \
    dhcpcd \
    iproute2 \
    iputils \
    net-tools \
"

IMAGE_INSTALL:append = " tzdata"

# linux-firmware: firmware para el chip WiFi BCM43455 del RPi5
#   Sin este paquete la interfaz wlan0 no aparece en el sistema.
#   Se usa linux-firmware (general) en lugar de linux-firmware-bcm43455
#   porque garantiza disponibilidad independientemente de la versión de meta-oe.
# wpa-supplicant: demonio de autenticación WPA/WPA2
#   Lee /etc/wpa_supplicant/wpa_supplicant-wlan0.conf al arrancar.
IMAGE_INSTALL:append = " \
    linux-firmware \
    wpa-supplicant \
"

IMAGE_INSTALL:append = " \
    bash \
    vim \
    htop \
    procps \
    coreutils \
"

IMAGE_INSTALL:append = " ollama ca-certificates libstdc++ libgcc libgomp numactl"

IMAGE_FSTYPES = "wic.bz2"
# qwen3:4b ocupa ~2.6 GB; con 8 GB extra hay margen suficiente
IMAGE_ROOTFS_EXTRA_SPACE = "8388608"
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch commercial"

BB_NUMBER_PARSE_THREADS = "2"
BB_NUMBER_THREADS = "4"
PARALLEL_MAKE = "-j 4"

DL_DIR ?= "${TOPDIR}/../downloads"
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache"
TMPDIR = "${TOPDIR}/tmp"

CONF_VERSION = "2"

# Desactiva manifiestos SPDX — causan colisiones de sstate
# cuando se cambia DISTRO_FEATURES entre compilaciones
INHERIT:remove = "create-spdx"
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
echo "=================================================="
