# BUD Premium

Compagnon de bureau natif pour macOS, de Monterey à Sequoia et au-delà, sur Intel comme sur Apple Silicon. Un petit compagnon blanc vit dans le notch, suit votre souris du regard, et déplie à la demande un tableau de bord de seize panneaux.

Écrit en Swift et AppKit pur. Aucune dépendance externe, aucune télémétrie, aucune donnée qui quitte votre Mac sauf celles que vous adressez explicitement à Google.

**Version 22** · by Lahbib.AI

[![build](https://github.com/Lahbib-colab/bud-premium/actions/workflows/build.yml/badge.svg)](https://github.com/Lahbib-colab/bud-premium/actions/workflows/build.yml)

---

## Installation

### Depuis le dépôt

```bash
git clone https://github.com/Lahbib-colab/bud-premium.git
cd bud-premium
make
```

`make` compile les sources et installe `BUD.app` dans `~/Applications`, puis le lance. Les autres cibles :

| Commande | Effet |
|---|---|
| `make` · `./build.sh install` | compile et installe |
| `make check` · `./build.sh check` | compile sans rien installer — ce que vérifie la CI |
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
├── Sources/                 les 18 fichiers Swift de l'application
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

BUD interroge `version.json` à la racine de ce dépôt, via `raw.githubusercontent.com`. Pour publier une version : modifiez `budVersion` dans `Sources/BudCore.swift`, lancez `make installer`, puis mettez `version.json` à jour et committez le tout. Le numéro de version vient de `BudCore.swift` — ni le `Makefile` ni le plist ne le dupliquent.

---

---

## Compatibilité

| | |
|---|---|
| Systèmes | macOS 12 Monterey → 15 Sequoia et au-delà |
| Processeurs | Intel (x86_64) et Apple Silicon (arm64) |
| Cible de déploiement | 12.0 — compatible vers l'avant |

L'installeur compile sur votre machine, pour son architecture (`uname -m`), et appose une signature ad hoc. Il n'y a pas de binaire universel à télécharger : le binaire produit est natif, jamais émulé.

**Ce qui change sur Sequoia et après**

La chaîne Xcode récente utilise Swift 6. L'installeur passe explicitement `-swift-version 5` : sans cela, un futur changement de mode par défaut basculerait la compilation en concurrence stricte, que ce code ne vise pas.

Toutes les compilations passent par `xcrun`, jamais par le chemin résolu de `swiftc`. C'est `xcrun` qui positionne `SDKROOT` ; appeler le binaire directement donne un compilateur incapable de trouver sa bibliothèque standard. Si `xcrun` lui-même est muet, l'installeur se rabat sur le `swiftc` du PATH, et si la chaîne ne compile rien du tout, il bascule sur un Xcode complet s'il en trouve un.

Il sonde aussi l'orthographe de la cible avant de compiler. Les chaînes récentes veulent `x86_64-apple-macos12.0`, les anciennes `macosx12.0`, et une chaîne d'avant Big Sur refuse les deux — l'installeur essaie l'une puis l'autre, et retombe sinon sur `MACOSX_DEPLOYMENT_TARGET`. Il neutralise également la variable `TOOLCHAINS`, qu'une chaîne Swift tierce installée à côté viendrait fausser.

Le diagnostic s'exécute **avant** que l'installeur ne touche à quoi que ce soit : un échec laisse votre installation précédente intacte.

La signature ad hoc (`codesign --sign -`) est **obligatoire pour exécuter du arm64**. Elle donne aussi au système une identité stable pour les autorisations. Attention : cette identité change à chaque recompilation, donc macOS redemandera l'Automatisation et l'Accessibilité après chaque mise à jour. C'est la contrepartie d'une application non notariée.

macOS 15 a retiré le contournement par clic droit → Ouvrir pour les applications non signées ; il faut passer par Réglages Système → Confidentialité et sécurité → « Ouvrir quand même ». BUD n'est pas concerné : il est compilé sur place et l'installeur efface l'attribut de quarantaine. En revanche l'installeur `.command`, lui, est téléchargé et donc marqué — c'est la raison du `bash ~/Downloads/…` plutôt qu'un double-clic.

macOS 15 a introduit la confidentialité du réseau local. BUD ne la déclenche pas : selon la note technique TN3179 d'Apple, accepter une connexion TCP entrante ne demande aucune autorisation, et le guetteur OAuth est de toute façon restreint à 127.0.0.1. Les échanges avec Gmail sortent vers Internet, pas vers le réseau local.

---

## Le notch

BUD n'occupe qu'un seul objet à l'écran, qui grandit et rétrécit sur place.

| État | Taille | Contenu |
|---|---|---|
| **Replié** | 214 × 36 | La brioche, l'heure, une pastille d'alerte |
| **Aperçu** | 470 × 160 | Salutation, date, disque libre, agents, focus, horloge |
| **Approbation** | 600 × 210 | Carte de validation avec boutons cliquables |
| **Ouvert** | 880 × 610 | Le tableau de bord complet |

Survolez le haut de l'écran pour l'aperçu, cliquez pour ouvrir. Il se replie à la sortie du curseur, sur Échap, ou au clic ailleurs. Trois filets de sécurité garantissent le repli, dont une vérification de la position réelle du curseur chaque seconde.

Devant une application en plein écran, BUD s'efface complètement — réglage désactivable.

---

## Le personnage

Un squircle blanc aux coins très arrondis, deux joues rose pastel, deux yeux ronds et une bouche en « O » avec la langue rose. Dessiné entièrement en courbes de Bézier, net du 16 px au 1024 px.

**Trois habillages**, au choix dans Compagnon → **Habillage** :

- *À plat* — la coque blanche et son liseré interne.
- *Nacré* — cadre champagne dégradé, coque nacrée en dégradé radial, reflet spéculaire et signature « BUD » gravée.
- *Métal* — une tête de robot : coque ardoise, cadre argenté, écran facial sombre et yeux carrés lumineux avec halo. Un reflet balaie lentement la coque. Les yeux prennent votre couleur d'accent, sauf si elle est trop sombre pour l'écran noir — BUD retombe alors sur le cyan. En alerte ils virent au rose, avec sourcils froncés et symbole de colère pulsant.

**Animations permanentes** — flottement vertical sinusoïdal, respiration qui dilate le corps de 1,4 % en largeur et le comprime d'autant en hauteur, regard qui suit le curseur avec lissage exponentiel (et une curiosité lente au repos), clignements à intervalle aléatoire, ombre au sol qui se resserre quand le compagnon monte.

**Au clic** — ressorts d'écrasement et de saut amortis en exponentielle, puis l'enchaînement clin d'œil → sourire.

**Six humeurs** — standard (la bouche en « O »), souriant (demi-lune ouverte), clin d'œil, en colère (paupières inclinées, sourcils froncés, symbole pulsant, tremblement), perdu (spirales contrarotatives et gouttes de sueur qui tombent en boucle), endormi après 23 h.

---

## Les panneaux

### Essentiel

**Compagnon** — conseils selon trois personnalités (Zen, Coach, Rigolo), blagues, salutations. La carte « À propos » affiche la version et vérifie les mises à jour.

**Chat** — conversation en langage naturel avec BUD. Moteur d'intentions local, sans modèle de langage, sans réseau : instantané et hors ligne. Il comprend et exécute :

```
« Combien d'espace me reste-t-il ? »
« Vide la corbeille »  ·  « Nettoie les résidus »
« Éjecte les disques externes »
« Lance un focus de 40 minutes »  ·  « Arrête le focus »
« Note : rappeler le garage »
« Copie le snippet signature »
« Mes mails »  ·  « Envoie un mail à paul@exemple.fr pour dire bonjour »
« Rappelle-moi d'appeler Paul à 17h30 »  ·  « Mes rappels »
« Musique »  ·  « Morceau suivant »  ·  « Monte le volume »  ·  « Alexa »
« Ouvre les téléchargements »  ·  « L'heure »  ·  « Une blague »
```

**Agents** — vos agents IA demandent une validation et BUD la présente dans le notch. Protocole fichier, sans dépendance :

```bash
"$HOME/Library/Application Support/BUD-Assistant/bud-ask" \
  "Déployer ?" "3 fichiers vers main" "$PWD"
# bloque jusqu'à réponse · 0 = validé, 1 = refusé, 2 = délai dépassé
```

L'agent dépose `agents/<id>.json`, BUD écrit `<id>.reply`. Surveillance par `DispatchSource` sur le dossier, doublée d'un sondage de sécurité. À l'arrivée d'une demande, la brioche passe en alerte, le notch s'ouvre en carte **Autoriser / Refuser / Détails**.

### Communication

**Courrier** — trois voies de connexion, par ordre de priorité :

1. **Google OAuth 2.0 avec PKCE** — flux complet, écoute locale sur 127.0.0.1, authentification IMAP et SMTP en XOAUTH2. Jetons dans le trousseau macOS. Nécessite un identifiant client de type *application de bureau* et l'étendue `https://mail.google.com/`.
2. **Mot de passe d'application** — IMAP sur 993 et SMTP sur 465, clients écrits à la main sur Network.framework.
3. **Mail.app** — par AppleScript, si aucun compte n'est relié.

La boîte affiche les huit derniers messages, lus ou non, chacun sur une ligne cliquable : expéditeur, objet, date, pastille de non-lu, trombone s'il y a une pièce jointe, et un liseré de couleur donnant le verdict de l'analyse. Trois compteurs en tête : non lus, suspects, voie utilisée.

**Répondre** — sélectionnez un message, BUD préfixe l'objet par `Re:`, cite le corps d'origine et vise la bonne adresse. Le `Message-ID` est repris en `In-Reply-To` et `References`, sans quoi votre réponse arriverait comme un message isolé au lieu de se ranger dans le fil. Si le `Reply-To` diverge du `From`, BUD garde le `From` : c'est exactement la manœuvre qu'un hameçonneur utilise pour détourner la réponse. Répondre à un message classé dangereux demande une confirmation — répondre prouve à l'expéditeur que votre adresse est vivante.

**Analyse de hameçonnage** — locale, sans réseau, sans modèle de langage. Aucun message, aucune adresse, aucun lien ne quitte votre Mac. BUD lit d'abord les verdicts que le serveur a déjà écrits (SPF, DKIM, DMARC), puis applique ses propres règles :

| Signal | Poids |
|---|---|
| DMARC en échec | 45 |
| SPF en échec · DKIM invalide | 30 · 25 |
| Nom affiché annonçant une autre adresse que la vraie | 32 |
| Marque citée dont le domaine ne suit pas (29 marques françaises) | 30 |
| Domaine en punycode, alphabets mélangés | 35 · 30 |
| Lien affichant un domaine et menant à un autre | 38 |
| Lien vers une adresse IP brute · raccourcisseur | 28 · 12 |
| Pièce jointe exécutable · double extension · macros | 65 · 50 · 45 |
| Nom truqué par inversion d'écriture | 60 |
| Vocabulaire d'urgence, demande d'identifiants avec lien | jusqu'à 55 |

À partir de 25 le message est *suspect*, à partir de 60 *dangereux*. Le barème a été éprouvé sur des cas réels : trois messages légitimes (notification Google, infolettre commerciale, facture avec PDF) sortent à zéro, cinq hameçonnages courants en France — faux Ameli, faux Chronopost, fausse facture `.exe`, usurpation de nom affiché, lien masqué derrière une IP — sortent tous en dangereux. Un document à macros envoyé par un collègue légitime sort en suspect : un avertissement, pas un blocage.

**Quarantaine** — le bouton **Isoler** déplace le message vers le dossier des indésirables du compte, par `UID MOVE` ou, si le serveur ne le gère pas, par copie puis purge. Le nom du dossier est demandé au serveur par son rôle `\Junk`, car il est traduit. Rien n'est supprimé.

**Analyse complète** — le bouton **Analyser** parcourt la boîte puis les téléchargements. Pour les fichiers, BUD repère les formes dangereuses (exécutable venu du web, double extension, nom truqué, document à macros) et, pour les applications et paquets, interroge **Gatekeeper**, qui connaît les signatures qu'une heuristique ignore. Les fichiers retenus partent à la corbeille, jamais à la destruction : une fausse alerte doit rester réparable.

La veille tourne chaque minute. À l'arrivée d'un message, le notch se déplie avec l'expéditeur et l'objet — et annonce « Message dangereux » avant que vous ne l'ouvriez si l'analyse l'a classé ainsi.

**Téléphone** — relier Gmail sans rien taper au clavier du Mac. BUD affiche un QR code, vous le scannez, l'application Google du téléphone fait le reste. Deux voies :

1. **Mot de passe d'application** — le QR ouvre `myaccount.google.com/apppasswords` sur le téléphone, déjà authentifié. Vous créez un mot de passe nommé « BUD » et recopiez ses seize lettres. Demande la validation en deux étapes ; aucun identifiant client n'est nécessaire.
2. **OAuth Google** — le QR ouvre la page de consentement sur le téléphone. Après l'autorisation, la redirection pointe vers votre Mac et n'aboutit donc pas sur le téléphone : son adresse contient le code, qu'il suffit de coller dans BUD. Le vérificateur PKCE n'a jamais quitté le Mac, le code seul ne vaut rien pour un tiers.

Le guetteur local reste armé pendant l'opération : si vous préférez cliquer « Ouvrir ici », le consentement se fait sur le Mac et BUD termine seul. « Agrandir » affiche le code en 420 pt pour viser de loin.

À savoir : le *device flow* de Google — le code à six lettres sur `google.com/device` — **n'accepte pas** les scopes Gmail. Google le réserve à `email`, `openid`, `profile`, deux scopes Drive et deux YouTube. C'est la raison de ces deux voies plutôt que d'un simple code à saisir.

**Rappels** — écrivez la phrase entière, BUD en extrait l'heure : *« Sortir les poubelles à 19h30 »*, *« Appeler le garage dans 20 minutes »*, *« Facture demain »*. À l'échéance, le notch s'ouvre en alarme avec **Terminé** et **+10 min**, le son se répète toutes les cinq secondes pendant une minute. Répétition quotidienne ou hebdomadaire.

**Musique** — Apple Music et Spotify pilotés en AppleScript, avec titre en cours affiché. Pour **Alexa**, Amazon n'expose aucune interface locale sur macOS : BUD ouvre le lecteur web Amazon Music et le commande par les **touches média du système**, émises en `CGEvent`. Cela réclame l'autorisation Accessibilité.

### Travail

**Stockage** — anneau d'occupation du disque de démarrage, quatre tuiles (libre, occupé, capacité, volumes), liste de tous les volumes avec barre colorée, type et bouton d'éjection. Bouton **Tout éjecter**. Constantes du Mac : CPU, mémoire, uptime. Alerte quand le disque passe sous le seuil configuré.

**Nettoyage** — sept cibles analysées à l'octet : corbeille personnelle, corbeilles des volumes externes, caches, journaux, données Xcode, fichiers `.DS_Store`, téléchargements de plus de 60 jours. Analyse d'abord, confirmation détaillée ensuite. Animation pendant le travail : des poussières sont aspirées vers la corbeille, le compteur d'octets grimpe en direct, et la fin déclenche une gerbe d'accent.

**Focus** — minuteur Pomodoro réglable de 5 à 120 minutes, compte à rebours visible dans le notch replié, cumul des sessions du jour.

**Notes** — bloc sauvegardé à chaque frappe, export Markdown daté sur le Bureau.

**Snippets** — extraits réutilisables dans `snippets.json`, copiés en un clic. La **capture rapide** (⌘⌥D) ouvre un champ flottant en verre dépoli, compatible avec la dictée système, qui route vers le presse-papiers, les notes ou un nouveau snippet. Option de collage automatique dans l'application active.

**Presse-papiers** — les vingt derniers textes copiés, les six derniers affichés, un clic pour les replacer.

**Rangement** — glissez n'importe quel fichier sur le notch : il se classe en onze catégories dans `~/Documents/BUD Rangement`. Les dossiers sont parcourus en profondeur, les doublons renommés, et un bouton annule le dernier rangement.

### Système

**Outils** — recherche web, veille écran, bascule clair/sombre du système, corbeille, IP locale et nom du Wi-Fi, lancement rapide de Finder, Safari, Mail et Terminal.

**Réglages** — apparence (auto, clair, sombre), matière du panneau (opaque, verre dépoli, cristal), six couleurs d'accent dont le blanc, et treize interrupteurs de comportement.

---

## Raccourcis

| Touches | Action |
|---|---|
| ⌘⌥B | Ouvrir ou replier le tableau de bord |
| ⌘⌥K | Chat |
| ⌘⌥M | Courrier |
| ⌘⌥P | Téléphone — appairage Gmail |
| ⌘⌥R | Rappels |
| ⌘⌥D | Capture rapide |
| ⌘⌥A | Demandes des agents |
| ⌘⌥F | Démarrer ou arrêter un focus |
| Échap | Replier |

---

## Fichiers

```
~/Library/Application Support/BUD-Assistant/
├── src/                    les sources Swift, recompilables
├── state.json              préférences et contenus
├── state.backup-*.json     sauvegardes horodatées
├── snippets.json           vos extraits
├── reminders.json          vos rappels
├── quicknotes.md           journal des captures
├── agents/                 demandes et réponses des agents
└── bud-ask                 passerelle en ligne de commande
```

Le trousseau macOS garde les jetons OAuth, l'identifiant client et les mots de passe d'application, sous le service `fr.lahbib.bud.gmail`. Rien de sensible n'est écrit sur disque.

Le schéma JSON est tolérant : chaque clé inconnue est ignorée, chaque clé absente prend sa valeur par défaut, et les clés devenues inutiles sont conservées. Une ancienne configuration survit à toutes les montées de version.

---

## Autorisations macOS

| Demandée pour | Où l'accorder |
|---|---|
| Piloter Mail, Musique, Spotify, apparence système | Confidentialité → Automatisation |
| Touches média (Alexa), collage automatique, dictée | Confidentialité → Accessibilité |
| Ranger et nettoyer des fichiers | Confidentialité → Fichiers et dossiers |

Aucune n'est demandée au lancement : chacune arrive à la première utilisation réelle de la fonction concernée.

---

## Mises à jour

BUD interroge un fichier JSON une fois par jour, et à la demande depuis la carte « À propos » :

```json
{
  "version": "22.1",
  "notes": "Correctifs d'affichage",
  "url": "https://exemple.com/Installer_BUD_Premium.command"
}
```

L'adresse du canal se change depuis le bouton **Canal**. Si aucun canal n'est joignable, BUD le dit sans insister.

---

## Ce que BUD ne fait pas

Par honnêteté, autant le dire clairement.

Le chat n'est pas un modèle de langage : c'est un moteur d'intentions à base de mots-clés. Il comprend bien ce qu'il connaît, et répond par une aide quand il ne saisit pas.

L'analyse de courrier n'est pas un antivirus. BUD ne télécharge pas les pièces jointes et n'inspecte pas leur contenu : il reconnaît les formes d'attaque, pas les signatures de logiciels malveillants. Pour les fichiers déjà téléchargés, c'est Gatekeeper — l'outil d'Apple — qui tranche, pas BUD. Un message classé sain peut être malveillant, et un message suspect peut être parfaitement légitime : le verdict vous informe, il ne décide pas à votre place.

Alexa n'est pas contrôlée nativement — Amazon ne le permet pas sur macOS. BUD pilote son lecteur web par les touches média.

L'appairage par téléphone ne peut pas se passer entièrement de copier-coller en mode OAuth : Google interdit son *device flow* pour le courrier. La voie « mot de passe d'application » est, elle, complète — seize lettres à recopier.

L'application n'est ni signée ni notarisée : elle est compilée sur votre machine, à partir de sources que vous pouvez lire intégralement.
