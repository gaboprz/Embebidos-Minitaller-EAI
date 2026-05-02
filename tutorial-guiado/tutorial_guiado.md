# Tutorial: Imagen Yocto con LLM en VirtualBox

Este tutorial guía la creación de una imagen personalizada con Yocto Scarthgap orientada a arquitectura x86-64. La imagen incluye Ollama con el modelo TinyLlama preinstalado, y está pensada para correr dentro de VirtualBox. 

**Tiempo estimado:** entre 3 y 5 horas (la mayor parte es compilación automática).

---

## Requisitos previos

Antes de empezar, tener instalado en la máquina host:

- **Docker Desktop** (o Docker Engine en Linux)
- **VirtualBox** (versión 6.1 o superior)
- Al menos **50 GB de espacio libre en disco**
- Al menos **8 GB de RAM** en el host
- Conexión a internet estable para descargar fuentes

---

## 1. Preparación del entorno Docker

Todo el proceso de compilación de Yocto ocurre dentro de un contenedor Docker. Esto evita instalar decenas de dependencias directamente en el sistema operativo del host y garantiza que el entorno sea idéntico para todos.

Crear una carpeta para el proyecto y dentro de ella crear el Dockerfile:

```bash
mkdir yocto-x86-tutorial
cd yocto-x86-tutorial
touch Dockerfile
```

Contenido del `Dockerfile`:

```dockerfile
FROM ubuntu:22.04

# Evita preguntas interactivas de apt durante la instalación
ENV DEBIAN_FRONTEND=noninteractive

# Dependencias requeridas por Yocto para compilar:
# compiladores, herramientas de scripting, utilidades de compresión y librerías varias
RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl-mesa0 libsdl1.2-dev \
    pylint xterm python3-subunit mesa-common-dev zstd liblz4-tool \
    python3-distutils curl locales sudo vim tmux file \
    && rm -rf /var/lib/apt/lists/*

# Yocto requiere un locale UTF-8 correcto; sin esto algunos scripts fallan
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

Construir y arrancar el contenedor:

```bash
# Construye la imagen Docker
docker build -t yocto-x86-builder .

# Crea y abre el contenedor por primera vez
# -v monta la carpeta local dentro del contenedor para que
# los archivos del build persistan aunque el contenedor se detenga
docker run -it --name yocto-x86 \
  -v $(pwd)/yocto-workspace:/home/yoctouser/yocto-workspace \
  yocto-x86-builder

# Para volver a entrar al contenedor en sesiones posteriores
docker start yocto-x86
docker exec -it yocto-x86 /bin/bash
```

---

## 2. Clonado de Poky y capas

Dentro del contenedor, clonar Poky y las capas adicionales necesarias. Poky es la distribución de referencia de Yocto: incluye BitBake (el motor de compilación) y todas las recetas base del sistema operativo.

```bash
# Reclamar propiedad de carpeta de trabajo, si no se hace, no permite ejecutar los siguientes comandos
sudo chown -R yoctouser:yoctouser /home/yoctouser/yocto-workspace

# Poky: el núcleo de Yocto con BitBake y las recetas base
git clone -b scarthgap git://git.yoctoproject.org/poky.git

cd poky

# meta-openembedded: colección de recetas extra
# Se necesita meta-oe para algunas dependencias y meta-networking para herramientas de red
git clone -b scarthgap git://git.openembedded.org/meta-openembedded

# Inicializa el entorno de build y crea la carpeta build/ con los archivos de configuración
source oe-init-build-env build
```

---

## 3. Registro de capas

`bblayers.conf` le dice a BitBake qué capas forman parte del proyecto. Sin que una capa esté registrada aquí, BitBake no puede usar ninguna receta dentro de ella.

```bash
# Recetas gráficas y de sistema: dependencias de varios paquetes
bitbake-layers add-layer ../meta-openembedded/meta-oe

# Dependencia del meta-networking
bitbake-layers add-layer ../meta-openembedded/meta-python

# Herramientas de red y cliente DHCP
bitbake-layers add-layer ../meta-openembedded/meta-networking

# Crea la capa personalizada del proyecto y la registra
# Esta capa contendrá la receta de Ollama
bitbake-layers create-layer meta-ollama
bitbake-layers add-layer ../build/meta-ollama/
```

---

## 4. Preparación de los archivos binarios

Antes de armar la estructura de la capa, hay que descargar los archivos binarios que van dentro de la receta de Ollama. Estos pasos se hacen **en el host** (fuera del contenedor), en una terminal separada.

El binario de Ollama para x86-64 se descarga de GitHub. El modelo TinyLlama se descarga usando Ollama directamente en el host y luego se empaqueta con la estructura de directorios que Ollama espera en producción.

```bash
# --- En el HOST, no dentro del contenedor ---

# Descarga el binario de Ollama para x86-64
wget https://github.com/ollama/ollama/releases/download/v0.5.7/ollama-linux-amd64.tgz

# Instala Ollama en el host para poder descargar el modelo
curl -fsSL https://ollama.com/install.sh | sh

# Descarga gemma2:2b (~1.6 MB)
ollama pull gemma2:2b

# Verifica que el modelo se descargó
ollama list

# Empaqueta los pesos del modelo con la estructura que Ollama espera:
# el tar.gz contendrá models/blobs/ y models/manifests/
# que luego se extraen en /root/.ollama/ dentro de la imagen
sudo tar -czvf ~/Escritorio/gemma2-2b-prebaked.tar.gz \
    -C /usr/share/ollama/.ollama models
```

Una vez generados, estos archivos se copian más adelante a la carpeta `files/` de la receta.

---

## 5. Estructura de la capa personalizada

La capa `meta-ollama` debe tener esta estructura antes de compilar. Hay que crear los directorios y archivos manualmente:

```
meta-ollama/
├── conf/
│   └── layer.conf          ← generado por bitbake-layers create-layer
├── COPYING.MIT             ← generado automáticamente
├── README                  ← generado automáticamente
└── recipes-ai/
    └── ollama/
        ├── files/
        │   ├── ollama-linux-amd64.tgz      ← descargado en el paso anterior
        │   ├── ollama.service              ← creado a continuación
        │   └── tinyllama-prebaked.tar.gz   ← generado en el paso anterior
        └── ollama_1.0.bb                   ← creado a continuación
```

Crear los directorios necesarios:

```bash
# Dentro del contenedor, estando en poky/build/
mkdir -p meta-ollama/recipes-ai/ollama/files
```

---

## 6. Contenido de los archivos

### `layer.conf`

`layer.conf` es el archivo que define la identidad de la capa ante BitBake. Cada capa necesita uno. `bitbake-layers create-layer` ya lo genera con valores básicos; hay que editarlo para agregar la dependencia con `core` y declarar compatibilidad con Scarthgap.

Ubicación: `meta-ollama/conf/layer.conf`

```bash
# Agrega esta capa al BBPATH para que BitBake encuentre sus archivos
BBPATH .= ":${LAYERDIR}"

# Registra todos los archivos .bb y .bbappend dentro de carpetas recipes-*
BBFILES += "${LAYERDIR}/recipes-*/*/*.bb \
            ${LAYERDIR}/recipes-*/*/*.bbappend"

# Nombre único de esta capa
BBFILE_COLLECTIONS += "meta-ollama"

# Patrón que identifica que un archivo pertenece a esta capa
BBFILE_PATTERN_meta-ollama = "^${LAYERDIR}/"

# Prioridad 10: si hay conflicto con una receta de otra capa, gana esta
BBFILE_PRIORITY_meta-ollama = "10"

# Esta capa requiere que la capa "core" esté presente
LAYERDEPENDS_meta-ollama = "core"

# Declara compatibilidad con Yocto Scarthgap
LAYERSERIES_COMPAT_meta-ollama = "scarthgap"
```

---

### `ollama.service`

Este archivo le dice a systemd cómo arrancar Ollama: cuándo hacerlo, con qué usuario y qué variables de entorno necesita. Sin las variables `HOME` y `OLLAMA_MODELS`, Ollama no encuentra los modelos aunque estén instalados, ya que cuando corre como servicio systemd no hereda las variables del usuario.

Ubicación: `meta-ollama/recipes-ai/ollama/files/ollama.service`

```ini
[Unit]
Description=Ollama - Local LLM Runner
# Arranca después de que el sistema esté listo
After=multi-user.target

[Service]
ExecStart=/usr/bin/ollama serve
User=root

# Ollama busca los modelos en $HOME/.ollama/models
# Un servicio systemd no hereda el HOME del usuario por defecto
Environment=HOME=/root

# Ruta explícita a los modelos, refuerza que no haya confusión de rutas
Environment=OLLAMA_MODELS=/root/.ollama/models

# Escucha en todas las interfaces; permite consultar la API desde el host
Environment=OLLAMA_HOST=0.0.0.0:11434

# Sin límite al detener: un modelo cargado puede tardar en terminar
TimeoutStopSec=infinity

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

### `ollama_1.0.bb`

Esta es la receta que empaqueta Ollama dentro de la imagen. Se encarga de instalar el binario, registrar el servicio systemd para que arranque automáticamente, y colocar los pesos del modelo donde Ollama los busca.

El tgz de Ollama para amd64 incluye runners para CUDA (NVIDIA) y ROCm (AMD). En una máquina virtual sin GPU dedicada solo se usa la inferencia por CPU, que en las versiones modernas de Ollama está integrada dentro del binario principal. Por eso no se instala el contenido de `lib/ollama/`.

Ubicación: `meta-ollama/recipes-ai/ollama/ollama_1.0.bb`

```bash
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

# "inherit systemd" activa el soporte para instalar y habilitar servicios systemd
inherit systemd

# Nombre del archivo .service que systemd debe manejar
SYSTEMD_SERVICE:${PN} = "ollama.service"

# "enable" hace que el servicio arranque en cada boot sin necesidad de correr systemctl enable
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Instala el binario de Ollama en /usr/bin/
    # La inferencia por CPU está integrada directamente en este binario
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/ollama-release/bin/ollama ${D}${bindir}/ollama

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
"

# El binario viene precompilado y sin símbolos de debug
# Sin esta línea, BitBake lanzaría un error de QA al detectarlo
INSANE_SKIP:${PN} = "already-stripped"
```

---

## 7. Configuración del build: `local.conf`

`local.conf` es el archivo central de configuración del build. Aquí se define la máquina objetivo (`genericx86-64`), el sistema de init, los paquetes a instalar y parámetros del sistema.

Ubicación: `poky/build/conf/local.conf`

Reemplazar el contenido generado por defecto con el siguiente:

```bash
# ================================================================
#  local.conf — Yocto Scarthgap | genericx86-64 | VirtualBox
# ================================================================

# ----------------------------------------------------------------
# 1. MÁQUINA Y DISTRIBUCIÓN
# ----------------------------------------------------------------
# genericx86-64: target de 64 bits para PC y máquinas virtuales
# El BSP viene incluido en meta-yocto-bsp, no necesita capa extra
MACHINE = "genericx86-64"

# poky es la distribución de referencia de Yocto
DISTRO = "poky"

# IPK es el formato de paquetes estándar en imágenes embebidas
PACKAGE_CLASSES = "package_ipk"

# ----------------------------------------------------------------
# 2. SISTEMA DE INIT: systemd
# ----------------------------------------------------------------
# Reemplaza SysVinit por systemd, necesario para manejar servicios
# como ollama.service de forma automática al encender la VM
DISTRO_FEATURES:append = " systemd"

# usrmerge es requerido por systemd en Scarthgap
# Sin esto, systemd no puede proveer udev y algunos paquetes no se compilan
DISTRO_FEATURES:append = " usrmerge"

VIRTUAL-RUNTIME_init_manager = "systemd"
DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"

# ----------------------------------------------------------------
# 3. IMAGE FEATURES
# ----------------------------------------------------------------
# empty-root-password: permite hacer login como root sin contraseña
EXTRA_IMAGE_FEATURES += "empty-root-password"

# ----------------------------------------------------------------
# 4. PAQUETES — SISTEMA BASE Y RED
# ----------------------------------------------------------------
IMAGE_INSTALL:append = " \
    bash \
    dhcpcd \
    iproute2 \
    procps \
    coreutils \
    ca-certificates \
    libstdc++ \
    libgcc \
    libgomp \
"

# ----------------------------------------------------------------
# 5. PAQUETE — OLLAMA
# ----------------------------------------------------------------
IMAGE_INSTALL:append = " ollama"

# ----------------------------------------------------------------
# 6. FORMATO DE IMAGEN
# ----------------------------------------------------------------
# wic: genera una imagen de disco completa con tabla de particiones
# Es el formato necesario para convertir luego a vmdk para VirtualBox
IMAGE_FSTYPES = "wic.vmdk wic"

# Espacio extra en el rootfs:
# TinyLlama ocupa ~600 MB; con 4 GB hay margen para el modelo y los logs
# Unidad: KB. 4194304 KB = 4 GB
IMAGE_ROOTFS_EXTRA_SPACE = "4194304"

# ----------------------------------------------------------------
# 7. RENDIMIENTO DE COMPILACIÓN
# ----------------------------------------------------------------
# Ajustar estos valores según los núcleos disponibles en el host
# Con una máquina de 4 núcleos: BB_NUMBER_THREADS = "4", PARALLEL_MAKE = "-j 4"
BB_NUMBER_PARSE_THREADS ?= "1"
BB_NUMBER_THREADS ?= "2"
PARALLEL_MAKE ?= "-j 2"

# ----------------------------------------------------------------
# 8. DIRECTORIOS DE CACHÉ
# ----------------------------------------------------------------
# Coloca downloads y sstate-cache fuera del directorio de build
# para que persistan entre builds y ahorren tiempo de compilación
DL_DIR ?= "${TOPDIR}/../downloads"
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache"
TMPDIR = "${TOPDIR}/tmp"

CONF_VERSION = "2"

# ----------------------------------------------------------------
# 9. FIXES DE BUILD
# ----------------------------------------------------------------
# Desactiva la generación de manifiestos SPDX (licencias)
# Causan colisiones de sstate si se cambian DISTRO_FEATURES entre builds
INHERIT:remove = "create-spdx"
```

---

## 8. Copiar los archivos binarios al contenedor

Antes de compilar, copiar los archivos descargados en el paso 4 a la carpeta `files/` de la receta de `ollama` dentro del contenedor.


---

## 9. Compilación

Con todo en su lugar, compilar la imagen. La primera vez tarda entre 3 y 5 horas porque compila el toolchain y todos los paquetes desde el código fuente. Las compilaciones posteriores son mucho más rápidas gracias al sstate-cache.

```bash
# Dentro del contenedor, desde la carpeta poky/
source oe-init-build-env build

# Compila la imagen
bitbake core-image-base
```

Al terminar sin errores, la imagen aparece en:

```
poky/build/tmp/deploy/images/genericx86-64/
└── core-image-base-genericx86-64.wic
```

---

## 10. Importar la imagen a VirtualBox

La imagen generada es un disco en formato `.wic` (imagen de disco raw). VirtualBox trabaja con el formato `.vmdk`, así que hay que convertirla. Esta conversión se hace en el **host**, fuera del contenedor.

Primero, copiar la imagen fuera del contenedor si está montada en el volumen compartido. Si no, copiarla manualmente:

```bash
# Desde el host, en la carpeta del proyecto
cp ./yocto-workspace/poky/build/tmp/deploy/images/genericx86-64/core-image-base-genericx86-64.wic.vmdk .
```

---

## 11. Crear la máquina virtual en VirtualBox

Abrir VirtualBox y crear una nueva máquina virtual con estas configuraciones:

**Configuración básica:**
- **Nombre:** `Yocto-Ollama` (o cualquier nombre)
- **Tipo:** Linux
- **Versión:** Other Linux (64-bit)

**Hardware:**
- **RAM:** mínimo 4096 MB (4 GB). Con menos, TinyLlama puede fallar al cargar
- **CPUs:** 2 o más

**Disco duro:**
- Seleccionar **"Usar un archivo de disco duro existente"**
- Navegar y seleccionar el archivo `core-image-base-genericx86-64.vmdk` generado en el paso anterior

**Red:**
- Mantener el adaptador en modo **NAT** (configuración por defecto)

Guardar y arrancar la máquina virtual.

---

## 12. Primer uso: login y prueba del LLM

Al arrancar la VM, aparece el prompt de login de la consola. Ingresar como root sin contraseña:

```
raspberrypi5 login: root
```

> El hostname puede ser diferente dependiendo de la configuración, pero el login es siempre `root`.

Verificar que Ollama arrancó correctamente:

```bash
# Ver el estado del servicio
systemctl status ollama

# Debe mostrar: Active: active (running)
```

Verificar que el modelo está disponible:

```bash
ollama list
# Debe mostrar: tinyllama con su ID y tamaño (~600 MB)
```

Probar el modelo:

```bash
# Enviar un prompt directo y recibir una respuesta
ollama run tinyllama "Explain what a neural network is in two sentences"

# Abrir un chat interactivo con el modelo
ollama run tinyllama
# Para salir del chat: escribir /bye y Enter
```

---

## Troubleshooting

### El comando VBoxManage no se encuentra

En Linux, VBoxManage está en `/usr/bin/VBoxManage` si VirtualBox se instaló con el paquete del sistema. En macOS está en `/usr/local/bin/VBoxManage`. Verificar con:

```bash
which VBoxManage
# o
VBoxManage --version
```

Si no aparece, agregar la carpeta de VirtualBox al PATH o usar la ruta completa.

---

### La VM no arranca (pantalla negra o error de bootloader)

Significa que la conversión del `.wic` a `.vmdk` no se completó bien, o que el archivo `.wic` estaba corrupto. Verificar el tamaño del archivo generado:

```bash
ls -lh core-image-base-genericx86-64.wic
# Debe pesar varios gigabytes, no cero ni unos pocos KB
```

Si el tamaño es correcto, intentar la conversión con `qemu-img` como alternativa a VBoxManage:

```bash
# Requiere tener qemu-utils instalado en el host
qemu-img convert -f raw -O vmdk \
    core-image-base-genericx86-64.wic \
    core-image-base-genericx86-64.vmdk
```

---

### Ollama aparece como inactivo

Si `systemctl status ollama` muestra el servicio inactivo o fallido:

```bash
# Ver los logs del servicio para saber qué falló
journalctl -u ollama -n 50

# Intentar arrancarlo manualmente
systemctl start ollama

# Ver el estado después de arrancarlo
systemctl status ollama
```

---

### Ollama arranca pero el modelo falla al correr

```
Error: llama runner process no longer running: -1
```

La causa más común es que los pesos del modelo no están en la ruta correcta. Verificar:

```bash
ls /root/.ollama/models/
# Debe mostrar las carpetas: blobs/  manifests/
```

Si está vacío, el paso de instalación del modelo dentro de la receta no se ejecutó bien. La solución más rápida en este caso es descargar el modelo directamente desde la VM si tiene internet:

```bash
# Dentro de la VM, si hay conexión de red
ollama pull tinyllama
```

---

### La VM no obtiene conexión de red

Si Ollama necesita conectarse (por ejemplo, para descargar modelos), verificar el estado de red:

```bash
# Ver las interfaces de red y sus IPs
ip addr show

# Ver el estado del cliente DHCP
systemctl status dhcpcd

# Si dhcpcd está inactivo, arrancarlo
systemctl start dhcpcd

# Esperar unos segundos y volver a ver la IP
ip addr show eth0
```

---

### El build falla con error de caché (sstate)

Si un build previo falló a mitad y el siguiente también falla con errores de "File exists" o conflictos de sstate, limpiar la caché de la receta problemática:

```bash
# Reemplazar "nombre-receta" por el paquete que falla (ej: ollama, core-image-base)
bitbake -c cleansstate nombre-receta
bitbake core-image-base
```

Si el problema persiste, limpiar el directorio de trabajo de la imagen completa:

```bash
rm -rf poky/build/tmp/work/genericx86-64-poky-linux/core-image-base/
bitbake core-image-base
```
