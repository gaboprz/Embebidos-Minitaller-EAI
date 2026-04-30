# ================================================================
#  meta-custom/recipes-graphics/xorg-app/xterm_%.bbappend
#
#  Fix: xterm 388 no tiene el target 'install-desktop' en su Makefile,
#  pero la receta de meta-oe lo llama como segundo paso del do_install,
#  causando que el build falle con "No rule to make target".
#
#  Solución: sobreescribir do_install para ejecutar solo "make install"
#  y crear manualmente el directorio de .desktop files vacío.
#  En una imagen embebida sin launcher de escritorio, el .desktop
#  no es necesario.
# ================================================================

# meta-ai/recipes-graphics/xorg-app/xterm_%.bbappend

# meta-ai/recipes-graphics/xorg-app/xterm_%.bbappend

# Deshabilitamos las utilidades de escritorio desde la raíz
EXTRA_OECONF:append = " --disable-desktop-utils"

# Forzamos a que el comando de meta-oe no haga nada si llega a llamarse
do_install:append() {
    # Creamos un archivo dummy si es que meta-oe lo busca, 
    # pero no dejamos que ejecute el 'make install-desktop'
    :
}
