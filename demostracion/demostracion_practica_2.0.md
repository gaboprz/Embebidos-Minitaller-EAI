# Demostración práctica

Se usa una Raspberry Pi 5 de 8 GB de RAM. Se crea una imagen personalizada usando Yocto Scarthgap dentro de un contenedor Docker. La imagen incluye una interfaz gráfica, acceso por SSH sin contraseña, autologin al encender, y una receta de Ollama con un modelo LLM preinstalado y listo para correr.

---

## Creación del contenedor Docker

Yocto requiere una cantidad considerable de dependencias del sistema. Para no instalarlas directamente en el host y garantizar un entorno reproducible, todo el trabajo de compilación se hace dentro de un contenedor Docker basado en Ubuntu 22.04.

Con Docker instalado, se crea una carpeta para el proyecto y dentro de ella se crea el Dockerfile:

```bash
touch Dockerfile
```

Con el siguiente contenido:

```dockerfile
FROM ubuntu:22.04

# Evita que apt lance preguntas interactivas durante la instalación de paquetes
ENV DEBIAN_FRONTEND=noninteractive

# Todas las dependencias que Yocto necesita para compilar:
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

# Yocto no puede correr como root, por eso se crea un usuario normal
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

Desde la misma carpeta donde está el Dockerfile, se construye y arranca el contenedor:

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
# -v monta la carpeta local dentro del contenedor para que
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
# Poky es el núcleo de Yocto: BitBake, recetas base y toolchain
git clone -b scarthgap git://git.yoctoproject.org/poky.git

cd poky

# Soporte específico para Raspberry Pi: MACHINE raspberrypi5, kernel, firmware y overlays del GPU
git clone -b scarthgap git://git.yoctoproject.org/meta-raspberrypi

# Colección de capas con recetas extra: X11, drivers, herramientas de red, multimedia
git clone -b scarthgap git://git.openembedded.org/meta-openembedded

# Inicializa el entorno de build y crea la carpeta build/ con los archivos de configuración
source oe-init-build-env build
```

---

## Registro de capas en bblayers.conf

`bblayers.conf` le dice a BitBake qué capas forman parte del proyecto. Sin que una capa esté registrada aquí, BitBake no sabe que existe y no puede usar ninguna receta que haya dentro de ella. Se usa `bitbake-layers add-layer` porque valida la compatibilidad de la capa antes de agregarla.

```bash
# Capa con soporte de hardware para Raspberry Pi
bitbake-layers add-layer ../meta-raspberrypi

# Recetas gráficas y de sistema: X.Org, matchbox-wm, vim, htop, etc.
bitbake-layers add-layer ../meta-openembedded/meta-oe

# Módulos y librerías de Python adicionales
bitbake-layers add-layer ../meta-openembedded/meta-python

# Herramientas de red: dhcpcd, net-tools, etc.
bitbake-layers add-layer ../meta-openembedded/meta-networking

# Codecs y librerías multimedia, requeridas por dependencias indirectas de X11
bitbake-layers add-layer ../meta-openembedded/meta-multimedia

# Crea la capa personalizada del proyecto y la registra
bitbake-layers create-layer meta-ai
bitbake-layers add-layer ../build/meta-ai/
```

---

## Estructura de la capa personalizada

Dentro de `meta-ai` van todas las recetas propias del proyecto. Hay que crearla con esta estructura exacta antes de compilar:

```
meta-ai
├── conf
│   └── layer.conf
├── COPYING.MIT
├── README
├── recipes-ai
│   └── ollama
│       ├── files
│       │   ├── gemma2-2b-prebaked.tar.gz
│       │   ├── ollama-linux-arm64.tgz
│       │   └── ollama.service
│       └── ollama_1.0.bb
├── recipes-core
│   ├── autologin
│   │   ├── autologin_1.0.bb
│   │   └── files
│   │       ├── autologin.conf
│   │       ├── bash_profile
│   │       ├── xinitrc
│   │       └── xorg.conf
│   ├── images
│   │   └── core-image-base.bbappend
│   └── show-ip
│       ├── files
│       │   └── 99-show-ip.sh
│       └── show-ip_1.0.bb
├── recipes-example
│   └── example
│       └── example_0.1.bb
└── recipes-graphics
    └── xorg-app
        └── xterm_%.bbappend
```

---

## Contenido de los archivos

### `layer.conf`

`layer.conf` es el archivo que define la identidad de la capa ante BitBake. Cada capa necesita uno. Sin él, BitBake no sabe cómo llamar a la capa, qué recetas contiene, ni con qué otras capas es compatible. Es básicamente el "carnet de identidad" de la capa dentro del sistema de build.

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

# Prioridad 10: si hay un conflicto con una receta de otra capa, gana esta
BBFILE_PRIORITY_meta-ai = "10"

# Esta capa necesita que "core" y "raspberrypi" estén presentes para funcionar
LAYERDEPENDS_meta-ai = "core raspberrypi"

# Declara que esta capa es compatible con Yocto Scarthgap
LAYERSERIES_COMPAT_meta-ai = "scarthgap"
```

---

### `ollama_1.0.bb`

Esta receta empaqueta Ollama para la imagen. Se encarga de instalar el binario, registrar el servicio systemd para que arranque solo, y colocar los pesos del modelo en la ruta donde Ollama los busca.

El tgz de Ollama contiene también runners para CUDA (NVIDIA) y ROCm (AMD). El RPi5 no tiene ninguno de esos GPUs, por lo que solo se instala el binario principal, que en versiones modernas de Ollama ya lleva la inferencia CPU integrada.

```bash
SUMMARY = "Ollama local AI model runner"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ollama-linux-arm64.tgz;subdir=ollama-release \
    file://ollama.service \
    file://gemma2-2b-prebaked.tar.gz;unpack=0 \
"
# subdir=ollama-release: extrae el tgz en su propia carpeta para no mezclar archivos
# unpack=0 en el modelo: BitBake extrae automáticamente los .tar.gz,
# pero aquí necesitamos controlarlo nosotros para elegir el destino final

S = "${WORKDIR}"

# "inherit systemd" activa el soporte para instalar y habilitar servicios systemd
inherit systemd

# Nombre del archivo .service que systemd debe registrar
SYSTEMD_SERVICE:${PN} = "ollama.service"

# "enable" hace que el servicio arranque solo en cada boot, sin necesidad de correr systemctl enable
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Instala el binario de Ollama en /usr/bin/
    # En esta versión, la inferencia CPU está dentro del binario directamente
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

    # lib/ollama/ no se instala: solo contiene runners CUDA (cuda_v11, cuda_v12)
    # que requieren libcuda.so, la cual no existe en el RPi5

    # Instala el archivo de servicio en el directorio estándar de systemd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/

    # Extrae los pesos del modelo en /root/.ollama/
    # --no-same-owner evita que el UID/GID original del tar cause errores de QA
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/gemma2-2b-prebaked.tar.gz \
        -C ${D}/root/.ollama/
}

# Lista los archivos que pertenecen a este paquete
FILES:${PN} += " \
    ${bindir}/ollama \
    ${systemd_system_unitdir}/ollama.service \
    /root/.ollama/ \
"

# El binario de Ollama viene precompilado y ya sin símbolos de debug
# Sin esta línea, BitBake lanzaría un error de QA al detectarlo
INSANE_SKIP:${PN} = "already-stripped"
```

---

### `ollama.service`

El archivo `.service` le dice a systemd cómo arrancar Ollama: con qué usuario, qué variables de entorno necesita y cuándo hacerlo. Sin las variables `HOME` y `OLLAMA_MODELS`, Ollama no encuentra los modelos aunque estén instalados, ya que cuando corre como servicio systemd no hereda las variables de entorno del usuario.

```ini
[Unit]
Description=Ollama Service
# Espera a que la red esté lista antes de iniciar
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=root

# Necesario porque Ollama busca los modelos en $HOME/.ollama/models
# Un servicio systemd no hereda el HOME del usuario por defecto
Environment=HOME=/root

# Ruta explícita a los modelos, por si HOME no está bien configurado
Environment=OLLAMA_MODELS=/root/.ollama/models

# Permite consultar la API de Ollama desde otros equipos en la red
Environment=OLLAMA_HOST=0.0.0.0:11434

# Sin límite de tiempo al detener el servicio: un prompt largo puede tardar en terminar
TimeoutStopSec=infinity

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

### Preparación de los archivos binarios

Los dos archivos que van dentro de `files/` no se pueden generar con BitBake porque son binarios externos. Hay que prepararlos en el host antes de compilar.

El tgz de Ollama se descarga directamente desde GitHub. El modelo se descarga usando Ollama en el host, y luego se empaqueta en un tar.gz con la estructura de directorios que Ollama espera encontrar en producción.

```bash
# Descarga el binario de Ollama para ARM64 (versión compatible con RPi5). El archivo descargado queda en la ubicación desde la que estaba la terminal.
wget https://github.com/ollama/ollama/releases/download/v0.5.7/ollama-linux-arm64.tgz

# Instala Ollama en el host para poder descargar el modelo
curl -fsSL https://ollama.com/install.sh | sh

# Descarga los pesos del modelo gemma2:2b (~1.6 GB)
ollama pull gemma2:2b

# Verifica que el modelo se descargó correctamente
ollama list

# Empaqueta los pesos con la estructura de directorios que Ollama espera:
# el tar.gz contendrá models/blobs/ y models/manifests/
# que luego se extraen en /root/.ollama/ dentro de la imagen
sudo tar -czvf ~/Escritorio/gemma2-2b-prebaked.tar.gz \
    -C /usr/share/ollama/.ollama models
```

Una vez descargados, ambos archivos deben copiarse a `meta-ai/recipes-ai/ollama/files/`.

---

### `autologin_1.0.bb`

Esta receta instala los cuatro archivos que hacen funcionar el autologin y la interfaz gráfica. Se separa en una receta propia para que sea un paquete reutilizable, en lugar de un script que genera archivos directamente sobre el rootfs.

```bash
SUMMARY = "Autologin de root en tty1, arranque automático de X11 y xorg.conf para RPi5"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://autologin.conf \
    file://xinitrc \
    file://bash_profile \
    file://xorg.conf \
"

S = "${WORKDIR}"

do_install() {
    # Instala el drop-in de systemd que activa el autologin en tty1
    install -d ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/
    install -m 0644 ${WORKDIR}/autologin.conf \
        ${D}${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf

    # Instala los archivos de sesión de root
    install -d ${D}/root
    install -m 0755 ${WORKDIR}/xinitrc     ${D}/root/.xinitrc
    install -m 0644 ${WORKDIR}/bash_profile ${D}/root/.bash_profile

    # Instala la configuración de X11 para RPi5
    # Reemplaza cualquier xorg.conf genérico que xserver-xorg pudiera haber dejado
    install -d ${D}${sysconfdir}/X11
    install -m 0644 ${WORKDIR}/xorg.conf ${D}${sysconfdir}/X11/xorg.conf
}

# Todos los archivos que pertenecen a este paquete
FILES:${PN} = " \
    ${sysconfdir}/systemd/system/getty@tty1.service.d/autologin.conf \
    ${sysconfdir}/X11/xorg.conf \
    /root/.xinitrc \
    /root/.bash_profile \
"

# Marca estos archivos como de configuración: el gestor de paquetes
# no los sobreescribirá si el usuario los modifica en la Pi
CONFFILES:${PN} = " \
    ${sysconfdir}/X11/xorg.conf \
    /root/.xinitrc \
    /root/.bash_profile \
"
```

---

### `autologin.conf`

Este archivo es un "drop-in" de systemd para el servicio `getty@tty1`. En lugar de modificar la unidad original de getty, systemd lee esta carpeta `.service.d/` y aplica los cambios encima. El resultado es que al arrancar la Pi, el login en tty1 ocurre automáticamente con el usuario root, sin que nadie escriba nada.

```ini
[Service]
# La primera línea vacía borra el ExecStart original de getty
# Sin esto, systemd acumularía dos comandos de inicio y fallaría
ExecStart=
# --autologin root: hace login automático sin pedir contraseña
# --noclear: no borra los mensajes de boot antes del prompt
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM

# Type=idle: espera a que todos los demás servicios terminen de arrancar
# antes de mostrar el prompt, evitando que los mensajes de boot se mezclen
Type=idle
```

---

### `bash_profile`

Cuando root hace login en tty1 gracias al autologin, bash ejecuta `.bash_profile`. Este archivo detecta si el login ocurrió en la pantalla física (tty1) y arranca X11 automáticamente. Si el login fue por SSH, la condición no se cumple y X no se intenta lanzar.

```bash
#!/bin/bash

# Carga .bashrc si existe (aliases, PATH personalizados, etc.)
[ -f ~/.bashrc ] && source ~/.bashrc

# Lanza X11 solo si no hay display activo y el login ocurrió en tty1
# Esto evita intentar arrancar X cuando la conexión es por SSH
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    echo "Iniciando interfaz gráfica X11..."
    exec startx 2>/var/log/xsession-errors
fi
```

---

### `xinitrc`

Cuando `startx` arranca el servidor X, lee `.xinitrc` para saber qué ejecutar. Aquí se lanza el window manager y la terminal. `matchbox-wm` va en segundo plano (`&`) y `xterm` en primer plano: cuando xterm se cierra, X termina y la sesión vuelve a tty1, donde el autologin vuelve a activarse.

```bash
#!/bin/sh

# Arranca Matchbox WM en segundo plano
# Es un window manager minimalista, diseñado para sistemas embebidos
matchbox-wm &

# Abre xterm como proceso principal de la sesión
# Cuando esta ventana se cierra, X11 termina
exec xterm -fa Monospace -fs 12 -title "RPi5 Terminal"
```

---

### `xorg.conf`

Sin este archivo, X.Org intenta autodetectar el hardware y puede terminar eligiendo el modo framebuffer, que es incompatible con el stack DRM/KMS del RPi5. Este archivo le indica explícitamente que use el driver `modesetting` con el dispositivo `/dev/dri/card0`, que es como el GPU VideoCore VI del RPi5 se expone al sistema.

```
Section "Device"
    Identifier  "RPi5 VideoCore VI"
    # modesetting es el driver correcto para hardware con DRM/KMS
    # No usar xf86-video-fbdev: ese es framebuffer legacy, no funciona en RPi5
    Driver      "modesetting"
    # card0 es el nodo DRM del GPU VideoCore VI
    Option      "kmsdev"       "/dev/dri/card0"
    # Desactiva aceleración por software que puede interferir con el stack DRM
    Option      "AccelMethod"  "none"
EndSection

Section "Screen"
    Identifier  "Default Screen"
    Device      "RPi5 VideoCore VI"
    # Sin DefaultDepth: X lee la profundidad de color del monitor via EDID
EndSection
```

---

### `core-image-base.bbappend`

Un `.bbappend` extiende una receta existente sin modificarla directamente. En este caso, extiende `core-image-base` para agregar los paquetes propios de la capa (`autologin` y `show-ip`) y para modificar `sshd_config` después de que los paquetes están instalados. La modificación de `sshd_config` se hace aquí con un `ROOTFS_POSTPROCESS_COMMAND` porque altera un archivo de otro paquete (openssh), lo cual no se puede hacer desde una receta propia.

```bash
# Agrega los paquetes autologin y show-ip a la imagen
IMAGE_INSTALL:append = " autologin show-ip"

# Ejecuta la función configure_sshd sobre el rootfs ya armado
ROOTFS_POSTPROCESS_COMMAND:append = " configure_sshd;"

configure_sshd() {
    SSHD_CONFIG="${IMAGE_ROOTFS}/etc/ssh/sshd_config"

    # Si openssh no está instalado, omite sin romper el build
    if [ ! -f "${SSHD_CONFIG}" ]; then
        bbwarn "configure_sshd: ${SSHD_CONFIG} no encontrado, omitiendo."
        return 0
    fi

    # Permite que root se conecte por SSH (por defecto está bloqueado)
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'          "${SSHD_CONFIG}"
    # Acepta contraseñas vacías
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' "${SSHD_CONFIG}"
    # Desactiva PAM: con PAM activo, los módulos de autenticación rechazan
    # contraseñas vacías aunque OpenSSH las permitiría
    sed -i 's/^#*UsePAM.*/UsePAM no/'                             "${SSHD_CONFIG}"

    # Si las directivas no existían en el archivo, las agrega al final
    grep -q "^PermitRootLogin"      "${SSHD_CONFIG}" || echo "PermitRootLogin yes"      >> "${SSHD_CONFIG}"
    grep -q "^PermitEmptyPasswords" "${SSHD_CONFIG}" || echo "PermitEmptyPasswords yes" >> "${SSHD_CONFIG}"
    grep -q "^UsePAM"               "${SSHD_CONFIG}" || echo "UsePAM no"                >> "${SSHD_CONFIG}"
}
```

---

### `99-show-ip.sh`

Los archivos en `/etc/profile.d/` se ejecutan automáticamente en cualquier login interactivo, tanto en consola física como por SSH. Este script muestra un banner con la dirección IP de cada interfaz de red activa y el comando `ssh` listo para copiar. Es útil porque evita tener que conectar teclado y monitor a la Pi para saber a qué IP conectarse.

```bash
#!/bin/sh

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│         Raspberry Pi 5 — Yocto          │"
echo "├─────────────────────────────────────────┤"

found=0

# Itera sobre los nombres de interfaz posibles en RPi5
# El kernel puede llamar a Ethernet "eth0" o "end0" según la configuración
for iface in eth0 eth1 end0 wlan0; do
    # Extrae solo la IP (sin el prefijo de subred) usando awk
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

### `show-ip_1.0.bb`

Receta que empaqueta el script anterior como un paquete propio. Declarar `iproute2` como dependencia en tiempo de ejecución garantiza que el comando `ip` esté disponible cuando el script se ejecute.

```bash
SUMMARY = "Muestra la dirección IP al iniciar sesión"
DESCRIPTION = "Instala /etc/profile.d/99-show-ip.sh para mostrar \
               las IPs de red disponibles en cada login."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://99-show-ip.sh"

S = "${WORKDIR}"

do_install() {
    # Instala el script en profile.d/ para que se ejecute en cada login
    install -d ${D}${sysconfdir}/profile.d/
    install -m 0755 ${WORKDIR}/99-show-ip.sh \
        ${D}${sysconfdir}/profile.d/99-show-ip.sh
}

FILES:${PN} = "${sysconfdir}/profile.d/99-show-ip.sh"

# iproute2 provee el comando "ip" que usa el script
RDEPENDS:${PN} = "iproute2"
```

---

### `xterm_%.bbappend`

La receta de xterm en meta-oe intenta instalar un archivo `.desktop` (un acceso directo de escritorio) como parte de `do_install`. En la versión 388, ese target no existe en el Makefile de xterm y el build falla. Este bbappend desactiva esa funcionalidad antes de que se compile.

El `%` en el nombre del archivo funciona como comodín: aplica a cualquier versión de xterm, no solo a la 388.

```bash
# Desactiva la generación del archivo .desktop durante la configuración
# Esto evita que make intente instalar un target que no existe en xterm 388
EXTRA_OECONF:append = " --disable-desktop-utils"
```

---

### `local.conf`

`local.conf` es el archivo de configuración principal del build.

```bash
# ================================================================
#  local.conf — Yocto Scarthgap | Raspberry Pi 5
# ================================================================

# ----------------------------------------------------------------
# 1. MÁQUINA Y DISTRIBUCIÓN
# ----------------------------------------------------------------
# raspberrypi5: activa el BSP específico del RPi5 (kernel, firmware, device tree)
MACHINE = "raspberrypi5"
# poky es la distribución de referencia de Yocto
DISTRO = "poky"
# IPK es el formato de paquetes estándar en imágenes embebidas
PACKAGE_CLASSES = "package_ipk"

# ----------------------------------------------------------------
# 2. SISTEMA DE INIT: systemd
# ----------------------------------------------------------------
# Reemplaza SysVinit por systemd, necesario para el autologin por drop-in
DISTRO_FEATURES:append = " systemd"
# usrmerge es requerido por systemd en Scarthgap para proveer udev
# Sin esto, xserver-xorg y dhcpcd fallan al no encontrar el proveedor de udev
DISTRO_FEATURES:append = " usrmerge"
VIRTUAL-RUNTIME_init_manager = "systemd"
DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"

# ----------------------------------------------------------------
# 3. CARACTERÍSTICAS DE LA DISTRO Y HARDWARE
# ----------------------------------------------------------------
# Habilita el subsistema X11 en la distro para que los paquetes gráficos se compilen con soporte X
DISTRO_FEATURES:append = " x11"
# 128 MB de RAM dedicados al GPU para el framebuffer de X11
GPU_MEM = "128"
# Activa la UART hardware, útil para debug por consola serie
ENABLE_UART = "1"
# Activa el overlay vc4-kms-v3d-pi5, que expone el GPU VideoCore VI como dispositivo DRM/KMS
MACHINE_FEATURES:append = " vc4graphics"

# ----------------------------------------------------------------
# 4. IMAGE FEATURES
# ----------------------------------------------------------------
# empty-root-password: deja la contraseña de root vacía
# ssh-server-openssh: instala y habilita sshd automáticamente
# allow-empty-password: configura PAM para aceptar contraseñas vacías
EXTRA_IMAGE_FEATURES += " \
    empty-root-password \
    ssh-server-openssh \
    allow-empty-password \
"

# ----------------------------------------------------------------
# 5. PAQUETES — INTERFAZ GRÁFICA X11 + Matchbox WM
# ----------------------------------------------------------------
IMAGE_INSTALL:append = " \
    xserver-xorg \
    xf86-video-modesetting \
    xf86-input-evdev \
    xf86-input-libinput \
    matchbox-wm \
    xterm \
    xinit \
    xauth \
    xrandr \
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
# 7. PAQUETES — UTILITARIOS
# ----------------------------------------------------------------
IMAGE_INSTALL:append = " \
    bash \
    vim \
    htop \
    procps \
    coreutils \
"

# ----------------------------------------------------------------
# 8. RASPBERRY PI — CONFIGURACIÓN ESPECÍFICA
# ----------------------------------------------------------------
# Usa el bootloader nativo del RPi en lugar de U-Boot
RPI_USE_U_BOOT = "0"
ENABLE_SPI_BUS = "1"
ENABLE_I2C = "1"

# vc4-kms-v3d-pi5: activa el driver DRM del GPU
# cma-512: reserva 512 MB de memoria contigua para el GPU, necesario para X11
RPI_EXTRA_CONFIG:append = "\ndtoverlay=vc4-kms-v3d-pi5,cma-512\n"

# ----------------------------------------------------------------
# 9. PAQUETES — OLLAMA Y LLM
# ----------------------------------------------------------------
# libstdc++, libgcc, libgomp: dependencias en tiempo de ejecución del binario de Ollama
# ca-certificates: necesario para conexiones HTTPS desde Ollama
# numactl: herramienta de gestión de memoria NUMA
IMAGE_INSTALL:append = " ollama ca-certificates libstdc++ libgcc libgomp numactl"

# ----------------------------------------------------------------
# 10. ALMACENAMIENTO Y LICENCIAS
# ----------------------------------------------------------------
# wic.bz2: genera una imagen de disco completa lista para grabar en SD
IMAGE_FSTYPES = "wic.bz2"

# 6 GB de espacio extra en el rootfs para el modelo gemma2:2b (~1.6 GB) y margen
IMAGE_ROOTFS_EXTRA_SPACE = "6291456"

LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch commercial"

# ----------------------------------------------------------------
# 11. RENDIMIENTO DE COMPILACIÓN
# ----------------------------------------------------------------
BB_NUMBER_PARSE_THREADS = "2"
BB_NUMBER_THREADS = "4"
PARALLEL_MAKE = "-j 4"

# ----------------------------------------------------------------
# 12. DIRECTORIOS DE CACHÉ
# ----------------------------------------------------------------
# Coloca downloads y sstate-cache fuera del directorio de build
# para que persistan entre builds y ahorren tiempo de compilación
DL_DIR ?= "${TOPDIR}/../downloads"
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache"
TMPDIR = "${TOPDIR}/tmp"

CONF_VERSION = "2"

# ----------------------------------------------------------------
# 13. FIXES DE BUILD
# ----------------------------------------------------------------
# Desactiva la generación de manifiestos SPDX (licencias)
# Causan colisiones de sstate si se cambian DISTRO_FEATURES entre builds
INHERIT:remove = "create-spdx"

# Desactiva la instalación del archivo .desktop de xterm
# La receta de meta-oe lo intenta instalar pero el Makefile de xterm 388 no lo soporta
PACKAGECONFIG:remove:pn-xterm = "desktop-utils"
```

---

## Compilación de la imagen

Con todos los archivos en su lugar, se compila la imagen. El proceso toma varias horas la primera vez porque compila todo desde el código fuente. Las compilaciones posteriores son más rápidas gracias al sstate-cache.

```bash
# Desde dentro del contenedor Docker, inicializa el entorno de build
source oe-init-build-env build

# Compila la imagen completa
bitbake core-image-base
```

---

## Ubicación de la imagen generada

Al terminar, la imagen aparece en:

```
poky/
└── build/
    └── tmp/
        └── deploy/
            └── images/
                └── raspberrypi5/
                    └── core-image-base-raspberrypi5.rootfs-20260425203823.wic.bz2
```

Hay que copiarla a una carpeta fuera del contenedor antes de seguir.

---

## Flasheo de la tarjeta SD

Para flashear la imagen se usa balenaEtcher. Sin embargo, balenaEtcher trabaja mejor con imágenes sin comprimir, así que primero se descomprime el `.wic.bz2`:

```bash
# Desde fuera del contenedor, en el mismo directorio que la imagen
# El nombre exacto del archivo varía según la fecha del build
bzip2 -d -v core-image-base-raspberrypi5.rootfs-20260425203823.wic.bz2
```

Esto genera un archivo `.wic` que se selecciona directamente en balenaEtcher junto con la tarjeta SD como destino.

---

## Primer arranque y conexión SSH

Con la tarjeta SD lista, se conecta la Pi al router por cable Ethernet y se enciende la Pi. La imagen está configurada para hacer todo de forma automática: autologin al arrancar, obtener IP por DHCP y arrancar el servidor SSH.

Al encender, la Pi muestra automáticamente un banner con su dirección IP.

```bash
# Conectarse a la Pi por SSH (usar la IP que muestra el banner)
ssh root@192.168.100.133

# La primera vez pregunta si se confía en el host, responder sí
yes
```

---

## Uso del LLM

Ya dentro de la Pi:

```bash
# Verifica que el modelo está instalado
ollama list

# Envía un prompt directo
ollama run gemma2:2b "Prompt elegido"

# Abre un chat interactivo con el modelo
ollama run gemma2:2b
```

---

## Troubleshooting

### Error de llave SSH al reconectar

Si se flashea una imagen nueva a la misma Pi y se intenta conectar a la misma IP, SSH rechaza la conexión porque la llave del servidor cambió. Para corregirlo:

```bash
# Elimina la llave antigua asociada a esa IP
# Reemplaza la ruta por la del usuario actual y la IP correspondiente
ssh-keygen -f '/home/usuario/.ssh/known_hosts' -R '192.168.100.133'
```

---

### SSH aparece como inactivo

Si al verificar el estado de SSH se ve que está inactivo:

```bash
systemctl status sshd
```

Se puede activar manualmente para la sesión actual:

```bash
systemctl start sshd
```

Si el problema es recurrente entre reinicios, significa que `sshd.service` no está habilitado. Se puede activar permanentemente con:

```bash
systemctl enable sshd
systemctl start sshd
```

---

### La Pi no obtiene IP (sin conexión de red)

Si el banner de show-ip muestra "Sin IP asignada aún":

```bash
# Verifica el estado del cliente DHCP
systemctl status dhcpcd

# Si está inactivo, arráncalo manualmente
systemctl start dhcpcd

# Espera unos segundos y verifica la IP asignada
ip addr show eth0
```

---

### X11 no arranca (xterm: command not found / twm: command not found)

Si `startx` falla con errores de comandos no encontrados como `twm` o `xclock`, significa que X está leyendo el xinitrc del sistema (`/etc/X11/xinit/xinitrc`) en lugar del de root (`/root/.xinitrc`). Verificar que el archivo existe:

```bash
ls -la /root/.xinitrc
cat /root/.xinitrc
```

El archivo debe existir y contener `matchbox-wm` y `xterm`. Si no existe, el archivo `autologin_1.0.bb` no se instaló correctamente. Revisar que la receta esté siendo incluida por `core-image-base.bbappend`.

---

### Ollama falla al correr un modelo (error -1)

```
Error: llama runner process no longer running: -1
```

Las causas más comunes son:

**Los pesos del modelo no están en la ruta correcta.** Verificar:

```bash
ls /root/.ollama/models/
```

Debe contener las carpetas `blobs/` y `manifests/`. Si está vacío, el `tar.gz` del modelo no se instaló bien en la receta.

**Variables de entorno incorrectas.** Verificar que el servicio las tiene:

```bash
systemctl show ollama | grep Environment
```

Debe mostrar `HOME=/root` y `OLLAMA_MODELS=/root/.ollama/models`.
