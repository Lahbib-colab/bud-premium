# BUD Premium

Compagnon de bureau natif pour macOS, de Monterey à Sequoia et au-delà, sur Intel comme sur Apple Silicon. Un petit compagnon blanc vit dans le notch, suit votre souris du regard, et déplie à la demande un tableau de bord de seize panneaux.

Écrit en Swift et AppKit pur. Aucune dépendance externe, aucune télémétrie, aucune donnée qui quitte votre Mac sauf celles que vous adressez explicitement à Google.

**Version 23.2** · by Lahbib.AI

[![build](https://github.com/Lahbib-colab/bud-premium/actions/workflows/build.yml/badge.svg)](https://github.com/Lahbib-colab/bud-premium/actions/workflows/build.yml)

---

## Installation

### Depuis le dépôt

```bash
git clone https://github.com/Lahbib-colab/bud-premium.git
cd bud-premium
make
```

Les scripts s'invoquent par `bash`, jamais par `./` : le dépôt reste utilisable même si le bit d'exécution a été perdu (c'est le cas de tout fichier ajouté depuis l'interface web de GitHub).

`make` compile les sources et installe `BUD.app` dans `~/Applications`, puis le lance. Les autres cibles :

| Commande | Effet |
|---|---|
| `make` · `bash build.sh install` | compile et installe |
| `make check` · `bash build.sh check` | compile sans rien installer — ce que vérifie la CI |
| `make installer` | régénère `dist/Installer_BUD_Premium.command` |

### Depuis l'installeur en un fichier

Pour une machine sans le dépôt, `dist/Installer_BUD_Premium.command` embarque les sources et le script de compilation :

```bash
bash ~/Downloads/Installer_BUD_Premium.command
```

`bash` plutôt qu'un double-clic : un fichier téléchargé porte l'attribut de quarantaine et perd son bit d'exécution, ce qui fait échouer le double-clic avec l'erreur −10810. L'invoquer par `bash` contourne les deux.

L'installeur écrit les sources dans `~/Library/Application Support/BUD-Assistant/src/`, y dépose `build.sh`, puis l'appelle. **La logique de compilation n'existe qu'une fois**, dans `build.sh` à la racine du dépôt : l'installeur ne fait que de l'emballage, et la CI teste donc exactement le code qui tournera chez vous.

Votre `state.json` est sauvegardé avant toute écriture.

### Prérequis

Les outils en ligne de commande de Xcode, avec un **SDK macOS 11 ou plus récent** — pas seulement un Mac récent. Un Mac mis à jour depuis Catalina peut tourner sous Sequoia avec des outils de 2019 ; BUD a besoin d'API apparues avec Big Sur. `build.sh` le vérifie avant toute chose et vous dit quoi faire.

```bash
xcode-select -p            # quels outils sont sélectionnés
xcrun --show-sdk-version   # doit afficher 11 ou plus
```

Si le SDK est antérieur à 11 :

```bash
sudo rm -rf /Library/Developer/CommandLineTools
sudo xcode-select --install
```

---

## Organisation du dépôt

```
bud-premium/
├── Sources/                 les 19 fichiers Swift de l'application
├── Tools/
│   ├── MakeIcon.swift       générateur d'icône, compilé seul
│   ├── bud-ask              passerelle agents en ligne de commande
│   └── make-installer.sh    fabrique dist/ depuis Sources/ + build.sh
├── build.sh                 compilation et installation — source unique
├── Makefile                 raccourcis
├── version.json             canal de mise à jour interrogé par BUD
├── dist/                    installeur en un fichier, versionné
└── .github/workflows/       compilation vérifiée sur macOS 14 et 15
```

`MakeIcon.swift` vit dans `Tools/` et non dans `Sources/` pour une raison précise : il contient du code au niveau racine, ce que Swift n'autorise que dans `main.swift` ou dans un fichier compilé seul. Le laisser dans `Sources/` casserait la compilation de l'application.

### Mises à jour

BUD interroge l'API des releases de ce dépôt, une fois par jour et à la demande depuis la carte « À propos ». La release est la source de vérité : elle porte à la fois le numéro de version et les installeurs, donc rien à tenir en parallèle.

Le bouton **télécharge et installe**. Il n'ouvre plus de page web : BUD récupère l'archive, vérifie qu'elle contient bien son architecture, remplace le paquet et redémarre. Une confirmation précède toujours le remplacement, et un bouton « Voir les notes » permet de lire d'abord.

Une application ne peut pas se réécrire pendant qu'elle tourne. Le remplacement est donc confié à un petit script qui attend la fin de BUD, échange les paquets, puis **restaure l'ancien si le nouveau ne démarre pas**. Vos réglages, notes et rappels vivent ailleurs et ne sont pas touchés.

### Publier une version

Modifiez `budVersion` dans `Sources/BudCore.swift`, lancez `make installer`, committez, poussez. Aucun tag à créer : le workflow compare le numéro aux releases existantes et publie s'il est nouveau.

La CI compile alors un **binaire universel** — et c'est le point qui ne se devine pas. Les machines GitHub sont en arm64 ; un installeur compilé tel quel ne démarrerait pas sur un Mac Intel. `build.sh --universal` compile les deux architectures depuis la même machine et les réunit avec `lipo`, et la publication est refusée si l'une des deux tranches manque.

Quatre fichiers sont joints à chaque release :

| Fichier | Pour qui |
|---|---|
| `BUD-Premium-x.y.dmg` | vous, à glisser dans Applications |
| `BUD-Premium-x.y.zip` | l'updater de BUD, automatiquement |
| `Installer_BUD_Premium-x.y.command` | compilation sur votre machine, sans blocage Gatekeeper |
| `SHA256.txt` | les empreintes |

Le `.dmg` et le `.zip` ne sont ni signés ni notariés par Apple. Au premier lancement depuis le `.dmg`, macOS bloque l'application : Réglages Système → Confidentialité et sécurité → « Ouvrir quand même ». Une seule fois. L'installeur par les sources évite entièrement ce blocage, puisqu'il compile sur place — c'est pourquoi il reste publié. Le bouton de mise à jour, lui, n'est jamais concerné : c'est BUD qui écrit le paquet et retire l'attribut de quarantaine, pas le Finder.

Un canal personnalisé à l'ancien format reste accepté, par le bouton **Canal** :

```json
{
  "version": "23.2",
  "notes": "Correctifs d'affichage",
  "url": "https://exemple.com/BUD-Premium.zip"
}
```

---

## Ce que BUD ne fait pas

Par honnêteté, autant le dire clairement.

Le chat n'est pas un modèle de langage : c'est un moteur d'intentions à base de mots-clés. Il comprend bien ce qu'il connaît, et répond par une aide quand il ne saisit pas.

L'analyse de courrier n'est pas un antivirus. BUD ne télécharge pas les pièces jointes et n'inspecte pas leur contenu : il reconnaît les formes d'attaque, pas les signatures de logiciels malveillants. Pour les fichiers déjà téléchargés, c'est Gatekeeper — l'outil d'Apple — qui tranche, pas BUD. Un message classé sain peut être malveillant, et un message suspect peut être parfaitement légitime : le verdict vous informe, il ne décide pas à votre place.

L'égaliseur ne mesure rien. macOS n'expose aucun niveau audio en sortie sans capturer le flux, ce que BUD ne fait pas. Les barres et le rythme sont synthétiques, pilotés par des sinusoïdes de fréquences premières entre elles pour éviter tout motif qui se répète visiblement. C'est un signe de vie, pas un instrument de mesure.

L'appairage par téléphone ne peut pas se passer entièrement de copier-coller en mode OAuth : Google interdit son *device flow* pour le courrier. La voie « mot de passe d'application » est, elle, complète — seize lettres à recopier.

L'application n'est ni signée ni notarisée : elle est compilée sur votre machine, à partir de sources que vous pouvez lire intégralement.
