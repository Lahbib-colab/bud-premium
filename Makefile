# BUD Premium — raccourcis de développement
#
#   make            compile et installe dans ~/Applications
#   make check      compile sans installer (ce que fait la CI)
#   make installer  régénère dist/Installer_BUD_Premium.command
#   make clean      efface l'installeur généré

.PHONY: all install check installer clean

all: install

install:
	@./build.sh install

check:
	@./build.sh check

installer:
	@./Tools/make-installer.sh

clean:
	@rm -f dist/*.command
	@echo "dist/ nettoyé."
