# BUD Premium — raccourcis de développement
#
#   make            compile et installe dans ~/Applications
#   make check      compile sans installer (ce que fait la CI)
#   make installer  régénère dist/Installer_BUD_Premium.command
#
# Les scripts sont appelés par « bash », jamais par « ./ » : le dépôt
# fonctionne même si le bit d'exécution a été perdu en route.
#   make clean      efface l'installeur généré

.PHONY: all install check installer clean

all: install

install:
	@bash build.sh install

check:
	@bash build.sh check

installer:
	@bash Tools/make-installer.sh

clean:
	@rm -f dist/*.command
	@echo "dist/ nettoyé."
