# Demostración práctica

Se usa una Raspberry Pi 5 de 8 GB de RAM. Se crea una imagen personalizada usando Yocto Scarthgap dentro de un contenedor Docker. La imagen es de consola, sin interfaz gráfica. Incluye acceso por SSH sin contraseña, autologin al encender, un LLM local corriendo con Ollama, y un agente que lee correos de Gmail y responde automáticamente como asistente de ventas de una tienda de electrónica.

---

## Creación del contenedor Docker

Yocto requiere una cantidad considerable de dependencias del sistema. Para no instalarlas directamente en el host y garantizar un entorno reproducible, todo el trabajo de compilación se hace dentro de un contenedor Docker basado en Ubuntu 22.04.

El setup está dividido en tres archivos que trabajan juntos:

- **`Dockerfile`**: instala las dependencias del sistema y copia los scripts. No clona nada.
- **`setup.sh`**: clona Poky y las capas, registra las capas en BitBake, crea la capa `meta-ai` y escribe todas las recetas y archivos de configuración.
- **`entrypoint.sh`**: se ejecuta cada vez que arranca el contenedor. La primera vez que el contenedor arranca con el volumen vacío, ejecuta `setup.sh` automáticamente — los archivos quedan en el directorio del host y son visibles desde el administrador de archivos. Las veces siguientes, detecta que el workspace ya existe y abre bash directamente.

Con Docker instalado, se crea una carpeta para el proyecto y dentro de ella se colocan los tres archivos:

```bash
mkdir yocto-pi5-project
cd yocto-pi5-project
```

### `Dockerfile`

Se encarga de preparar el sistema operativo del contenedor.

```dockerfile
FROM ubuntu:22.04

# Evita que apt lance preguntas interactivas durante la instalación de paquetes
ENV DEBIAN_FRONTEND=noninteractive

# Todas las dependencias que Yocto necesita para compilar:
# - compiladores (gcc, build-essential, chrpath)
# - herramientas de scripting (gawk, diffstat, python3 y sus módulos)
# - utilidades de compresión (xz-utils, zstd, liblz4-tool)
# - librerías gráficas requeridas por algunas recetas aunque no usemos GUI
RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl-mesa0 libsdl1.2-dev \
    pylint xterm python3-subunit mesa-common-dev zstd liblz4-tool \
    python3-distutils curl locales sudo vim tmux file mc \
    && rm -rf /var/lib/apt/lists/*

# Yocto requiere un locale UTF-8 correcto; sin esto algunos scripts fallan
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

# Copia los dos scripts al home del usuario, fuera del volumen,
# para que siempre estén disponibles independientemente del estado del volumen
COPY --chown=yoctouser:yoctouser setup.sh    /home/yoctouser/setup.sh
COPY --chown=yoctouser:yoctouser entrypoint.sh /home/yoctouser/entrypoint.sh
RUN chmod +x /home/yoctouser/setup.sh /home/yoctouser/entrypoint.sh

# Todo lo que corre dentro del contenedor lo hace como yoctouser, nunca como root
USER yoctouser
WORKDIR /home/yoctouser/yocto-workspace

# El entrypoint se ejecuta en cada arranque del contenedor
ENTRYPOINT ["/home/yoctouser/entrypoint.sh"]
```

---

### `entrypoint.sh`

Se ejecuta automáticamente cada vez que el contenedor arranca. Su lógica es simple: si el workspace está vacío, ejecuta el setup completo; si ya tiene contenido, inicializa el entorno de Yocto y abre bash.

```bash
#!/bin/bash

WORKSPACE=/home/yoctouser/yocto-workspace

# Detectar si el workspace ya fue inicializado buscando la carpeta poky/
# Si no existe, es la primera vez que arranca el contenedor con este volumen
if [ ! -d "$WORKSPACE/poky" ]; then
    echo "========================================================"
    echo "  Primera ejecución: configurando el workspace..."
    echo "  Esto tarda unos minutos por los clones de git."
    echo "========================================================"
    /home/yoctouser/setup.sh
    echo "========================================================"
    echo "  Setup completo. El workspace es visible desde tu host."
    echo "========================================================"
else
    echo ">>> Workspace ya configurado. Iniciando entorno de Yocto..."
fi

# Inicializar el entorno de Yocto — establece PATH y variables necesarias para BitBake
# La salida se suprime porque el mensaje informativo de Yocto no es útil en arranques repetidos
cd $WORKSPACE/poky
source oe-init-build-env build

# Abrir bash interactivo, listo para correr bitbake
exec /bin/bash
```

---

### `setup.sh`

Es el script que configura todo el workspace de Yocto. Se ejecuta una sola vez, en el primer arranque del contenedor. Clona los repositorios, inicializa el entorno de build, registra las capas y crea todos los directorios y archivos de recetas.

```bash
#!/bin/bash
set -e  # El script se detiene inmediatamente si cualquier comando falla

# Rutas base — todo en el script se deriva de estas variables
WORKSPACE=/home/yoctouser/yocto-workspace
POKY=$WORKSPACE/poky
BUILD=$POKY/build
META_AI=$BUILD/meta-ai

# ── Paso 1: Clonar repositorios ──────────────────────────────────
# Cada clone usa la ruta absoluta de destino para no depender del
# directorio de trabajo actual

git clone -b scarthgap https://git.yoctoproject.org/poky.git $POKY

# meta-raspberrypi: BSP para Raspberry Pi (kernel, firmware, device tree)
git clone -b scarthgap https://git.yoctoproject.org/meta-raspberrypi $POKY/meta-raspberrypi

# meta-openembedded: colección de capas con recetas extra
# Se usa meta-oe, meta-python y meta-networking
git clone -b scarthgap https://github.com/openembedded/meta-openembedded.git $POKY/meta-openembedded

# ── Paso 2: Inicializar el entorno de build ───────────────────────
# source oe-init-build-env requiere que el directorio actual sea poky/
# Es el único cd del script; después el directorio activo es $BUILD
cd $POKY
source oe-init-build-env build

# ── Paso 3: Verificar rutas antes de registrar capas ─────────────
# Si alguna capa no existe, el script falla con un mensaje claro
# en lugar de producir un error críptico de bitbake-layers
for dir in \
    "$POKY/meta-openembedded/meta-oe" \
    "$POKY/meta-openembedded/meta-python" \
    "$POKY/meta-openembedded/meta-networking" \
    "$POKY/meta-raspberrypi"; do
    if [ ! -d "$dir" ]; then
        echo "ERROR: no existe $dir"; exit 1
    fi
done

# ── Paso 4: Registrar capas en bblayers.conf ─────────────────────
# Se usan rutas absolutas para que bblayers.conf quede con paths completos
bitbake-layers add-layer $POKY/meta-openembedded/meta-oe
bitbake-layers add-layer $POKY/meta-openembedded/meta-python
bitbake-layers add-layer $POKY/meta-openembedded/meta-networking
bitbake-layers add-layer $POKY/meta-raspberrypi

# Crea la capa meta-ai con la estructura mínima y la registra
bitbake-layers create-layer $META_AI
bitbake-layers add-layer $META_AI

# ── Paso 5: Crear directorios de la capa ─────────────────────────
mkdir -p $META_AI/recipes-ai/ollama/files
mkdir -p $META_AI/recipes-ai/email-agent/files
mkdir -p $META_AI/recipes-core/autologin/files
mkdir -p $META_AI/recipes-core/images
mkdir -p $META_AI/recipes-core/show-ip/files

# ── Paso 6: Escribir todos los archivos de recetas ───────────────
# (ver sección "Contenido de los archivos" para la explicación de cada uno)

# ... [el script escribe aquí todos los archivos detallados en la sección siguiente]

# ── Paso 7: Escribir local.conf ───────────────────────────────────
# Reemplaza el local.conf generado por defecto por oe-init-build-env
# con la configuración final del proyecto
cat > $BUILD/conf/local.conf << 'EOF'
# contenido de local.conf (detallado en su sección correspondiente)
EOF
```

---

## Preparación de los archivos binarios

Antes de hacer el build, hay que preparar los binarios que van dentro de la receta de Ollama. Estos pasos se ejecutan en el **host** (fuera del contenedor), en una terminal separada. Son los únicos archivos que no se crean automáticamente porque son demasiado pesados para incluirlos en el repositorio.

### Descargar el binario de Ollama

Ollama distribuye binarios precompilados para ARM64.

```bash
# Descarga el binario de Ollama para ARM64
# La versión 0.6.2 es estable y compatible con el RPi5
wget https://github.com/ollama/ollama/releases/download/v0.6.2/ollama-linux-arm64.tgz

# Verifica que el archivo descargó correctamente
ls -lh ollama-linux-arm64.tgz
```

### Descargar y empaquetar el modelo gemma3:4b

Se usa `gemma3:4b` como modelo de lenguaje. 

```bash
# Instala Ollama en el host para poder descargar el modelo
curl -fsSL https://ollama.com/install.sh | sh

# Descarga gemma3:4b (~3.1 GB)
ollama pull gemma3:4b

# Verifica que el modelo quedó disponible
ollama list
# Debe mostrar: gemma3:4b con su ID y tamaño

# Empaqueta los pesos del modelo con la estructura de directorios que Ollama espera.
# El tar.gz resultante contendrá models/blobs/ y models/manifests/,
# que luego se extraen en /root/.ollama/ dentro de la imagen
sudo tar -czvf gemma3:4b-prebaked.tar.gz \
    -C /usr/share/ollama/.ollama models
```

---

## Construcción y primer arranque

Con los tres archivos del proyecto listos (`Dockerfile`, `setup.sh`, `entrypoint.sh`), se construye la imagen y se arranca el contenedor.

```bash
# Construye la imagen Docker — solo instala dependencias del sistema
# No clona nada, así que es relativamente rápido
docker build -t yocto-builder-pi5 .

# Crea la carpeta que se montará como volumen
mkdir -p yocto-workspace

# Arranca el contenedor por primera vez con el volumen montado.
# Como el volumen está vacío, entrypoint.sh detecta que es la primera
# vez y ejecuta setup.sh automáticamente: clona repos, configura capas
# y crea todas las recetas. Al terminar, todo es visible desde el
# administrador de archivos del host en la carpeta yocto-workspace/
docker run -it --name yocto-ia-pi5 \
  -v $(pwd)/yocto-workspace:/home/yoctouser/yocto-workspace \
  yocto-builder-pi5

# Para volver a entrar al contenedor en sesiones posteriores
# (el setup no se repite — detecta que poky/ ya existe)
docker start yocto-ia-pi5
docker exec -it yocto-ia-pi5 /bin/bash
```

Una vez dentro del contenedor, copiar los dos binarios pesados a la carpeta de la receta.

---

## Estructura de la capa personalizada

El script `setup.sh` crea automáticamente la siguiente estructura dentro del volumen del host:

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
│           ├── ollama-linux-arm64.tgz    ← copiar manualmente
│           ├── ollama.service
│           └── qwen2.5-3b-prebaked.tar.gz ← copiar manualmente
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

Los únicos archivos que hay que copiar manualmente son los dos binarios pesados marcados arriba. El resto lo crea `setup.sh` en el primer arranque.

---

## Contenido de los archivos

Esta sección explica qué hace cada archivo que `setup.sh` crea automáticamente y por qué existe.

### `layer.conf`

`layer.conf` es el archivo que define la identidad de la capa ante BitBake. Sin él, BitBake no sabe cómo llamar a la capa, qué recetas contiene, ni con qué otras capas es compatible.

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
    file://gemma3:4b-prebaked.tar.gz;unpack=0 \
"
# subdir=ollama-release: extrae el tgz en su propia carpeta para no mezclar archivos
# unpack=0 en el modelo: BitBake descomprime .tar.gz automáticamente, pero aquí
# necesitamos hacerlo nosotros para elegir el destino correcto (/root/.ollama/)

S = "${WORKDIR}"

# "inherit systemd" activa el soporte para instalar y habilitar unidades systemd
inherit systemd

SYSTEMD_SERVICE:${PN} = "ollama.service"

# "enable" hace que el servicio arranque en cada boot sin correr systemctl enable a mano
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Instala el binario principal en /usr/bin/
    # En versiones modernas de Ollama, la inferencia CPU está dentro de este binario
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

    # lib/ollama/ NO se instala: solo contiene runners CUDA/ROCm que requieren
    # libcuda.so o librocm — librerías que no existen en el RPi5
    # Instalarlos causaría errores de QA (dependencias no satisfechas)

    # Instala el archivo de servicio en el directorio estándar de systemd
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ollama.service ${D}${systemd_system_unitdir}/

    # Extrae los pesos del modelo en /root/.ollama/
    # --no-same-owner: descarta el UID/GID original del tar para evitar
    # el error "uid not found" en la fase do_package de BitBake
    install -d ${D}/root/.ollama
    tar --no-same-owner -xzf ${WORKDIR}/gemma3:4b-prebaked.tar.gz \
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

Le dice a systemd cómo arrancar Ollama: cuándo hacerlo, con qué usuario y qué variables de entorno necesita. Las variables `HOME` y `OLLAMA_MODELS` son críticas: cuando Ollama corre como servicio systemd no hereda el entorno del usuario, y sin ellas no encuentra los modelos aunque estén instalados.

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
# Un servicio systemd no hereda HOME del usuario — hay que definirlo explícitamente
Environment=HOME=/root

# Ruta explícita a los modelos como refuerzo adicional
Environment=OLLAMA_MODELS=/root/.ollama/models

# Escucha en todas las interfaces: permite consultar la API desde la red local
Environment=OLLAMA_HOST=0.0.0.0:11434

# Sin límite de tiempo para detener: un modelo cargado puede tardar en terminar
TimeoutStopSec=infinity

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

### `autologin_1.0.bb`

Esta receta instala el drop-in de systemd para getty que produce el autologin de root en tty1. Al no tener interfaz gráfica, el autologin simplemente lleva al prompt de consola directamente.

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

Drop-in de systemd para `getty@tty1`. En lugar de modificar la unidad original de getty, systemd lee la carpeta `.service.d/` y aplica estos cambios encima. El resultado es que al arrancar la Pi, el login ocurre automáticamente con root sin que nadie escriba nada.

Ubicación: `meta-ai/recipes-core/autologin/files/autologin.conf`

```ini
[Service]
# La primera línea vacía borra el ExecStart original de getty
# Sin esto, systemd acumularía dos comandos de inicio y fallaría
ExecStart=
# --autologin root: hace login automático sin pedir contraseña
# --noclear: no borra los mensajes de boot antes del prompt
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM

# Type=idle: espera a que todos los demás servicios terminen de arrancar
# antes de mostrar el prompt, evitando mezclar mensajes de boot con la sesión
Type=idle
```

---

### `show-ip_1.0.bb`

Empaqueta un script que se ejecuta automáticamente en cada login y muestra las IPs asignadas. Es útil porque evita conectar teclado y monitor para saber a qué dirección SSH conectarse.

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
    # Extrae solo la IP sin el prefijo de subred usando awk
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

Un `.bbappend` extiende una receta existente sin modificarla directamente. Este archivo extiende `core-image-base` para agregar los paquetes propios (`autologin`, `show-ip`, `email-agent`) y realizar dos configuraciones sobre el rootfs después de instalar los paquetes.

`configure_sshd` modifica `/etc/ssh/sshd_config` para permitir login de root sin contraseña. Se hace aquí con `ROOTFS_POSTPROCESS_COMMAND` porque altera un archivo de otro paquete (openssh), lo que no puede hacerse desde una receta propia.

`enable_timesyncd` crea el symlink de systemd para habilitar el cliente NTP. `systemd-timesyncd` viene dentro del paquete `systemd` pero no está habilitado por defecto en imágenes mínimas de Yocto. Sin esto, la Pi arranca sin sincronizar la hora y los certificados SSL fallan al conectarse a Gmail.

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
        bbwarn "sshd_config no encontrado, omitiendo."; return 0
    fi

    # Por defecto OpenSSH bloquea el login de root — esto lo habilita
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/'          "${SSHD_CONFIG}"
    # Por defecto OpenSSH rechaza contraseñas vacías — esto lo permite
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' "${SSHD_CONFIG}"
    # PAM con contraseña vacía bloquea el login aunque OpenSSH lo permitiría
    sed -i 's/^#*UsePAM.*/UsePAM no/'                             "${SSHD_CONFIG}"

    # Si las directivas no existían en el archivo, las agrega al final
    grep -q "^PermitRootLogin"      "${SSHD_CONFIG}" || echo "PermitRootLogin yes"      >> "${SSHD_CONFIG}"
    grep -q "^PermitEmptyPasswords" "${SSHD_CONFIG}" || echo "PermitEmptyPasswords yes" >> "${SSHD_CONFIG}"
    grep -q "^UsePAM"               "${SSHD_CONFIG}" || echo "UsePAM no"                >> "${SSHD_CONFIG}"
}

enable_timesyncd() {
    WANTS_DIR="${IMAGE_ROOTFS}/etc/systemd/system/sysinit.target.wants"
    UNIT="${IMAGE_ROOTFS}/usr/lib/systemd/system/systemd-timesyncd.service"

    if [ -f "${UNIT}" ]; then
        install -d "${WANTS_DIR}"
        # Este symlink es el equivalente de "systemctl enable systemd-timesyncd"
        # aplicado en tiempo de build, sobre el rootfs
        ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
               "${WANTS_DIR}/systemd-timesyncd.service"
    else
        bbwarn "systemd-timesyncd.service no encontrado."
    fi
}
```

---

### `email-agent_1.0.bb`

Esta receta instala el agente de email: el script Python, el servicio systemd, el documento de información de la tienda y el archivo de configuración con las credenciales.

Los archivos de configuración (`config.env` y `store_info.md`) se instalan como plantillas y se editan en la Pi después del primer arranque vía SSH. Hornear las credenciales en la imagen las dejaría expuestas en el archivo `.wic`.

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
    # Script en su propio directorio para no mezclarlo con binarios del sistema
    install -d ${D}/usr/bin/email-agent/
    install -m 0755 ${WORKDIR}/agent.py ${D}/usr/bin/email-agent/agent.py

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
# La stdlib (imaplib, smtplib, email, logging) viene con python3
# requests es el único paquete externo necesario para llamar a la API de Ollama
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

El archivo está comentado en detalle en el código. Los parámetros más importantes son:

- `temperature=0.1`: mínima creatividad para respuestas factuales. Reduce la tendencia del modelo a inventar productos o precios.
- `num_predict=1200`: espacio suficiente para responder preguntas múltiples sin truncarse.
- El cuerpo del correo se trunca a 600 caracteres para no desperdiciar tokens del contexto limitado del modelo.

Ubicación: `meta-ai/recipes-ai/email-agent/files/agent.py`

---

### `config.env`

Archivo de configuración del agente. Se instala como plantilla y se edita en la Pi después del primer arranque.

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
# Define el tono y la firma de las respuestas — mantener en una o dos oraciones
PERSONALITY=Responde de forma profesional y amigable. Firma como "Equipo de Ventas - TecnoPartes S.A."
```

---

### `store_info.md`

Este documento es la base de conocimiento del asistente. El agente lo lee completo en cada ciclo y lo inyecta en el prompt junto con el correo del cliente. El modelo responde basándose exclusivamente en este contenido.

El formato de cada línea de inventario es deliberadamente simple: `- Nombre del producto: DISPONIBLE/AGOTADO, $precio`. Esta estructura hace que sea muy difícil para el modelo confundir el estado del producto — la primera palabra después de los dos puntos siempre es DISPONIBLE o AGOTADO.

El archivo puede editarse en la Pi después del arranque sin recompilar la imagen.

Ubicación: `meta-ai/recipes-ai/email-agent/files/store_info.md`

```markdown
# TecnoPartes S.A.

Telefono: +506 2234-5678 | Correo: ventas@tecnopartes.cr

SUCURSAL:
Direccion: De la Rotonda de la Hispanidad, 200 metros al este, local 4B, San Pedro, San Jose
Horario: Lunes a viernes 8:00 AM - 6:30 PM | Sabados 9:00 AM - 3:00 PM | Domingos cerrado

INVENTARIO:
- Resistencia 220 ohm 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 1k ohm 1/4W: DISPONIBLE, $0.04 por unidad
- Resistencia 100 ohm 2W: AGOTADO
- Arduino Uno R3: DISPONIBLE, $12.00 por unidad
- Arduino Nano: DISPONIBLE, $8.27 por unidad
- ESP32 DevKit V1: DISPONIBLE, $10.19 por unidad
...
```

---

### `local.conf`

`local.conf` es el archivo de configuración central del build. Define la máquina objetivo, el sistema de init, los paquetes a instalar y parámetros del sistema. `setup.sh` reemplaza el `local.conf` generado por defecto por `oe-init-build-env` con esta versión final.

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
# apuntando a America/Costa_Rica durante la construcción del rootfs
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
# tzdata es requerido por DEFAULT_TIMEZONE para crear /etc/localtime
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
IMAGE_ROOTFS_EXTRA_SPACE = "8388608"

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

Con el workspace configurado y los dos binarios copiados, compilar la imagen desde dentro del contenedor:

```bash
bitbake core-image-base
```

El entorno de Yocto ya está inicializado por `entrypoint.sh`, así que no hace falta correr `source oe-init-build-env` manualmente.

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
yocto-workspace/poky/build/tmp/deploy/images/raspberrypi5/
└── core-image-base-raspberrypi5.rootfs-YYYYMMDDHHMMSS.wic.bz2
```

Como el volumen está montado, el archivo ya es accesible directamente desde el administrador de archivos del host.

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
```

La App Password debe escribirse sin espacios. Si el error persiste, verificar que la verificación en dos pasos está activa en la cuenta de Google y que la App Password se generó correctamente.

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

---

### El agente detecta correos pero no responde

Verificar el log en detalle:

```bash
tail -100 /var/log/email-agent.log
```

Si el log termina en "Autenticación IMAP exitosa" y luego hay silencio, Ollama probablemente no había terminado de cargar el modelo. Verificar:

```bash
systemctl status ollama
curl -s http://localhost:11434/api/tags
```

Si Ollama no responde, reiniciar ambos servicios en orden:

```bash
systemctl restart ollama
sleep 60
systemctl restart email-agent
```
