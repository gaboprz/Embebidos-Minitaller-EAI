# Demostración práctica

Se usa una Raspberry Pi 5 de 8 GB de RAM. Se crea una imagen personalizada usando Yocto Scarthgap dentro de un contenedor Docker. La imagen es de consola, sin interfaz gráfica. Incluye acceso por SSH sin contraseña, autologin al encender, un LLM local corriendo con Ollama, y un agente que lee correos de Gmail y responde automáticamente como asistente de ventas de una tienda de electrónica.

---

## Creación del contenedor Docker

Yocto requiere una cantidad considerable de dependencias del sistema. Para no instalarlas directamente en el host y garantizar un entorno reproducible, todo el trabajo de compilación se hace dentro de un contenedor Docker basado en Ubuntu 22.04.

Con Docker instalado, se crea una carpeta para el proyecto y dentro de ella se crea el Dockerfile:

```bash
mkdir yocto-pi5-project
cd yocto-pi5-project
touch Dockerfile
```

Contenido del `Dockerfile`:

```dockerfile
FROM ubuntu:22.04

# Evita que apt lance preguntas interactivas durante la instalación de paquetes
ENV DEBIAN_FRONTEND=noninteractive

# Todas las dependencias que Yocto necesita para compilar:
# - compiladores (gcc, build-essential, chrpath)
# - herramientas de scripting (gawk, diffstat, python3 y sus módulos)
# - utilidades de compresión (xz-utils, zstd, liblz4-tool)
# - librerías gráficas requeridas por algunas recetas aunque no usemos GUI (libegl-mesa0, libsdl1.2-dev)
RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl-mesa0 libsdl1.2-dev \
    pylint xterm python3-subunit mesa-common-dev zstd liblz4-tool \
    python3-distutils curl locales sudo vim tmux file mc \
    && rm -rf /var/lib/apt/lists/*

# Yocto requiere un locale UTF-8 configurado correctamente
# Sin esto, algunos scripts de build fallan con errores de encoding
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Yocto no puede correr como root — se crea un usuario normal llamado yoctouser
ARG USERNAME=yoctouser
ARG USER_UID=1000
ARG USER_GID=1000

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Todo lo que corre dentro del contenedor lo hace como yoctouser, nunca como root
USER $USERNAME
WORKDIR /home/yoctouser/yocto-workspace

CMD ["/bin/bash"]
```

Construir y arrancar el contenedor:

```bash
# Archivos que Docker debe ignorar al construir la imagen
cat > .dockerignore << 'EOF'
target/
.git/
*.log
*.tmp
EOF

# Construye la imagen Docker con el nombre "yocto-builder-pi5"
docker build -t yocto-builder-pi5 .

# Crea y abre el contenedor por primera vez
# El flag -v monta la carpeta local dentro del contenedor para que
# los archivos del build persistan aunque el contenedor se detenga
docker run -it --name yocto-ia-pi5 \
  -v $(pwd)/yocto-workspace:/home/yoctouser/yocto-workspace \
  yocto-builder-pi5

# Para volver a entrar al contenedor en sesiones posteriores
docker start yocto-ia-pi5
docker exec -it yocto-ia-pi5 /bin/bash
```

---

## Clonado de capas y configuración inicial

Ya dentro del contenedor, se clona Poky y las capas adicionales necesarias. Poky es la distribución de referencia de Yocto: incluye BitBake (el motor de compilación), las recetas base del sistema y las políticas de build. La rama `scarthgap` es la versión LTS usada en este proyecto.

```bash
# Poky: el núcleo de Yocto con BitBake, recetas base y toolchain
git clone -b scarthgap git://git.yoctoproject.org/poky.git

cd poky

# Soporte específico para Raspberry Pi: MACHINE raspberrypi5, kernel, firmware y device tree
git clone -b scarthgap git://git.yoctoproject.org/meta-raspberrypi

# Colección de capas con recetas extra que Poky no incluye por defecto:
# meta-oe (librerías de sistema), meta-python (módulos Python), meta-networking (dhcpcd, net-tools)
git clone -b scarthgap git://git.openembedded.org/meta-openembedded

# Inicializa el entorno de build y crea la carpeta build/ con los archivos de configuración por defecto
source oe-init-build-env build
```

---

## Registro de capas en bblayers.conf

`bblayers.conf` le dice a BitBake qué capas forman parte del proyecto. Sin que una capa esté registrada aquí, BitBake no sabe que existe y no puede usar ninguna receta dentro de ella. Se usa `bitbake-layers add-layer` porque valida la compatibilidad de la capa antes de agregarla, evitando errores silenciosos.

```bash
# Recetas de sistema y librerías base; dependencias indirectas de varios paquetes
bitbake-layers add-layer ../meta-openembedded/meta-oe

# Módulos y librerías de Python adicionales (necesarios para el agente de email)
bitbake-layers add-layer ../meta-openembedded/meta-python

# Herramientas de red: dhcpcd, net-tools, iputils
bitbake-layers add-layer ../meta-openembedded/meta-networking

# Soporte de hardware para toda la familia Raspberry Pi
bitbake-layers add-layer ../meta-raspberrypi

# Crea la capa personalizada del proyecto con la estructura mínima requerida
# y la registra en bblayers.conf en un solo paso
bitbake-layers create-layer meta-ai
bitbake-layers add-layer ../build/meta-ai/
```

---

## Preparación de los archivos binarios

Antes de crear los archivos de recetas, hay que preparar los binarios que van dentro de la capa. Estos pasos se ejecutan en el **host** (fuera del contenedor), en una terminal separada.

Hay dos binarios que preparar: el ejecutable de Ollama y el modelo de lenguaje empaquetado.

### Descargar el binario de Ollama

Ollama distribuye binarios precompilados para ARM64. El tgz incluye el ejecutable principal y runners para GPU NVIDIA/AMD que no se usarán en el RPi5.

```bash
# Descarga el binario de Ollama para ARM64
# La versión 0.5.7 es estable y compatible con el RPi5
wget https://github.com/ollama/ollama/releases/download/v0.5.7/ollama-linux-arm64.tgz

# Verifica que el archivo descargó correctamente (debe pesar varios cientos de MB)
ls -lh ollama-linux-arm64.tgz
```

### Descargar y empaquetar el modelo qwen2.5:3b

Se usa `qwen2.5:3b` como modelo de lenguaje. Fue entrenado específicamente para seguir instrucciones estructuradas, lo que lo hace más adecuado que modelos similares en tamaño para tareas como responder correos basándose en un documento de inventario.

```bash
# Instala Ollama en el host para poder descargar el modelo
curl -fsSL https://ollama.com/install.sh | sh

# Descarga qwen2.5:3b (~2 GB)
ollama pull qwen2.5:3b

# Verifica que el modelo quedó disponible
ollama list
# Debe mostrar: qwen2.5:3b con su ID y tamaño

# Empaqueta los pesos del modelo con la estructura de directorios que Ollama espera
# El tar.gz resultante contendrá models/blobs/ y models/manifests/
# que luego se extraen en /root/.ollama/ dentro de la imagen
sudo tar -czvf qwen2.5-3b-prebaked.tar.gz \
    -C /usr/share/ollama/.ollama models
```

### Copiar los binarios a la carpeta de recetas

Una vez creada la estructura de la capa (siguiente sección), copiar ambos archivos dentro de la receta correspondiente.

---

## Estructura de la capa personalizada

Dentro de `meta-ai` van todas las recetas propias del proyecto. Hay que crear los directorios y archivos con esta estructura exacta antes de compilar:

```
meta-ai/
├── conf/
│   └── layer.conf
├── COPYING.MIT
├── README
├── recipes-ai/
│   ├── email-agent/
│   │   ├── email-agent_1.0.bb
│   │   └── files/
│   │       ├── agent.py
│   │       ├── config.env
│   │       ├── email-agent.service
│   │       └── store_info.md
│   └── ollama/
│       ├── ollama_1.0.bb
│       └── files/
│           ├── ollama-linux-arm64.tgz
│           ├── ollama.service
│           └── qwen2.5-3b-prebaked.tar.gz
├── recipes-core/
│   ├── autologin/
│   │   ├── autologin_1.0.bb
│   │   └── files/
│   │       └── autologin.conf
│   ├── images/
│   │   └── core-image-base.bbappend
│   └── show-ip/
│       ├── show-ip_1.0.bb
│       └── files/
│           └── 99-show-ip.sh
└── recipes-example/
    └── example/
        └── example_0.1.bb
```

Crear los directorios que no genera `bitbake-layers create-layer` automáticamente:

```bash
# Desde dentro del contenedor, estando en poky/build/
mkdir -p meta-ai/recipes-ai/ollama/files
mkdir -p meta-ai/recipes-ai/email-agent/files
mkdir -p meta-ai/recipes-core/autologin/files
mkdir -p meta-ai/recipes-core/images
mkdir -p meta-ai/recipes-core/show-ip/files
```

---

## Contenido de los archivos

### `layer.conf`

`layer.conf` es el archivo que define la identidad de la capa ante BitBake. Sin él, BitBake no sabe cómo llamar a la capa, qué recetas contiene, ni con qué otras capas es compatible. `bitbake-layers create-layer` genera una versión base; hay que reemplazarla con esta:

Ubicación: `meta-ai/conf/layer.conf`

```bash
# Agrega esta capa al BBPATH para que BitBake encuentre sus archivos de configuración
BBPATH .= ":${LAYERDIR}"

# Registra todos los archivos .bb y .bbappend dentro de carpetas recipes-*
BBFILES += "${LAYERDIR}/recipes-*/*/*.bb \
            ${LAYERDIR}/recipes-*/*/*.bbappend"

# Nombre único de esta colección de recetas
BBFILE_COLLECTIONS += "meta-ai"

# Patrón que identifica que un archivo pertenece a esta capa
BBFILE_PATTERN_meta-ai = "^${LAYERDIR}/"

# Prioridad 10: si hay conflicto con una receta de otra capa, gana esta
BBFILE_PRIORITY_meta-ai = "10"

# Esta capa requiere que las capas "core" y "raspberrypi" estén presentes
LAYERDEPENDS_meta-ai = "core raspberrypi"

# Declara compatibilidad con Yocto Scarthgap (versión 5.0.x)
LAYERSERIES_COMPAT_meta-ai = "scarthgap"
```

---

### `ollama_1.0.bb`

Esta receta empaqueta Ollama en la imagen. Instala el binario, registra el servicio systemd para que arranque automáticamente, y extrae los pesos del modelo en la ruta donde Ollama los busca.

El tgz de Ollama contiene runners para CUDA (NVIDIA) y ROCm (AMD). El RPi5 no tiene esos GPUs, así que solo se instala el binario principal. En versiones modernas de Ollama la inferencia por CPU está integrada directamente en ese binario.

Ubicación: `meta-ai/recipes-ai/ollama/ollama_1.0.bb`

```bash
SUMMARY = "Ollama local AI model runner con qwen2.5:3b preinstalado"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ollama-linux-arm64.tgz;subdir=ollama-release \
    file://ollama.service \
    file://qwen2.5-3b-prebaked.tar.gz;unpack=0 \
"
# subdir=ollama-release: extrae el tgz en su propia carpeta para no mezclar con otros archivos
# unpack=0 en el modelo: BitBake descomprime .tar.gz automáticamente, pero aquí
# necesitamos hacerlo nosotros para elegir el destino correcto (/root/.ollama/)

S = "${WORKDIR}"

# "inherit systemd" activa el soporte para instalar y habilitar unidades systemd
inherit systemd

SYSTEMD_SERVICE:${PN} = "ollama.service"

# "enable" hace que el servicio arranque en cada boot sin necesidad de correr
# systemctl enable manualmente
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Instala el binario principal en /usr/bin/
    # En versiones modernas de Ollama, la inferencia CPU está dentro de este binario
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

    # lib/ollama/ NO se instala: solo contiene runners CUDA/ROCm que
    # requieren libcuda.so o librocm — librerías que no existen en el RPi5
    # Instalarlos causaría errores de QA (dependencias no satisfechas)

    # Instala el archivo de servicio en el directorio estándar de systemd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/

    # Extrae los pesos del modelo en /root/.ollama/
    # --no-same-owner: descarta el UID/GID original del tar para evitar
    # el error "uid not found" en la fase do_package de BitBake
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/qwen2.5-3b-prebaked.tar.gz \
        -C ${D}/root/.ollama/
}

FILES:${PN} += " \
    ${bindir}/ollama \
    ${systemd_system_unitdir}/ollama.service \
    /root/.ollama/ \
"

# El binario viene precompilado y sin símbolos de debug (stripped)
# Sin esta línea, BitBake lanza un error de QA al detectarlo
INSANE_SKIP:${PN} = "already-stripped"
```

---

### `ollama.service`

El archivo `.service` le dice a systemd cómo arrancar Ollama: con qué usuario, qué variables de entorno necesita y cuándo hacerlo. Las variables `HOME` y `OLLAMA_MODELS` son críticas: cuando Ollama corre como servicio systemd no hereda el entorno del usuario, y sin ellas no encuentra los modelos aunque estén instalados.

Ubicación: `meta-ai/recipes-ai/ollama/files/ollama.service`

```ini
[Unit]
Description=Ollama Service
# Arranca después de que la red esté operativa
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=root

# Ollama busca los modelos en $HOME/.ollama/models
# Un servicio systemd no hereda HOME del usuario, hay que definirlo explícitamente
Environment=HOME=/root

# Ruta explícita a los modelos como refuerzo adicional
Environment=OLLAMA_MODELS=/root/.ollama/models

# Escucha en todas las interfaces: permite consultar la API desde la red local
Environment=OLLAMA_HOST=0.0.0.0:11434

# Sin límite de tiempo para detener: el modelo puede tardar en terminar
TimeoutStopSec=infinity

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

### `autologin_1.0.bb`

Esta receta instala el drop-in de systemd para getty que produce el autologin de root en tty1.

Ubicación: `meta-ai/recipes-core/autologin/autologin_1.0.bb`

```bash
SUMMARY = "Autologin de root en tty1 sin contraseña"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Solo se necesita el drop-in de getty
SRC_URI = "file://autologin.conf"

S = "${WORKDIR}"

do_install() {
    # Crea el directorio para drop-ins del servicio getty@tty1
    install -d ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/
    install -m 0644 ${WORKDIR}/autologin.conf \
        ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf
}

FILES:${PN} = " \
    ${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf \
"
```

---

### `autologin.conf`

Este archivo es un "drop-in" de systemd para el servicio `getty@tty1`. En lugar de modificar la unidad original de getty, systemd lee la carpeta `.service.d/` y aplica los cambios encima. El resultado es que al arrancar la Pi, el login en tty1 ocurre automáticamente con root sin que nadie escriba nada.

Ubicación: `meta-ai/recipes-core/autologin/files/autologin.conf`

```ini
[Service]
# La primera línea en blanco borra el ExecStart original de getty
# Sin esto, systemd acumularía dos comandos de inicio y fallaría
ExecStart=
# --autologin root: hace login automático sin pedir contraseña
# --noclear: no borra los mensajes de boot antes del prompt
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM

# Type=idle: espera a que todos los demás servicios arranquen antes de mostrar
# el prompt, evitando que los mensajes de boot se mezclen con la sesión
Type=idle
```

---

### `show-ip_1.0.bb`

Esta receta empaqueta un script que se ejecuta automáticamente en cada login y muestra las IPs asignadas a las interfaces de red. Es útil porque evita conectar teclado y monitor para saber a qué dirección SSH conectarse.

Ubicación: `meta-ai/recipes-core/show-ip/show-ip_1.0.bb`

```bash
SUMMARY = "Muestra la dirección IP al iniciar sesión"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-show-ip.sh"

S = "${WORKDIR}"

do_install() {
    # Los archivos en /etc/profile.d/ se ejecutan automáticamente en cada login
    # interactivo, tanto en consola física como en SSH
    install -d ${D}${sysconfdir}/profile.d/
    install -m 0755 ${WORKDIR}/99-show-ip.sh \
        ${D}${sysconfdir}/profile.d/99-show-ip.sh
}

FILES:${PN} = "${sysconfdir}/profile.d/99-show-ip.sh"

# iproute2 provee el comando "ip" que usa el script para leer las IPs
RDEPENDS:${PN} = "iproute2"
```

---

### `99-show-ip.sh`

Ubicación: `meta-ai/recipes-core/show-ip/files/99-show-ip.sh`

```bash
#!/bin/sh

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│         Raspberry Pi 5 — Yocto          │"
echo "├─────────────────────────────────────────┤"

found=0

# Itera sobre los nombres de interfaz más comunes en RPi5
# El kernel puede llamar a Ethernet "eth0" o "end0" según la configuración
for iface in eth0 eth1 end0 wlan0; do
    # Extrae solo la IP (sin el prefijo de subred /24) usando awk
    IP=$(ip -4 addr show "$iface" 2>/dev/null \
         | awk '/inet / { split($2, a, "/"); print a[1] }')

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
```

---

### `core-image-base.bbappend`

Un `.bbappend` extiende una receta existente sin modificarla directamente. Este archivo extiende `core-image-base` para agregar los paquetes propios (`autologin`, `show-ip`, `email-agent`) y para realizar dos configuraciones sobre el rootfs después de instalar los paquetes:

1. `configure_sshd`: modifica `/etc/ssh/sshd_config` para permitir login de root sin contraseña. Se hace aquí con `ROOTFS_POSTPROCESS_COMMAND` porque altera un archivo de otro paquete (openssh) — no puede hacerse desde una receta propia.

2. `enable_timesyncd`: crea el symlink de systemd para habilitar el cliente NTP. `systemd-timesyncd` viene dentro del paquete `systemd` pero no está habilitado por defecto en imágenes mínimas de Yocto. Sin esto, la Pi arranca sin sincronizar la hora y los certificados SSL fallan.

Ubicación: `meta-ai/recipes-core/images/core-image-base.bbappend`

```bash
# Agrega los tres paquetes propios a la imagen
IMAGE_INSTALL:append = " autologin show-ip email-agent"

# Ejecuta ambas funciones sobre el rootfs después de instalar paquetes,
# antes de generar la imagen final
ROOTFS_POSTPROCESS_COMMAND:append = " configure_sshd; enable_timesyncd;"

configure_sshd() {
    SSHD_CONFIG="${IMAGE_ROOTFS}/etc/ssh/sshd_config"

    # Si openssh no está instalado por alguna razón, omite sin romper el build
    if [ ! -f "${SSHD_CONFIG}" ]; then
        bbwarn "configure_sshd: ${SSHD_CONFIG} no encontrado, omitiendo."
        return 0
    fi

    # Por defecto OpenSSH bloquea el login de root — esto lo habilita
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'          "${SSHD_CONFIG}"

    # Por defecto OpenSSH rechaza contraseñas vacías — esto lo permite
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' "${SSHD_CONFIG}"

    # PAM con contraseña vacía bloquea el login aunque OpenSSH lo permitiría
    # Desactivar PAM hace que SSH use su propio sistema de autenticación
    sed -i 's/^#*UsePAM.*/UsePAM no/'                             "${SSHD_CONFIG}"

    # Si las directivas no existían en el archivo original, las agrega al final
    grep -q "^PermitRootLogin"      "${SSHD_CONFIG}" || echo "PermitRootLogin yes"      >> "${SSHD_CONFIG}"
    grep -q "^PermitEmptyPasswords" "${SSHD_CONFIG}" || echo "PermitEmptyPasswords yes" >> "${SSHD_CONFIG}"
    grep -q "^UsePAM"               "${SSHD_CONFIG}" || echo "UsePAM no"                >> "${SSHD_CONFIG}"
}

enable_timesyncd() {
    # systemd-timesyncd viene dentro del paquete systemd pero no está habilitado
    # por defecto en imágenes mínimas de Yocto.
    # Este symlink es el equivalente de "systemctl enable systemd-timesyncd"
    # pero aplicado en tiempo de build, sobre el rootfs.
    # Se enlaza en sysinit.target.wants porque timesyncd debe arrancar en la
    # fase de inicialización, antes de que otros servicios lo necesiten.
    WANTS_DIR="${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants"
    UNIT="${IMAGE_ROOTFS}/usr/lib/systemd/system/systemd-timesyncd.service"

    if [ -f "${UNIT}" ]; then
        install -d "${WANTS_DIR}"
        ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
               "${WANTS_DIR}/systemd-timesyncd.service"
        bbdebug 1 "enable_timesyncd: NTP habilitado."
    else
        bbwarn "enable_timesyncd: systemd-timesyncd.service no encontrado."
    fi
}
```

---

### `email-agent_1.0.bb`

Esta receta instala el agente de email: el script Python, el servicio systemd, el documento de información de la tienda y el archivo de configuración con las credenciales.

Los archivos de configuración (`config.env` y `store_info.md`) se instalan como plantillas y se editan en la Pi después del primer arranque vía SSH. Esto es intencional: hornear las credenciales de Gmail en la imagen las dejaría expuestas en el archivo `.wic`.

Ubicación: `meta-ai/recipes-ai/email-agent/email-agent_1.0.bb`

```bash
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
    # Script principal en su propio directorio para no mezclar con binarios del sistema
    install -d ${D}/usr/bin/email-agent/
    install -m 0755 ${WORKDIR}/agent.py ${D}/usr/bin/email-agent/agent.py

    # Servicio systemd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/email-agent.service ${D}${systemd_system_unitdir}/

    # Archivos de configuración en /etc/email-agent/ para editar fácilmente desde SSH
    install -d ${D}${sysconfdir}/email-agent/
    install -m 0640 ${WORKDIR}/config.env    ${D}${sysconfdir}/email-agent/config.env
    install -m 0644 ${WORKDIR}/store_info.md ${D}${sysconfdir}/email-agent/store_info.md
}

FILES:${PN} = " \
    /usr/bin/email-agent/agent.py \
    ${systemd_system_unitdir}/email-agent.service \
    ${sysconfdir}/email-agent/config.env \
    ${sysconfdir}/email-agent/store_info.md \
"

# CONFFILES indica al gestor de paquetes que no sobreescriba estos archivos
# si el paquete se actualiza y el usuario ya los editó en la Pi
CONFFILES:${PN} = " \
    ${sysconfdir}/email-agent/config.env \
    ${sysconfdir}/email-agent/store_info.md \
"

# Dependencias de Python en tiempo de ejecución
# La stdlib de Python (imaplib, smtplib, email, logging) viene con python3
# requests es el único paquete externo necesario (para llamar a la API de Ollama)
RDEPENDS:${PN} = " \
    python3 \
    python3-requests \
    python3-email \
    python3-netclient \
    python3-logging \
    python3-json \
"
```

---

### `email-agent.service`

Ubicación: `meta-ai/recipes-ai/email-agent/files/email-agent.service`

```ini
[Unit]
Description=Email Sales Agent - Asistente de ventas por correo
# Arranca después de que la red esté lista Y después de que Ollama esté corriendo
# Así se garantiza que ambas dependencias están disponibles antes de procesar correos
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/bin/email-agent/agent.py
User=root

# HOME=/root necesario para que Python encuentre archivos de caché del usuario
Environment=HOME=/root

# Si el script termina por cualquier error, systemd lo reinicia automáticamente
Restart=on-failure
RestartSec=30

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

### `agent.py`

El agente es un script Python que corre como servicio. Su flujo es:

1. Espera a que la API de Ollama responda
2. Hace una inferencia de "warmup" para asegurar que el modelo está cargado en RAM
3. Entra en un bucle infinito: cada N segundos revisa la bandeja de Gmail via IMAP
4. Por cada correo no leído, construye un prompt con el inventario de la tienda y el correo del cliente
5. Llama a la API de Ollama y espera la respuesta
6. Envía la respuesta al remitente via SMTP
7. Marca el correo como leído

**Sobre el prompt**: el modelo recibe las reglas de negocio (qué hacer con productos agotados, no inventariar nada, usar precios exactos), la información de la tienda y el correo del cliente.

**Sobre la temperatura**: se usa `temperature=0.1`, el valor mínimo efectivo. Esto minimiza la "creatividad" del modelo y lo obliga a ceñirse al contexto dado, reduciendo la tendencia a inventar productos o precios.

Ubicación: `meta-ai/recipes-ai/email-agent/files/agent.py`

```python
#!/usr/bin/env python3
"""
agent.py — Asistente de ventas automatizado para tienda de electrónica.

Este script corre como servicio systemd en la Raspberry Pi 5.
Su función es monitorear una bandeja de Gmail, leer los correos entrantes,
consultar al modelo de lenguaje (Ollama) para generar una respuesta apropiada
basada en el inventario de la tienda, y enviar esa respuesta al remitente.

Dependencias externas:
    - requests: para llamar a la API REST de Ollama
    - El resto (imaplib, smtplib, email) son parte de la librería estándar de Python
"""

import imaplib       # Protocolo IMAP: permite leer correos de un servidor de email
import smtplib       # Protocolo SMTP: permite enviar correos
import email         # Parseo de mensajes de email (headers, cuerpo, adjuntos)
import time          # Para las pausas entre revisiones de la bandeja
import logging       # Para escribir el log de actividad en /var/log/email-agent.log
import requests      # Para hacer peticiones HTTP a la API de Ollama
from email.mime.text      import MIMEText        # Construye el cuerpo del email de respuesta
from email.mime.multipart import MIMEMultipart   # Construye el email completo (headers + cuerpo)
from email.header         import decode_header   # Decodifica asuntos y remitentes codificados

# Rutas de los archivos de configuración en el sistema de la Pi
CONFIG_FILE     = "/etc/email-agent/config.env"   # Credenciales y parámetros del agente
STORE_INFO_FILE = "/etc/email-agent/store_info.md" # Inventario y datos de la tienda
LOG_FILE        = "/var/log/email-agent.log"        # Archivo de log de actividad


# ─────────────────────────────────────────────────────────────────
# CARGA DE ARCHIVOS DE CONFIGURACIÓN
# ─────────────────────────────────────────────────────────────────

def load_config():
    """
    Lee el archivo config.env y devuelve sus valores como un diccionario.

    El archivo tiene el formato CLAVE=valor, una por línea.
    Las líneas que empiezan con # son comentarios y se ignoran.
    Las líneas vacías también se ignoran.

    Ejemplo de contenido del archivo:
        GMAIL_USER=ventas@tecnopartes.cr
        GMAIL_APP_PASSWORD=abcdabcdabcdabcd
        CHECK_INTERVAL=60
        OLLAMA_MODEL=qwen2.5:3b

    Retorna un dict como:
        {'GMAIL_USER': 'ventas@tecnopartes.cr', 'CHECK_INTERVAL': '60', ...}
    """
    config = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            # Ignorar líneas vacías y comentarios
            if line and not line.startswith('#') and '=' in line:
                # Dividir solo en el primer '=' para manejar valores que contengan '='
                key, val = line.split('=', 1)
                config[key.strip()] = val.strip()
    return config


def load_store_info():
    """
    Lee el archivo store_info.md completo y lo devuelve como una cadena de texto.

    Este archivo contiene el inventario de la tienda, datos de contacto,
    ubicación y horarios. Se lee completo y se inyecta en el prompt del LLM
    para que el modelo tenga el contexto necesario al responder.

    El archivo se lee en cada ciclo del agente (no solo al arrancar), lo que
    permite editar el inventario en la Pi sin necesidad de reiniciar el servicio.
    """
    with open(STORE_INFO_FILE) as f:
        return f.read()


# ─────────────────────────────────────────────────────────────────
# UTILIDADES PARA PROCESAR EMAILS ENTRANTES
# ─────────────────────────────────────────────────────────────────

def decode_str(s):
    """
    Decodifica el campo 'From' o 'Subject' de un email a texto plano.

    Los emails pueden codificar estos campos usando base64 o quoted-printable
    cuando contienen caracteres especiales (tildes, ñ, etc.).
    Por ejemplo, el asunto "Compra de componentes" podría llegar como:
        =?UTF-8?Q?Compra_de_componentes?=

    Esta función detecta ese encoding y lo convierte a texto legible.
    Si el campo ya es texto plano, lo devuelve sin cambios.
    """
    decoded_parts = decode_header(s)
    parts = []
    for part, enc in decoded_parts:
        if isinstance(part, bytes):
            # El fragmento está codificado — decodificarlo con el charset indicado
            parts.append(part.decode(enc or 'utf-8', errors='replace'))
        else:
            # El fragmento ya es texto plano
            parts.append(part)
    return ''.join(parts)


def get_email_body(msg):
    """
    Extrae el cuerpo en texto plano de un mensaje de email.

    Los emails modernos pueden tener múltiples partes (multipart):
    una versión en texto plano y otra en HTML. Este agente solo necesita
    el texto plano para enviarlo al LLM.

    Si el email es simple (no multipart), extrae el contenido directamente.
    Si es multipart, itera sobre las partes hasta encontrar 'text/plain'.

    En ambos casos, detecta el charset del mensaje (UTF-8, ISO-8859-1, etc.)
    para decodificar correctamente los bytes a texto.

    Devuelve el cuerpo como string, o cadena vacía si no se puede extraer.
    """
    if msg.is_multipart():
        # Iterar sobre todas las partes del mensaje
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
    Extrae únicamente la dirección de email del campo 'From'.

    El campo From puede venir en dos formatos:
        1. Solo dirección:   gabo@gmail.com
        2. Nombre + ángulos: Gabriel Pérez <gabo@gmail.com>

    Esta función detecta el formato y devuelve siempre solo la dirección,
    que es lo que se necesita para enviar la respuesta.
    """
    if '<' in from_header and '>' in from_header:
        # Formato "Nombre <email>" — extraer lo que está entre < y >
        return from_header.split('<')[1].split('>')[0].strip()
    # Formato solo dirección — devolver directamente
    return from_header.strip()


# ─────────────────────────────────────────────────────────────────
# CONSTRUCCIÓN DEL PROMPT Y CONSULTA AL LLM
# ─────────────────────────────────────────────────────────────────

def build_prompt(store_info, personality, subject, body):
    """
    Construye el texto completo que se envía al modelo de lenguaje (LLM).

    El prompt tiene cuatro partes:
        1. Definición del rol del asistente
        2. La información de la tienda (inventario, sucursal, horarios)
        3. Las reglas de comportamiento
        4. El correo del cliente y la instrucción de respuesta

    Por qué el inventario va antes de las reglas:
        El modelo lee el prompt de arriba a abajo. Si el inventario va primero,
        el modelo lo tiene en contexto cuando lee las reglas. Si las reglas
        fueran primero, el modelo podría "olvidarlas" al leer 50 líneas de inventario.

    Por qué se trunca el cuerpo del correo a 600 caracteres:
        Los modelos pequeños como qwen2.5:3b tienen un límite de contexto.
        Un cuerpo de email muy largo consumiría tokens que se necesitan para
        el inventario y las reglas. En la práctica, los correos de clientes
        son cortos y 600 caracteres son más que suficientes.

    La variable 'personality' viene del archivo config.env y permite cambiar
    el tono del asistente sin modificar el código.
    """
    # Limitar el cuerpo del correo para no desperdiciar espacio de contexto
    body_truncated = body.strip()[:600]

    return f"""Eres un vendedor de TecnoPartes S.A. Responde el email del cliente usando solo la información de la lista de abajo.

LISTA DE LA TIENDA:
{store_info}

REGLAS:
1. Para cada producto que pida el cliente, busca su nombre en la lista de arriba.
2. Si dice DISPONIBLE: confirma que está disponible y da el precio exacto de la lista.
3. Si dice AGOTADO: indica que está agotado. No inventes precio ni fecha.
4. Si el producto no está en la lista: indica que no lo manejamos. No lo inventes.
5. Si piden varias unidades de algo DISPONIBLE: multiplica el precio por la cantidad.
6. Para ubicación y horarios: usa solo lo que dice la lista. No inventes direcciones.
7. Escribe la respuesta como un email normal. No copies el formato de la lista.

EMAIL DEL CLIENTE:
Asunto: {subject}
Mensaje: {body_truncated}

{personality}
Respuesta:"""


def query_ollama(prompt, model, ollama_url, logger):
    """
    Envía el prompt a la API de Ollama y espera la respuesta completa del LLM.

    Ollama expone una API REST en el puerto 11434. El endpoint /api/generate
    acepta un prompt y devuelve el texto generado por el modelo.

    Parámetros importantes de la petición:
        stream=False:
            Con True, Ollama devuelve tokens uno a uno (streaming).
            Con False, espera a generar toda la respuesta antes de devolverla.
            Se usa False porque es más simple de manejar en este contexto.

        temperature=0.1:
            Controla cuánta "creatividad" tiene el modelo al generar texto.
            0.0 = completamente determinista (siempre la misma respuesta).
            1.0 = muy creativo, más propenso a inventar información.
            0.1 es el valor mínimo efectivo: el modelo es casi determinista,
            lo que reduce drásticamente la tendencia a inventar datos.

        num_predict=1200:
            Límite máximo de tokens (palabras/fragmentos) en la respuesta.
            Con 600 era insuficiente para responder preguntas múltiples
            (productos + ubicación + horarios). Con 1200 hay margen suficiente.

        timeout=600:
            10 minutos de espera máxima. qwen2.5:3b en CPU puede tardar
            entre 5 y 9 minutos por respuesta según la longitud del prompt.
    """
    url = f"{ollama_url}/api/generate"
    payload = {
        "model":  model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": 1200,
            "temperature": 0.1
        }
    }

    logger.info(f"Enviando prompt a Ollama ({len(prompt)} chars)...")
    start    = time.time()
    response = requests.post(url, json=payload, timeout=600)
    response.raise_for_status()  # Lanza excepción si Ollama devuelve error HTTP

    elapsed = time.time() - start
    result  = response.json()["response"].strip()
    logger.info(f"Respuesta recibida en {elapsed:.1f}s — {len(result)} chars")
    return result


# ─────────────────────────────────────────────────────────────────
# INICIALIZACIÓN Y WARMUP DE OLLAMA
# ─────────────────────────────────────────────────────────────────

def warmup_ollama(model, ollama_url, logger):
    """
    Hace una inferencia pequeña para confirmar que el modelo está cargado en RAM.

    Por qué es necesario:
        El agente y Ollama arrancan al mismo tiempo con systemd.
        Ollama puede tardar 30-60 segundos en cargar el modelo en RAM después
        de que su API ya responde. Si el agente hace una solicitud real antes
        de que el modelo esté listo, la inferencia queda colgada silenciosamente
        o falla sin un error claro.

        El warmup resuelve esto enviando un prompt trivial ("Di solo: OK")
        que fuerza al modelo a cargarse completamente. Una vez que el warmup
        termina, el modelo está listo para procesar correos reales.
    """
    logger.info("Calentando el modelo con inferencia de prueba...")
    url     = f"{ollama_url}/api/generate"
    payload = {
        "model":   model,
        "prompt":  "Di solo: OK",
        "stream":  False,
        "options": {"num_predict": 5}
    }
    try:
        start    = time.time()
        response = requests.post(url, json=payload, timeout=180)
        response.raise_for_status()
        logger.info(f"Warmup completado en {time.time()-start:.1f}s. Modelo listo.")
        return True
    except Exception as e:
        logger.error(f"Warmup falló: {e}")
        return False


def wait_for_ollama(ollama_url, logger, retries=15, delay=20):
    """
    Espera a que la API de Ollama esté respondiendo antes de continuar.

    Consulta el endpoint /api/tags que devuelve la lista de modelos instalados.
    Si responde con HTTP 200, Ollama está activo.

    Reintenta hasta 'retries' veces con 'delay' segundos entre cada intento.
    Si después de todos los intentos Ollama no responde, el agente aborta.

    Por qué esperar:
        El servicio email-agent.service tiene 'Requires=ollama.service' en
        su archivo de unidad, lo que garantiza que systemd arranca Ollama primero.
        Sin embargo, "arrancado" no significa "listo para inferencia". Esta función
        completa esa espera de forma activa.
    """
    for i in range(retries):
        try:
            r = requests.get(f"{ollama_url}/api/tags", timeout=5)
            if r.status_code == 200:
                logger.info("API de Ollama responde correctamente.")
                return True
        except Exception:
            pass
        logger.info(f"Esperando Ollama... intento {i+1}/{retries}")
        time.sleep(delay)
    logger.error("Ollama no respondió después de todos los intentos.")
    return False


# ─────────────────────────────────────────────────────────────────
# ENVÍO DE RESPUESTA POR CORREO
# ─────────────────────────────────────────────────────────────────

def send_reply(config, to_address, subject, body, logger):
    """
    Envía la respuesta generada por el LLM al remitente via Gmail SMTP.

    Protocolo utilizado: SMTP sobre SSL en el puerto 465.
        - SMTP_SSL establece la conexión cifrada desde el inicio.
        - Puerto 465 es el estándar para SMTP con SSL implícito.
        - Se usa la App Password de Google (no la contraseña normal),
          porque IMAP/SMTP con 2FA requiere esta contraseña especial.

    El asunto de la respuesta:
        Si el asunto original es "Consulta de stock", la respuesta lleva
        "Re: Consulta de stock". Si ya empieza con "Re:", no se duplica.

    Manejo de errores:
        SMTPAuthenticationError se captura por separado porque indica un
        problema de credenciales (App Password incorrecta), que es diferente
        a un error de red o de envío. Se loguea con un mensaje específico
        para facilitar el diagnóstico.
    """
    # Agregar "Re: " al asunto si no lo tiene ya
    reply_subject = subject if subject.startswith("Re:") else f"Re: {subject}"

    # Construir el mensaje de email con sus headers
    msg = MIMEMultipart()
    msg['From']    = config['GMAIL_USER']
    msg['To']      = to_address
    msg['Subject'] = reply_subject
    # utf-8 asegura que las tildes y la ñ se envíen correctamente
    msg.attach(MIMEText(body, 'plain', 'utf-8'))

    logger.info(f"Enviando respuesta a {to_address}...")
    try:
        # Abrir conexión SSL con Gmail SMTP y enviar
        with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=30) as server:
            server.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
            server.send_message(msg)
            logger.info("Correo enviado correctamente.")
    except smtplib.SMTPAuthenticationError as e:
        logger.error(f"Error de autenticación SMTP: {e}")
        logger.error("Verificar GMAIL_USER y GMAIL_APP_PASSWORD en config.env")
        raise
    except Exception as e:
        logger.error(f"Error al enviar correo: {type(e).__name__}: {e}")
        raise


# ─────────────────────────────────────────────────────────────────
# CICLO PRINCIPAL DE PROCESAMIENTO DE CORREOS
# ─────────────────────────────────────────────────────────────────

def process_unread_emails(config, store_info, logger):
    """
    Conecta a Gmail via IMAP, procesa todos los correos no leídos y responde a cada uno.

    Flujo completo para cada correo:
        1. Conectar a Gmail usando IMAP sobre SSL (puerto 993)
        2. Autenticar con la App Password de Google
        3. Seleccionar la bandeja de entrada (inbox)
        4. Buscar correos con flag UNSEEN (no leídos)
        5. Por cada correo no leído:
            a. Descargarlo completo (headers + cuerpo)
            b. Extraer remitente, asunto y cuerpo en texto plano
            c. Construir el prompt con el inventario de la tienda
            d. Enviar el prompt a Ollama y esperar la respuesta del LLM
            e. Enviar la respuesta al remitente via SMTP
            f. Marcar el correo como leído (flag \\Seen)
        6. Cerrar la conexión IMAP

    Por qué marcar como leído aunque haya error:
        Si un correo falla al procesarse, se marca como leído igualmente.
        Esto evita un bucle infinito donde el mismo correo fallido se
        reintenta en cada ciclo. Si se necesita reintentar un correo,
        se puede marcar manualmente como no leído en Gmail.

    Por qué leer store_info fuera de esta función:
        store_info se lee en cada ciclo del bucle principal de main(),
        no aquí. Esto permite que los cambios en el inventario (editando
        store_info.md en la Pi) tomen efecto sin reiniciar el servicio.
    """
    ollama_url  = config.get('OLLAMA_URL', 'http://localhost:11434')
    model       = config.get('OLLAMA_MODEL', 'qwen2.5:3b')
    personality = config.get('PERSONALITY', 'Firma como "Equipo de Ventas - TecnoPartes S.A."')

    logger.info("Conectando a Gmail IMAP...")
    try:
        # IMAP4_SSL usa el puerto 993 con TLS desde el inicio
        mail = imaplib.IMAP4_SSL('imap.gmail.com', timeout=30)
    except Exception as e:
        logger.error(f"No se pudo conectar a Gmail: {type(e).__name__}: {e}")
        return

    try:
        mail.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        logger.info("Autenticación IMAP exitosa.")
    except imaplib.IMAP4.error as e:
        logger.error(f"Error de autenticación IMAP: {e}")
        logger.error("Verificar credenciales en /etc/email-agent/config.env")
        mail.logout()
        return

    # Seleccionar la bandeja de entrada
    mail.select('inbox')

    # Buscar correos no leídos (UNSEEN = sin el flag \Seen)
    status, messages = mail.search(None, 'UNSEEN')
    if status != 'OK' or not messages[0]:
        logger.info("Sin correos nuevos.")
        mail.logout()
        return

    email_ids = messages[0].split()
    logger.info(f"Correos no leídos encontrados: {len(email_ids)}")

    for email_id in email_ids:
        try:
            # RFC822 descarga el mensaje completo incluyendo todos los headers
            status, data = mail.fetch(email_id, '(RFC822)')
            if status != 'OK':
                logger.error(f"No se pudo descargar el correo {email_id}")
                continue

            # Parsear el mensaje de bytes a objeto email de Python
            raw_email = data[0][1]
            msg       = email.message_from_bytes(raw_email)

            sender  = msg.get('From', '')
            subject = decode_str(msg.get('Subject', '(Sin asunto)'))
            body    = get_email_body(msg)

            sender_address = extract_sender_address(sender)
            logger.info(f"--- De: {sender_address} | Asunto: {subject}")
            logger.info(f"    Longitud del cuerpo: {len(body)} caracteres")

            # Paso 1: construir prompt y consultar al LLM
            prompt     = build_prompt(store_info, personality, subject, body)
            reply_text = query_ollama(prompt, model, ollama_url, logger)

            # Paso 2: enviar la respuesta al remitente
            send_reply(config, sender_address, subject, reply_text, logger)

            # Paso 3: marcar como leído para no procesarlo en el próximo ciclo
            mail.store(email_id, '+FLAGS', '\\Seen')
            logger.info(f"Correo {email_id} marcado como leído.")

        except Exception as e:
            logger.error(f"Error procesando correo {email_id}: {type(e).__name__}: {e}")
            # Marcar como leído para evitar bucles de reintento infinito
            try:
                mail.store(email_id, '+FLAGS', '\\Seen')
                logger.info(f"Correo {email_id} marcado como leído (tras error).")
            except Exception:
                pass

    mail.logout()
    logger.info("Sesión IMAP cerrada.")


# ─────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA PRINCIPAL
# ─────────────────────────────────────────────────────────────────

def main():
    """
    Punto de entrada del script. Configura el logging y arranca el bucle principal.

    Secuencia de arranque:
        1. Configurar el sistema de logging (archivo + formato de timestamp)
        2. Cargar la configuración desde config.env
        3. Esperar a que la API de Ollama responda (wait_for_ollama)
        4. Hacer el warmup del modelo (cargar en RAM)
        5. Entrar al bucle infinito: revisar correos cada CHECK_INTERVAL segundos

    El bucle principal:
        En cada iteración se lee store_info.md fresco del disco. Esto permite
        actualizar el inventario de la tienda sin reiniciar el agente: basta con
        editar el archivo en la Pi y el cambio toma efecto en el siguiente ciclo.

    Manejo de errores en el bucle:
        Si una iteración completa falla (por ejemplo, pérdida de conexión de red),
        el error se loguea y el bucle continúa en el siguiente ciclo. El agente
        nunca se detiene por un error puntual.
    """
    # Configurar logging: escribe en archivo con timestamp en cada línea
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s'
    )
    logger = logging.getLogger(__name__)
    logger.info("=== Email agent iniciado ===")

    # Cargar configuración (credenciales, modelo, intervalo de revisión)
    config         = load_config()
    check_interval = int(config.get('CHECK_INTERVAL', '60'))
    ollama_url     = config.get('OLLAMA_URL', 'http://localhost:11434')
    model          = config.get('OLLAMA_MODEL', 'qwen2.5:3b')

    # Esperar a que Ollama esté disponible antes de procesar correos
    if not wait_for_ollama(ollama_url, logger):
        logger.error("Abortando: Ollama no disponible.")
        return

    # Calentar el modelo para asegurar que está cargado en RAM
    if not warmup_ollama(model, ollama_url, logger):
        logger.warning("Warmup falló — el primer correo puede tardar más de lo normal.")

    logger.info(f"Agente listo. Revisando bandeja cada {check_interval} segundos.")

    # Bucle principal: corre indefinidamente hasta que el proceso se detenga
    while True:
        try:
            # Leer el inventario fresco en cada ciclo para reflejar cambios
            store_info = load_store_info()
            process_unread_emails(config, store_info, logger)
        except Exception as e:
            logger.error(f"Error en ciclo principal: {type(e).__name__}: {e}")

        # Esperar antes del próximo ciclo de revisión
        time.sleep(check_interval)


# El bloque if __name__ == '__main__' asegura que main() solo se ejecute
# cuando el script se corre directamente, no cuando se importa como módulo
if __name__ == '__main__':
    main()

```

---

### `config.env`

Archivo de configuración del agente. Se instala como plantilla y se edita en la Pi después del primer arranque. **No debe hornear las credenciales en la imagen.**

Ubicación: `meta-ai/recipes-ai/email-agent/files/config.env`

```bash
# Dirección de Gmail que usará la Pi para leer correos y responder
GMAIL_USER=tu_correo@gmail.com

# App Password de Google — NO es la contraseña normal de la cuenta
# Ver sección "Configuración de Gmail" para saber cómo generarla
GMAIL_APP_PASSWORD=xxxx xxxx xxxx xxxx

# Cada cuántos segundos revisa la bandeja de entrada
CHECK_INTERVAL=60

# Modelo de Ollama instalado en la imagen
OLLAMA_MODEL=qwen2.5:3b

# URL de la API de Ollama (no cambiar)
OLLAMA_URL=http://localhost:11434

# Instrucción de estilo que se inyecta al final del prompt
# Define el tono y la firma de las respuestas
# Mantenerlo corto: una o dos oraciones máximo
PERSONALITY=Responde de forma profesional y amigable. Firma como "Equipo de Ventas - TecnoPartes S.A."
```

---

### `store_info.md`

Este documento es la base de conocimiento del asistente. El agente lo lee completo y lo inyecta en el prompt junto con el correo del cliente. El modelo responde basándose exclusivamente en este contenido — no tiene acceso a internet ni a ninguna otra fuente.

El documento puede editarse en la Pi después del arranque sin recompilar la imagen.

Ubicación: `meta-ai/recipes-ai/email-agent/files/store_info.md`

```markdown
# TecnoPartes S.A.

Teléfono: +506 2234-5678
WhatsApp: +506 8765-4321
Correo: ventas@tecnopartes.cr

SUCURSAL:
Dirección: De la Rotonda de la Hispanidad, 200 metros al este, local 4B, San Pedro de Montes de Oca, San José
Horario: Lunes a viernes 8:00 AM - 6:30 PM | Sábados 9:00 AM - 3:00 PM | Domingos cerrado

INVENTARIO:
- Resistencia 220Ω 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 1kΩ 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 10kΩ 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 100Ω 2W ±5%: AGOTADO
- Resistencia 1kΩ 2W ±5%: DISPONIBLE, $0.25 por unidad
- Condensador cerámico 10nF 50V: DISPONIBLE, $0.09 por unidad
- Condensador cerámico 100nF 50V: DISPONIBLE, $0.09 por unidad
- Condensador electrolítico 10µF 25V: DISPONIBLE, $0.21 por unidad
- Condensador electrolítico 100µF 25V: DISPONIBLE, $0.29 por unidad
- Condensador electrolítico 470µF 35V: DISPONIBLE, $0.38 por unidad
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
- Regulador de voltaje LM7812 12V: DISPONIBLE, $0.81 por unidad
- Regulador ajustable LM317: DISPONIBLE, $0.96 por unidad
- Driver de motores L293D: DISPONIBLE, $2.79 por unidad
- Arduino Uno R3: DISPONIBLE, $12.00 por unidad
- Arduino Nano: DISPONIBLE, $8.27 por unidad
- Arduino Mega 2560: DISPONIBLE, $18.27 por unidad
- ESP32 DevKit V1: DISPONIBLE, $10.19 por unidad
- ESP8266 NodeMCU: DISPONIBLE, $6.54 por unidad
- Raspberry Pi Pico: DISPONIBLE, $9.23 por unidad
- Módulo Bluetooth HC-05: DISPONIBLE, $6.15 por unidad
- Módulo GPS NEO-6M: AGOTADO
- Sensor DHT22 temperatura y humedad: DISPONIBLE, $4.62 por unidad
- Sensor DHT11 temperatura y humedad: DISPONIBLE, $2.31 por unidad
- Sensor ultrasonido HC-SR04: DISPONIBLE, $3.37 por unidad
- Sensor PIR HC-SR501: DISPONIBLE, $4.04 por unidad
- LED rojo 5mm: DISPONIBLE, $0.05 por unidad
- LED verde 5mm: DISPONIBLE, $0.05 por unidad
- LED azul 5mm: DISPONIBLE, $0.09 por unidad
- LED RGB 5mm cátodo común: DISPONIBLE, $0.27 por unidad
- Pantalla OLED 0.96in I2C: DISPONIBLE, $5.96 por unidad
- Pantalla LCD 16x2 con I2C: DISPONIBLE, $8.08 por unidad
- Módulo relay 1 canal: DISPONIBLE, $2.79 por unidad
- Módulo relay 4 canales: AGOTADO
- Servomotor SG90: DISPONIBLE, $4.23 por unidad
- Motor paso a paso 28BYJ-48 con driver: DISPONIBLE, $6.54 por unidad
- Protoboard 830 puntos: DISPONIBLE, $4.62 por unidad
- Cables dupont M-M 40 unidades: DISPONIBLE, $2.21 por paquete
- Cables dupont M-F 40 unidades: DISPONIBLE, $2.21 por paquete
- Estaño 60/40 rollo 100g: DISPONIBLE, $5.19 por rollo
- Soldador 30W: DISPONIBLE, $15.77 por unidad
- Multímetro digital: DISPONIBLE, $17.69 por unidad
```

---

### `local.conf`

`local.conf` es el archivo de configuración central del build. Define la máquina objetivo, los paquetes a instalar, y parámetros del sistema.

Ubicación: `poky/build/conf/local.conf`

```bash
# ================================================================
#  local.conf — Yocto Scarthgap | Raspberry Pi 5 | Solo consola
# ================================================================

# ----------------------------------------------------------------
# 1. MÁQUINA Y DISTRIBUCIÓN
# ----------------------------------------------------------------
# raspberrypi5: activa el BSP del RPi5 (kernel, firmware, device tree)
MACHINE = "raspberrypi5"
DISTRO = "poky"
PACKAGE_CLASSES = "package_ipk"

# ----------------------------------------------------------------
# 2. SISTEMA DE INIT: systemd
# ----------------------------------------------------------------
# Reemplaza SysVinit por systemd, necesario para manejar servicios
# como ollama.service y el autologin por drop-in de getty
DISTRO_FEATURES:append = " systemd"

# usrmerge es requerido por systemd en Scarthgap para proveer udev
# Sin esta línea: el build falla con "Nothing PROVIDES udev"
DISTRO_FEATURES:append = " usrmerge"

VIRTUAL-RUNTIME_init_manager = "systemd"
DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"

# ----------------------------------------------------------------
# 3. ZONA HORARIA
# ----------------------------------------------------------------
# Variable nativa de Yocto: instala tzdata y crea /etc/localtime
# apuntando a America/Costa_Rica durante la construcción del rootfs.
# Sin esto, la imagen arranca en UTC y los certificados SSL pueden
# fallar si el reloj no se sincroniza a tiempo.
DEFAULT_TIMEZONE = "America/Costa_Rica"

# ----------------------------------------------------------------
# 4. HARDWARE — RASPBERRY PI
# ----------------------------------------------------------------
RPI_USE_U_BOOT = "0"
ENABLE_UART = "1"
ENABLE_SPI_BUS = "1"
ENABLE_I2C = "1"

# ----------------------------------------------------------------
# 5. IMAGE FEATURES
# ----------------------------------------------------------------
EXTRA_IMAGE_FEATURES += " \
    empty-root-password \
    ssh-server-openssh \
    allow-empty-password \
"

# ----------------------------------------------------------------
# 6. PAQUETES — RED Y CONECTIVIDAD
# ----------------------------------------------------------------
IMAGE_INSTALL:append = " \
    dhcpcd \
    iproute2 \
    iputils \
    net-tools \
"

# ----------------------------------------------------------------
# 7. PAQUETES — TIEMPO Y ZONA HORARIA
# ----------------------------------------------------------------
# tzdata: base de datos de zonas horarias requerida por DEFAULT_TIMEZONE
# systemd-timesyncd viene dentro del paquete systemd y se habilita
# desde core-image-base.bbappend, no se instala como paquete separado
IMAGE_INSTALL:append = " tzdata"

# ----------------------------------------------------------------
# 8. PAQUETES — UTILITARIOS
# ----------------------------------------------------------------
IMAGE_INSTALL:append = " \
    bash \
    vim \
    htop \
    procps \
    coreutils \
"

# ----------------------------------------------------------------
# 9. PAQUETES — OLLAMA Y LLM
# ----------------------------------------------------------------
IMAGE_INSTALL:append = " ollama ca-certificates libstdc++ libgcc libgomp numactl"

# ----------------------------------------------------------------
# 10. ALMACENAMIENTO Y LICENCIAS
# ----------------------------------------------------------------
# wic.bz2: imagen de disco completa comprimida, lista para grabar en SD
IMAGE_FSTYPES = "wic.bz2"

# qwen2.5:3b ocupa ~2 GB; con 8 GB extra hay margen holgado
# Unidad: KB. 8388608 KB = 8 GB
IMAGE_ROOTFS_EXTRA_SPACE = "8388608"

LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch commercial"

# ----------------------------------------------------------------
# 11. RENDIMIENTO DE COMPILACIÓN
# ----------------------------------------------------------------
# Ajustar según los núcleos disponibles en el host de compilación
BB_NUMBER_PARSE_THREADS = "2"
BB_NUMBER_THREADS = "4"
PARALLEL_MAKE = "-j 4"

# ----------------------------------------------------------------
# 12. DIRECTORIOS DE CACHÉ
# ----------------------------------------------------------------
DL_DIR ?= "${TOPDIR}/../downloads"
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache"
TMPDIR = "${TOPDIR}/tmp"

CONF_VERSION = "2"

# ----------------------------------------------------------------
# 13. FIXES DE BUILD
# ----------------------------------------------------------------
# Desactiva la generación de manifiestos SPDX (licencias)
# Causan colisiones de sstate cuando se cambian DISTRO_FEATURES entre builds
INHERIT:remove = "create-spdx"
```

---

## Compilación de la imagen

Con todos los archivos en su lugar y los binarios en sus carpetas `files/`, compilar la imagen.

```bash
# Desde dentro del contenedor Docker
source oe-init-build-env build

bitbake core-image-base
```

La primera vez tarda entre 4 y 6 horas porque compila el toolchain y todos los paquetes desde código fuente. Las compilaciones posteriores son mucho más rápidas gracias al sstate-cache.

Si el build falla, el error más común es de caché desactualizada. Se resuelve limpiando el paquete que falla:

```bash
# Reemplazar "nombre-receta" con el paquete que aparece en el error
bitbake -c cleansstate nombre-receta
bitbake core-image-base
```

---

## Ubicación de la imagen generada

Al terminar sin errores, la imagen aparece en:

```
poky/build/tmp/deploy/images/raspberrypi5/
└── core-image-base-raspberrypi5.rootfs-YYYYMMDDHHMMSS.wic.bz2
```

Copiarla fuera del contenedor antes de continuar. Si la carpeta del proyecto está montada como volumen, ya es accesible desde el host directamente.

---

## Flasheo de la tarjeta SD

Descomprimir la imagen antes de flashear:

```bash
# El nombre exacto varía según la fecha del build
bzip2 -d -v core-image-base-raspberrypi5.rootfs-YYYYMMDDHHMMSS.wic.bz2
```

Esto genera un archivo `.wic` que se selecciona en balenaEtcher junto con la tarjeta SD como destino.

---

## Primer arranque y conexión SSH

Conectar la Pi al router por cable Ethernet y encenderla. La imagen hace todo automáticamente: autologin al arrancar, obtener IP por DHCP, sincronizar el reloj con NTP y arrancar los servicios (sshd, ollama, email-agent).

Para obtener la dirección IP de manera sencilla, se debe ejecutar este comando directamente en la pi, estando esta conectada a un monitor:

```bash
ip a
```

Al encender, aparece en consola el banner con la IP asignada. El mismo banner aparece en cada login por SSH:

```bash
# Conectarse usando la IP que muestra el banner
ssh root@<IP_DE_LA_PI>

# La primera vez acepta la llave del servidor
yes
```

---

## Configuración de Gmail para el agente

El agente usa IMAP y SMTP para leer y enviar correos. Requiere una "App Password" de Google — no la contraseña normal de la cuenta. Esto es así porque IMAP no soporta autenticación de dos factores y Google bloquea el acceso con la contraseña regular cuando 2FA está activo.

### Pasos para generar la App Password

1. Ir a [myaccount.google.com](https://myaccount.google.com)
2. Seguridad → Verificación en dos pasos (activarla si no está activa)
3. Bajar hasta "Contraseñas de aplicaciones"
4. Crear una nueva → tipo "Correo", dispositivo "Otro" → ponerle nombre "Pi5 Agente"
5. Google genera una clave de 16 caracteres como `abcd efgh ijkl mnop` — guardarla

### Habilitar IMAP en Gmail

Actualmente, IMAP está siempre activo en Gmail.

---

## Configuración del agente en la Pi

Una vez conectado por SSH, editar las credenciales y el inventario:

```bash
# Editar las credenciales de Gmail
vim /etc/email-agent/config.env
```

Cambiar los valores de `GMAIL_USER` y `GMAIL_APP_PASSWORD` con los datos reales. La App Password va sin espacios.

```bash
# Editar el inventario y datos de la tienda
# Este archivo es la base de conocimiento del asistente
# El modelo responde basándose SOLO en lo que está aquí
vim /etc/email-agent/store_info.md
```

Reiniciar el agente para que tome los cambios:

```bash
systemctl restart email-agent
```

Verificar que está funcionando:

```bash
# Ver el estado del servicio
systemctl status email-agent

# Ver el log en tiempo real (Ctrl+C para salir)
tail -f /var/log/email-agent.log
```

El log debe mostrar líneas como:

```
=== Email agent iniciado ===
API de Ollama responde.
Calentando el modelo...
Warmup completado en 45.2s.
Agente listo. Revisando bandeja cada 60 segundos.
Conectando a Gmail IMAP...
Autenticación IMAP exitosa.
Sin correos nuevos.
```

---

## Uso del LLM directamente

Además del agente de email, se puede interactuar con el modelo directamente desde la consola:

```bash
# Verifica que el modelo está instalado
ollama list
# Debe mostrar: qwen2.5:3b

# Enviar un prompt directo
ollama run qwen2.5:3b "¿Qué es un transistor?"

# Chat interactivo (salir con /bye)
ollama run qwen2.5:3b
```

---

## Cambiar la personalidad del agente

La variable `PERSONALITY` en `config.env` define el tono del asistente. Se puede cambiar sin recompilar la imagen:

```bash
vim /etc/email-agent/config.env
# Modificar la línea PERSONALITY=
systemctl restart email-agent
```

Ejemplos:

```bash
# Formal
PERSONALITY=Trata al cliente de "usted". Sé preciso y conciso. Firma como "Departamento de Ventas, TecnoPartes S.A."

# Informal
PERSONALITY=Responde de manera amigable usando "usted". Firma como "El equipo de TecnoPartes"

# Técnico
PERSONALITY=Incluye especificaciones técnicas cuando las menciones. Firma como "Asesor Técnico — TecnoPartes S.A."
```

---

## Troubleshooting

### Error de llave SSH al reconectar

Si se flashea una imagen nueva a la misma Pi, SSH rechaza la conexión porque la llave del servidor cambió:

```bash
# En el host, eliminar la llave antigua
ssh-keygen -f '/home/usuario/.ssh/known_hosts' -R '<IP_DE_LA_PI>'
```

---

### SSH aparece como inactivo

```bash
systemctl status sshd
systemctl start sshd

# Para que persista entre reinicios
systemctl enable sshd
```

---

### La Pi no obtiene IP

```bash
systemctl status dhcpcd
systemctl start dhcpcd
sleep 5
ip addr show eth0
```

---

### Error de autenticación IMAP o SMTP

Si el log muestra errores de autenticación:

```bash
# Verificar que las credenciales están bien escritas
cat /etc/email-agent/config.env

# Verificar que IMAP está habilitado en Gmail:
# Gmail → Configuración → Ver toda la configuración → Reenvío e IMAP/POP
# Habilitar IMAP → Guardar cambios
```

---

### El reloj de la Pi está incorrecto

```bash
timedatectl status
# Debe mostrar: System clock synchronized: yes

# Si NTP no está activo
timedatectl set-ntp true
systemctl restart systemd-timesyncd
sleep 10
timedatectl status

# Verificar la zona horaria
timedatectl | grep "Time zone"
# Debe mostrar: America/Costa_Rica (CST, -0600)
```