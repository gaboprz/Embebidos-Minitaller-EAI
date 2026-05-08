#!/bin/bash
# ================================================================
#  entrypoint.sh — Se ejecuta cada vez que arranca el contenedor.
#
#  Primera vez (volumen vacío, sin carpeta poky/):
#    Ejecuta setup.sh que clona Poky y las capas, registra las capas,
#    crea meta-ai y escribe todas las recetas directamente en el
#    volumen del host. Al terminar, todo es visible desde el
#    administrador de archivos del host en yocto-workspace/.
#
#  Veces siguientes (poky/ ya existe):
#    Salta el setup, inicializa el entorno de Yocto y abre bash
#    con el entorno listo para correr bitbake directamente.
# ================================================================

WORKSPACE=/home/yoctouser/yocto-workspace

if [ ! -d "$WORKSPACE/poky" ]; then
    echo "========================================================"
    echo "  Primera ejecución: configurando el workspace..."
    echo "  Clonando repos y creando recetas. Tarda varios minutos."
    echo "========================================================"
    /home/yoctouser/setup.sh
    echo "========================================================"
    echo "  Setup completo."
    echo "  Copia los binarios pesados y luego corre:"
    echo "  bitbake core-image-base"
    echo "========================================================"
else
    echo ">>> Workspace ya configurado. Iniciando entorno de Yocto..."
fi

# Inicializa el entorno de Yocto: agrega BitBake al PATH y define
# las variables de entorno necesarias para compilar.
# Después del >, lo que hace es suprimir el mensaje impreso por Yocto
cd $WORKSPACE/poky
source oe-init-build-env build > /dev/null 2>&1

# Abre bash interactivo con el entorno ya inicializado.
# El usuario puede correr bitbake directamente al entrar.
exec /bin/bash
