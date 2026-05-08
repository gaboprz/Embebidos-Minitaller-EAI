# Imagen base: Ubuntu 22.04 LTS
FROM ubuntu:22.04

# Evita que apt lance preguntas interactivas durante la instalación
# de paquetes.
ENV DEBIAN_FRONTEND=noninteractive

# Instala todas las dependencias que Yocto necesita para compilar.
RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl-mesa0 libsdl1.2-dev \
    pylint xterm python3-subunit mesa-common-dev zstd liblz4-tool \
    python3-distutils curl locales sudo vim tmux file mc \
    && rm -rf /var/lib/apt/lists/*

# Yocto requiere un locale UTF-8 configurado correctamente.
# Configuran el idioma y la codificación de los caracteres
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Yocto no puede correr como root por razones de seguridad.
# Se crea un usuario normal llamado yoctouser con UID/GID 1000,
# que coincide con el UID típico del usuario del host en Linux.
ARG USERNAME=yoctouser
ARG USER_UID=1000
ARG USER_GID=1000

RUN groupadd --gid $USER_GID $USERNAME \
    # Crea el usuario con home en /home/yoctouser y shell bash
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    # Permisos sudo sin contraseña: necesario para algunos pasos del build
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    # 0440: el archivo de sudoers debe ser solo lectura para funcionar
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Copia los scripts al home del usuario, fuera del volumen montado.
# --chown=yoctouser:yoctouser asegura que el usuario tenga permisos
# de lectura y ejecución sobre sus propios scripts.
COPY --chown=yoctouser:yoctouser setup.sh     /home/yoctouser/setup.sh
COPY --chown=yoctouser:yoctouser entrypoint.sh /home/yoctouser/entrypoint.sh

# Hace ambos scripts ejecutables.
RUN chmod +x /home/yoctouser/setup.sh /home/yoctouser/entrypoint.sh

# Cambia al usuario sin privilegios para el resto del build.
USER yoctouser

# Directorio de trabajo del contenedor: donde vive el workspace de Yocto.
WORKDIR /home/yoctouser/yocto-workspace

# El entrypoint se ejecuta cada vez que se arranca el contenedor.
# Detecta si es el primer arranque (volumen vacío) y ejecuta el setup,
# o inicializa el entorno de Yocto y abre bash si ya está configurado.
ENTRYPOINT ["/home/yoctouser/entrypoint.sh"]
