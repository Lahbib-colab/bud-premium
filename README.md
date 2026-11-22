# BUD Premium

Compagnon de bureau natif pour macOS, de Monterey à Sequoia et au-delà, sur Intel comme sur Apple Silicon. Un petit compagnon blanc vit dans le notch, suit votre souris du regard, et déplie à la demande un tableau de bord de seize panneaux.

Écrit en Swift et AppKit pur. Aucune dépendance externe, aucune télémétrie, aucune donnée qui quitte votre Mac sauf celles que vous adressez explicitement à Google.

**Version 23.3** · by Lahbib.AI

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

Dans la barre repliée, **l'heure se lit comme sur un iPhone** : en gras, collée à gauche, la date du jour à sa droite en plus discret. Les chiffres sont à largeur fixe, sinon l'heure tremblerait à chaque minute — un « 1 » est plus étroit qu'un « 8 ». Pendant la lecture d'un morceau, la pochette, l'égaliseur et le titre défilant prennent cette place.

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
« Musique »  ·  « Morceau suivant »  ·  « Monte le volume »
« Ouvre les téléchargements »  ·  « L'heure »  ·  « Une blague »
« Batterie »  ·  « Mon adresse IP »  ·  « Verrouille l'écran »
« Passe en mode sombre »  ·  « Capture la fenêtre »
« Préviens-moi dans 15 minutes »
« Cherche la recette du pain perdu »
« 23 × 7 »  ·  « (120 + 80) / 4 »  ·  « 20 % de 480 »
```

**BUD calcule**, et l'évaluateur est écrit à la main : descente récursive sur quatre niveaux de priorité, parenthèses, puissance associative à droite, modulo, virgule décimale. Il n'est **pas** confié à `NSExpression`, qui évalue bien plus qu'une opération — il sait instancier des classes et appeler des méthodes par leur nom. Lui passer une chaîne venue du champ de saisie serait lui donner les clés de l'application pour additionner deux nombres. Un chiffre **et** un opérateur sont exigés avant qu'une phrase soit traitée comme un calcul, sinon « mes 5 mails » reviendrait en résultat.

**Dictée** — le micro à côté du champ transcrit votre parole, et le texte s'écrit au fil des mots pour que vous puissiez corriger au clavier plutôt que tout redire. Deux secondes de silence et BUD envoie.

La reconnaissance se fait **sur votre Mac**. `requiresOnDeviceRecognition` est posé, mais la documentation d'Apple est explicite : le drapeau n'est honoré que si `supportsOnDeviceRecognition` est vrai. BUD le vérifie donc lui-même, et si ce Mac ne sait pas reconnaître le français hors ligne, **il refuse la dictée et dit pourquoi** au lieu d'envoyer votre voix aux serveurs d'Apple. Pour l'activer : Réglages Système → Clavier → Dictée, puis téléchargez le français.

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

Le panneau a **deux modes**, *Boîte* et *Rédiger* : ils se partageaient la même hauteur et s'y retrouvaient tous deux à l'étroit. Chacun occupe maintenant tout l'espace — la liste 290 pt, le corps du message 300 pt — et les deux partagent le même cadre, bord haut et bord bas, pour que la bascule ne décale rien à l'écran.

La boîte affiche les huit derniers messages, lus ou non, chacun sur une carte cliquable de **trois lignes** : l'expéditeur avec la date à droite, l'objet, puis un **aperçu du corps**. S'y ajoutent la pastille de non-lu, le trombone d'une pièce jointe, un liseré de couleur donnant le verdict de l'analyse et, pour un message signalé, une capsule rouge ou ambre. Trois compteurs en tête : non lus, suspects, voie utilisée.

Une **pastille d'initiales** porte la couleur de l'expéditeur, tirée de son adresse : le même correspondant garde sa teinte d'une session à l'autre, et on le reconnaît avant d'avoir lu son nom. Douze teintes, et non une roue continue, où deux adresses voisines donneraient deux couleurs qu'on ne distingue pas. La pastille de non-lu devient un écusson posé sur ce disque.

**Balayez une carte.** Vers la gauche pour supprimer, vers la droite pour répondre : le fond coloré apparaît sous la carte qui glisse, et la couleur s'affirme au passage du seuil. La suppression demande confirmation — un balayage est vite fait sans le vouloir — alors que « Répondre » part directement, puisque répondre ne détruit rien. Rien n'est effacé : le message va à la **corbeille du compte**, dont le nom est demandé au serveur par son rôle `\Trash`, car il est localisé.

Un trackpad n'envoie pas de « geste de balayage » mais des événements de défilement avec une phase. La direction est donc décidée **une fois**, au début du geste, et tenue jusqu'au relâchement : arbitrer à chaque événement ferait sauter la carte entre défilement et balayage au moindre tremblement. Le défilement vertical de la liste reste intact, et une molette de souris ne balaie pas. Le sens suit le **doigt** et non le réglage : AppKit applique déjà « défilement naturel » à `scrollingDeltaX`, et sans défaire cette inversion le geste aurait déclenché l'action contraire chez qui a désactivé ce réglage.

Le mode **Lecture** ouvre le message en entier — en-tête, date écrite au long, verdict, pièces jointes, puis le corps sélectionnable avec un interligne large. Un clic sur une ligne y mène : lire est ce qu'on veut faire d'un courriel. Aucun aller-retour réseau de plus, le corps étant déjà rapatrié et décodé au relevé de la boîte. Les courriels qui n'ont qu'une version HTML ne sont pas *rendus* : BUD en extrait le texte, en transformant d'abord les balises de bloc en sauts de ligne — sans quoi tout se recollerait en un seul paragraphe.

Trois détails de lisibilité qui n'en sont pas :

- **La pastille de non-lu garde sa place, occupée ou non.** Sans cette réserve, le texte d'un message lu commençait 12 pt à gauche de celui d'un non-lu, et la colonne ondulait d'une ligne à l'autre.
- **La date est analysée, pas tronquée.** Couper l'en-tête à 17 caractères donnait « Sun, 22 Nov 2026 », et n'importe quel autre format de fuseau la coupait au milieu d'un mot. Elle est lue en locale POSIX — un Mac en français ne reconnaît ni « Sun » ni « Nov » — puis réécrite dans la langue du système : l'heure aujourd'hui, « hier », le jour et le mois cette année.
- **L'objet occupe toute la largeur.** La place réservée à la date et au verdict ne vaut que pour la première ligne ; l'objet en héritait et se trouvait tronqué pour rien.

L'aperçu vient du corps déjà récupéré pour citer le message dans une réponse. Par la passerelle Mail.app, il est **coupé à 200 caractères du côté d'AppleScript** : un message de plusieurs mégaoctets n'a pas à traverser la sortie d'`osascript` pour qu'on n'en garde qu'une ligne.

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

**Musique** — Apple Music seule, pilotée en AppleScript. Titre, artiste, album, barre de progression avec position et durée, recul et avance de 15 s, curseur de volume, lecture aléatoire, répétition (aucune, tout, ce titre). Un seul aller-retour rapporte l'état complet, chaque propriété lue dans son propre `try` : si une version de Musique n'expose plus la répétition, on perd cette information, pas la totalité.

Pendant la lecture, le notch replié montre le **titre défilant** à la place de l'heure — 214 pt ne suffisent pas pour les deux, et savoir ce qui joue vaut mieux qu'une horloge présente partout ailleurs — accompagné de quatre barres d'égaliseur, et **BUD prend le rythme** par impulsions dans ses ressorts.

La **pochette** s'affiche en 68 pt dans le panneau et en vignette de 18 pt dans le notch, à gauche de l'égaliseur. En pause elle s'assombrit sans disparaître : l'album ne change pas parce que la lecture s'arrête. Sans pochette — une radio, un flux — une note de musique tient la place.

L'illustration est exportée par son `raw data`, écrit dans un fichier de `Application Support` puis relu : l'image ne traverse jamais la sortie standard d'`osascript`, et le dossier n'est pas protégé, donc aucune autorisation supplémentaire n'est demandée. L'écriture a lieu **hors** du bloc `tell application "Music"`, car `open for access` appartient aux Standard Additions tandis que Musique publie son propre verbe `open`. Un seul export par morceau, partagé par le notch et le panneau, et le script renvoie la piste qu'il a réellement lue : si le morceau change pendant l'export, la pochette est rangée sous la bonne clé au lieu de rester collée au suivant.

Le sondage ne coûte rien quand Musique est fermée : le test d'exécution passe par `NSWorkspace`, sans lancer de processus.

Spotify et Alexa ont été retirés en version 23. Alexa surtout : Amazon n'expose aucune interface locale sur macOS, et le piloter par les touches média d'un lecteur web était un bricolage qui réclamait l'autorisation Accessibilité pour un résultat imprévisible.

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

S'y ajoutent le **verrouillage de l'écran** et l'accès aux **raccourcis clavier**. Le verrouillage passe par `CGSession -suspend` quand le système l'offre ; sinon BUD met l'écran en veille et le dit, parce qu'une mise en veille n'est un verrouillage que si votre réglage de mot de passe le veut — annoncer « verrouillé » dans ce cas serait un mensonge utile à personne.

Les icônes sont **teintées par groupe** — indigo, ambre, orange, turquoise, bleu, violet — sans que les titres y perdent en lisibilité : colorer les deux rendrait le texte pâle.

L'onglet est rangé en **groupes titrés** — Système, Applications, Capture d'écran — là où un seul des quatre portait un intertitre. Les rangées mesuraient 42, 44 et 48 pt selon l'endroit, et chaque ordonnée était calculée à la main, donc elles finissaient par se contredire ; elles descendent maintenant d'un pas constant. Les comptes rendus — apparence basculée, adresse IP, application ouverte, capture enregistrée — arrivent tous dans **une seule carte** au bas du panneau, au lieu de deux étiquettes concurrentes placées à deux endroits.

**Capture d'écran** — tout l'écran, une fenêtre, ou une sélection au réticule, vers le **Bureau** ou le **presse-papiers**. BUD n'écrit pas son propre code de capture : il appelle `screencapture`, l'outil du système, qui sait déjà gérer les écrans multiples, les densités Retina et l'espace colorimétrique. Le notch se replie avant la prise, sinon il figurerait sur chaque capture plein écran. Un bouton **Révéler** ouvre la dernière image dans le Finder.

Si l'image fait moins de 4 Ko, c'est que l'autorisation manque : BUD vous renvoie vers Réglages Système → Confidentialité et sécurité → **Enregistrement de l'écran**, au lieu de laisser un cadre noir sur votre Bureau.

**Réglages** — apparence (auto, clair, sombre), matière du panneau (opaque, verre dépoli, cristal), six couleurs d'accent dont le blanc, et treize interrupteurs de comportement.

---

## Raccourcis

Ce sont les raccourcis d'usine. **Tous se changent** : onglet Outils → *Raccourcis clavier…*, puis cliquez celui à remplacer et tapez la combinaison. Échap annule.

| Touches | Action |
|---|---|
| ⌘⌥B | Ouvrir ou replier le tableau de bord |
| ⌘⌥C | Dire coucou |
| ⌘⌥K | Chat |
| ⌘⌥V | Parler à BUD — ouvre le chat et la dictée |
| ⌘⌥M | Courrier |
| ⌘⌥P | Téléphone — appairage Gmail |
| ⌘⌥R | Rappels |
| ⌘⌥D | Capture rapide |
| ⌘⌥A | Demandes des agents |
| ⌘⌥F | Démarrer ou arrêter un focus |
| Échap | Replier |

Une combinaison sans ⌘, ⌃ ni ⌥ est **refusée** : elle intercepterait votre frappe ordinaire dans toutes les applications. Le capteur de touche installe un moniteur **local**, retiré dès la capture terminée — un moniteur global avalerait les touches de tout le système pendant l'enregistrement.

Les choix vivent dans un dictionnaire indexé par action, et non dans un champ par raccourci : ajouter une action ne demande donc aucune migration de vos réglages, et ce qui manque retombe sur l'usine.

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
| Piloter Mail, Musique, apparence système | Confidentialité → Automatisation |
| Collage automatique, dictée | Confidentialité → Accessibilité |
| Capture d'écran | Confidentialité → Enregistrement de l'écran |
| Ranger et nettoyer des fichiers | Confidentialité → Fichiers et dossiers |

Aucune n'est demandée au lancement : chacune arrive à la première utilisation réelle de la fonction concernée.

---


---

## Mises à jour

BUD interroge l'API des releases de ce dépôt, une fois par jour et à la demande depuis la carte « À propos ». La release est la source de vérité : elle porte à la fois le numéro de version et les installeurs, donc rien à tenir en parallèle.

Le bouton **télécharge et installe**, sans passer par le Finder ni le Terminal. Une confirmation précède toujours le remplacement, et un bouton « Voir les notes » permet de lire d'abord. Ensuite BUD enchaîne quatre contrôles, avec une barre de progression dans la carte :

| Étape | Contrôle |
|---|---|
| Téléchargement | barre qui se remplit, pourcentage réel |
| Empreinte | SHA-256 recalculé et comparé au `SHA256.txt` publié |
| Architecture | `lipo -archs` doit contenir celle de cette machine |
| Version | l'`Info.plist` de l'archive doit annoncer la version attendue |

Une empreinte qui diffère interrompt tout : un téléchargement abîmé ne s'installe pas. Si la release ne publie aucune empreinte, l'installation continue mais l'annonce. Pour les étapes dont la durée est inconnue — empreinte, décompression — la barre passe en navette va-et-vient plutôt que d'inventer un pourcentage.

Rien ne bloque l'interface : tout se déroule en arrière-plan et BUD reste utilisable.

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
