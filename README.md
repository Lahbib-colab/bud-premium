# BUD Premium

Compagnon de bureau natif pour macOS, de Monterey à Sequoia et au-delà, sur Intel comme sur Apple Silicon. **BUDs**, un petit compagnon blanc aux sept visages, vit dans le notch et déplie à la demande un tableau de bord de dix-huit panneaux : chat avec outils intégrés, agents en nœuds, courrier, musique, météo, maison connectée, stockage, nettoyage…

Écrit en Swift et AppKit pur. Aucune dépendance externe, aucune télémétrie. Ne quittent votre Mac que ce que vous adressez à Google (votre courrier Gmail), les coordonnées de la ville choisie pour la météo, et — seulement si vous y mettez une clé — les adresses des liens à vérifier.

**Version 25.8** · by Lahbib.AI

[![build](https://github.com/Lahbib-colab/bud-premium/actions/workflows/build.yml/badge.svg)](https://github.com/Lahbib-colab/bud-premium/actions/workflows/build.yml)

---

## Nouveautés

| Version | Ce qui change |
|---|---|
| **25.6 – 25.8** | **Mise à jour intégrée** de bout en bout : bannière de verre dans la barre latérale, progression détaillée, paquet vérifié avant tout remplacement, mot de passe demandé si le dossier est protégé, retour automatique à l'ancienne version si la nouvelle ne démarre pas. |
| **25.5** | L'onglet Outils disparaît : capture, veille, verrouillage et agents passent dans le **chat**, derrière une pilule *Outils*. Compte à rebours avant la mise en veille, confirmation avant de vider la corbeille, miniature de la capture dans le fil. |
| **25.4** | Le **Flux** : les agents en nœuds à la manière de n8n — sources, agents, BUDs — avec liens animés, badges d'état, cartes façon widgets iOS et fiche d'approbation obligatoire. Trois agents : *Nettoyage & Rangement*, *Cybersécurité*, *Météo & Maison*. |
| **25.3** | **Météo** animée façon Apple (Open-Meteo, sans clé) et **Maison** : vos commandes HomeKit lancées par Raccourcis. |
| **25.2** | La pastille Musique de l'aperçu se déplie en **lecteur réduit**, sur place. |
| **25.1** | Le compagnon devient **BUDs** : sept visages rendus, des postures par humeur, et les deux billes du tréma qui vivent chacune leur vie. |
| **24.8 – 25.0** | Écran de démarrage animé avec carillon, logo en deux encres, BUD harmonisé entre panneau et notch. |
| **24.5** | **« Hey Bud, réponds au mail de Free »** : réponse au courrier à la voix, dans votre style, validée avant tout envoi. |
| **24.4** | Musique réparée : titre, artiste et pochette fiables, commandes instantanées. |
| **24.2** | **Sous-agents** : vos scripts locaux, branchés sur BUD par un contrat JSON — voir [AGENTS.md](AGENTS.md). |

Le détail de chaque version, avec le pourquoi des choix, est dans **[CHANGELOG.md](CHANGELOG.md)**.

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

## Charte graphique

L'interface entière suit un système de jetons unique, décrit dans
**[DESIGN.md](DESIGN.md)** et implémenté dans `Sources/BudDesign.swift` :
espacement de base 4, six rôles typographiques à graisses contrastées,
quatre niveaux d'élévation, trois durées de mouvement, et une seule
fonction qui dessine toute surface de verre.

BUD est une application AppKit : il n'y a pas de CSS, et les jetons en
tiennent le rôle. Les dix-huit panneaux partagent six primitives — bouton,
carte, barre segmentée, entête, tuile, interrupteur — et c'est par elles
que la charte se propage à Compagnon, Chat, Agents et Courrier sans
avoir à les reprendre un par un.

---

## Organisation du dépôt

```
bud-premium/
├── Sources/                 les 37 fichiers Swift de l'application
├── Art/                     les rendus de BUDs, le mot du démarrage, le carillon
├── Tools/
│   ├── MakeIcon.swift       générateur d'icône, compilé seul
│   ├── bud-ask              passerelle agents en ligne de commande
│   ├── braces.py            contrôle d'équilibre des accolades
│   └── make-installer.sh    fabrique dist/ depuis Sources/ + Art/ + build.sh
├── build.sh                 compilation et installation — source unique
├── Makefile                 raccourcis
├── version.json             canal de mise à jour interrogé par BUD
├── dist/                    installeur en un fichier, versionné
├── CHANGELOG.md · AGENTS.md · DESIGN.md
└── .github/workflows/       compilation vérifiée, publication des releases
```

`MakeIcon.swift` vit dans `Tools/` et non dans `Sources/` pour une raison précise : il contient du code au niveau racine, ce que Swift n'autorise que dans `main.swift` ou dans un fichier compilé seul. Le laisser dans `Sources/` casserait la compilation de l'application.

---

## Compatibilité

| | |
|---|---|
| Systèmes | macOS 12 Monterey → 15 Sequoia et au-delà |
| Processeurs | Intel (x86_64) et Apple Silicon (arm64) |
| Cible de déploiement | 12.0 — compatible vers l'avant |

L'installeur `.command` compile sur votre machine, pour son architecture (`uname -m`), et appose une signature ad hoc : le binaire produit est natif, jamais émulé. Les `.dmg` et `.zip` des releases portent, eux, un binaire universel (Intel + Apple Silicon).

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
| **Replié** | 214 × 36 | BUDs, l'heure, une pastille d'alerte |
| **Aperçu** | 470 × 160 | Salutation, date, disque libre, agents, focus, horloge |
| **Approbation** | 600 × 210 | Carte de validation avec boutons cliquables |
| **Ouvert** | 880 × 610 | Le tableau de bord complet |

Survolez le haut de l'écran pour l'aperçu, cliquez pour ouvrir. Il se replie à la sortie du curseur, sur Échap, ou au clic ailleurs. Trois filets de sécurité garantissent le repli, dont une vérification de la position réelle du curseur chaque seconde.

Devant une application en plein écran, BUD s'efface complètement — réglage désactivable.

Les **quatre pastilles de l'aperçu** se choisissent parmi onze — espace libre, disques externes, agents, focus, heure, batterie, courrier non lu, prochain rappel, lecture en cours, mémoire libre, météo. Chacune porte sa teinte et **se clique** pour ouvrir le panneau qui la concerne ; celle qu'on survole s'éclaire. La pastille Météo prend l'icône du ciel du moment. Le réglage est dans la fenêtre *Raccourcis et aperçu*.

La pastille **Musique** ne quitte pas l'aperçu : elle se déplie sur place en **lecteur réduit** — pochette, titre, artiste, avancement, précédent, lecture, suivant. Le lecteur naît du rectangle de la pastille et s'y replie ; la pochette et le titre mènent au grand panneau.

Dans la barre repliée, **l'heure se lit comme sur un iPhone** : en gras, collée à gauche, la date du jour à sa droite en plus discret. Les chiffres sont à largeur fixe, sinon l'heure tremblerait à chaque minute — un « 1 » est plus étroit qu'un « 8 ». Pendant la lecture d'un morceau, la pochette, l'égaliseur et le titre défilant prennent cette place.

---

## Le personnage

**BUDs** est un Ü blanc dont les deux points du tréma sont deux billes. Il a **sept visages rendus** — neutre, content, réfléchi, déçu, en colère, étourdi, cool — qui partagent exactement le même cadrage : le nouveau visage se pose sur l'ancien en un fondu de seize centièmes, la silhouette ne bouge pas, et un petit bond du corps fait passer le changement pour un geste.

**Le visage dit l'émotion, la posture dit le reste.** Quatorze humeurs se partagent les sept visages, chacune avec son corps : la colère se tasse et tremble, l'étourdi tangue sur deux sinus qui ne se recoupent jamais, le réfléchi penche d'un seul côté, la fierté se redresse, la tristesse s'affaisse. Chaque humeur est attachée à un fait — un message dangereux qui arrive, une commande comprise de travers, une tâche réussie — et s'éteint d'elle-même.

**Au travail**, quand un outil ou un agent s'exécute, le visage se concentre et **les deux billes jonglent** : quand l'une est en haut, l'autre touche le corps. Puis vient l'expression du résultat.

| Expression des agents | Ce que montre BUDs |
|---|---|
| `neutral` | attentif, dressé |
| `happy` | content |
| `reflection` | réfléchi, tête penchée |
| `annoyed` | en colère, tassé |
| `dizzy` | étourdi, qui tangue |
| `cool` | lunettes, fier |
| `sad` | déçu, affaissé |
| `working` | concentré, billes qui jonglent |

Pendant la lecture de musique, BUDs met ses lunettes et danse en mesure. En thème clair, une ombre douce le détache du panneau. Le même dessin vit dans le panneau, dans le notch replié et dans le nœud de sortie du Flux — un seul point d'entrée les dessine tous, pour qu'ils ne divergent jamais.

**Le démarrage** : le mot BUD arrive lettre par lettre, avec un léger dépassement élastique, les billes tombent, un reflet traverse le mot, et un carillon de quatre notes — calculé, pas téléchargé — sonne s'il n'est pas coupé. Une seconde et demie, sans rien retenir : BUD finit de se construire derrière.

Les habillages vectoriels d'origine — *À plat*, *Nacré*, *Métal* — restent disponibles dans Réglages → Habillage, et servent de secours si le paquet ne porte pas les rendus.

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
« Mets le Mac en veille »  ·  « Analyse ce lien »
« Quel temps fait-il ? »  ·  « Lumière salon »
« Préviens-moi dans 15 minutes »
« Cherche la recette du pain perdu »
« 23 × 7 »  ·  « (120 + 80) / 4 »  ·  « 20 % de 480 »
```

**BUD calcule**, et l'évaluateur est écrit à la main : descente récursive sur quatre niveaux de priorité, parenthèses, puissance associative à droite, modulo, virgule décimale. Il n'est **pas** confié à `NSExpression`, qui évalue bien plus qu'une opération — il sait instancier des classes et appeler des méthodes par leur nom. Lui passer une chaîne venue du champ de saisie serait lui donner les clés de l'application pour additionner deux nombres. Un chiffre **et** un opérateur sont exigés avant qu'une phrase soit traitée comme un calcul, sinon « mes 5 mails » reviendrait en résultat.

**La pilule Outils** — au début de la rangée de suggestions, juste au-dessus du champ, une pilule en verre sombre ouvre le menu des outils vers le haut, par-dessus la conversation. Il remplace l'ancien onglet Outils :

| Groupe | Outils |
|---|---|
| Capture | tout l'écran, une fenêtre, une zone, une zone vers le presse-papiers |
| Système | veille du Mac, veille de l'écran, verrouillage, clair/sombre, vider la corbeille, réseau, batterie |
| Agents | rangement & nettoyage, cybersécurité, météo & maison — ceux du Flux |
| Plus | raccourcis clavier, Finder, Terminal |

Un outil ne laisse **qu'une bulle** dans le fil : elle tourne pendant le travail, puis devient le résultat — coche ou point d'exclamation, texte, et selon l'outil une **miniature** (la capture) et un geste au clic (« Afficher dans le Finder », « Ouvrir les réglages », « Examiner dans le Flux »). BUDs passe au travail pendant l'exécution, puis content, attentif ou déçu.

**Ce qui interrompt attend.** La mise en veille du Mac part après un compte à rebours de 5 s, le verrouillage après 3 s : une barre remplace les suggestions, avec un anneau qui se vide, *Annuler* et *Maintenant*. Vider la corbeille, irréversible, attend un clic. Demandés par écrit ou à la voix, ces outils passent par le même chemin que la pilule — même confirmation, même bulle.

**La capture vérifie l'autorisation avant de capturer.** Sans « Enregistrement de l'écran », macOS rend une image vide au lieu de refuser : BUD vérifie, déclenche la demande du système la première fois, et sinon propose d'ouvrir le bon réglage. Le panneau se replie pendant la prise — sinon il figurerait sur la capture — puis revient sur le chat avec la miniature. La capture passe par `screencapture`, l'outil du système, qui gère déjà les écrans multiples et le Retina ; la miniature est réduite par ImageIO plutôt que chargée en entier.

Pour ajouter un outil : un `BudTool` inscrit dans `BudToolCatalog.registerDefaults` (`Sources/BudTools.swift`). Le menu, la reconnaissance de la phrase, la bulle et les expressions suivent.

**Dictée** — le micro à côté du champ transcrit votre parole, et le texte s'écrit au fil des mots pour que vous puissiez corriger au clavier plutôt que tout redire. Deux secondes de silence et BUD envoie.

La reconnaissance se fait **sur votre Mac**. `requiresOnDeviceRecognition` est posé, mais la documentation d'Apple est explicite : le drapeau n'est honoré que si `supportsOnDeviceRecognition` est vrai. BUD le vérifie donc lui-même, et si ce Mac ne sait pas reconnaître le français hors ligne, **il refuse la dictée et dit pourquoi** au lieu d'envoyer votre voix aux serveurs d'Apple. Pour l'activer : Réglages Système → Clavier → Dictée, puis téléchargez le français.

**« Hey Bud »** — une écoute permanente, à armer dans Réglages, reconnaît le mot d'activation puis la commande qui suit, avec le même moteur local que la dictée. L'interface le montre tant qu'elle est armée : le micro reste ouvert, et sur batterie cela se sent.

**Agents** — vos agents IA demandent une validation et BUD la présente dans le notch. Protocole fichier, sans dépendance :

```bash
"$HOME/Library/Application Support/BUD-Assistant/bud-ask" \
  "Déployer ?" "3 fichiers vers main" "$PWD"
# bloque jusqu'à réponse · 0 = validé, 1 = refusé, 2 = délai dépassé
```

L'agent dépose `agents/<id>.json`, BUD écrit `<id>.reply`. Surveillance par `DispatchSource` sur le dossier, doublée d'un sondage de sécurité. À l'arrivée d'une demande, BUDs passe en alerte, le notch s'ouvre en carte **Autoriser / Refuser / Détails**.

**Flux** — les agents de BUD en **nœuds connectés**, à la manière de n8n, sans serveur n8n. Trois colonnes sur une trame de points :

```
Sources  ──▶  Agents  ──▶  BUDs
```

Les liens sont des courbes qui s'animent dans la couleur de l'agent quand il travaille — des tirets qui avancent, une perle qui circule. Chaque nœud porte un badge : *Prêt*, *En cours*, *OK*, *Alerte*, *Échec*, *À valider*. Un clic sélectionne, un double clic exécute. Le nœud de sortie est un BUDs miniature, avec un halo de la couleur de son expression. Sous le graphe, l'inspecteur montre le nœud choisi et les **cartes** de son dernier résultat, compactes à la manière des widgets iOS — la carte météo y a son vrai ciel animé.

| Agent | Ce qu'il fait |
|---|---|
| **Nettoyage & Rangement** | installeurs déjà utilisés, gros fichiers oubliés et fichiers suspects des téléchargements ; applications non ouvertes depuis 120 jours, avec leurs restes dans la bibliothèque. Jamais proposées : les apps d'Apple, les apps ouvertes, BUD lui-même. |
| **Cybersécurité** | liens du presse-papiers, d'un champ de saisie et des derniers messages : IP nues, punycode, alphabets mêlés, raccourcisseurs, extensions à risque, « @ » trompeurs, sosies de marques (`paypa1`, `micros0ft`). Analyse locale ; en option, Google Safe Browsing avec votre propre clé, rangée dans le trousseau — seules les adresses des liens partent. |
| **Météo & Maison** | le ciel du moment, et les commandes de chauffage, de lumières et de caméra trouvées dans votre dossier de raccourcis Maison. |

**Rien ne se supprime sans fiche.** Ce qui toucherait au disque revient en fiche d'approbation : une case par élément, sa raison, sa taille, le total qui suit les coches. Seuls les installeurs anciens arrivent cochés ; tout part à la **corbeille**, jamais à la destruction.

**Démo** lance les trois agents sur des données d'exemple (`Sources/BudFlowSamples.swift`) — la fiche se coche, la corbeille n'est pas touchée. **Visages** passe les huit expressions en revue. Un nouvel agent est une classe conforme à `BudAgent`, inscrite d'une ligne dans `BudAgentCatalog` : le graphe, les liens, les états et la fiche suivent seuls.

### Communication

**Courrier** — trois voies de connexion, par ordre de priorité :

1. **Google OAuth 2.0 avec PKCE** — flux complet, écoute locale sur 127.0.0.1, authentification IMAP et SMTP en XOAUTH2. Jetons dans le trousseau macOS. Nécessite un identifiant client de type *application de bureau* et l'étendue `https://mail.google.com/`.
2. **Mot de passe d'application** — IMAP sur 993 et SMTP sur 465, clients écrits à la main sur Network.framework.
3. **Mail.app** — par AppleScript, si aucun compte n'est relié.

Le panneau a **deux modes**, *Boîte* et *Rédiger* : ils se partageaient la même hauteur et s'y retrouvaient tous deux à l'étroit. Chacun occupe maintenant tout l'espace — la liste 290 pt, le corps du message 300 pt — et les deux partagent le même cadre, bord haut et bord bas, pour que la bascule ne décale rien à l'écran.

La boîte affiche les huit derniers messages, lus ou non, chacun sur une carte cliquable de **trois lignes** : l'expéditeur avec la date à droite, l'objet, puis un **aperçu du corps**. S'y ajoutent la pastille de non-lu, le trombone d'une pièce jointe, un liseré de couleur donnant le verdict de l'analyse et, pour un message signalé, une capsule rouge ou ambre. Trois compteurs en tête : non lus, suspects, voie utilisée.

La boîte montre **soixante messages**, rangés en quatre types comme dans Mail — Principal, Transactions, Mises à jour, Promotions — avec « Tous » en premier et sélectionné par défaut : un classement qui cache du courrier dès l'ouverture serait un piège.

Le signal décisif n'est pas dans l'objet mais dans les en-têtes `List-Unsubscribe`, `List-Id` et `Precedence`. Un message qui porte un lien de désabonnement est un envoi en masse : l'expéditeur le déclare lui-même et n'a aucun intérêt à mentir, contrairement à un objet, qu'on écrit pour attirer l'œil. Les mots-clés ne servent qu'à départager les envois en masse entre eux. Une transaction prime sur tout le reste, car une confirmation de commande part souvent d'une plateforme qui ajoute un lien de désabonnement, et la ranger en promotions ferait perdre la seule trace d'un achat.

Le bouton **Sélection** remplace chaque pastille d'initiales par une case, à l'emplacement exact de la pastille pour que la colonne de texte ne bouge pas. *Supprimer* agit alors sur tout ce qui est coché, en une seule commande IMAP.

Le corps n'est rapatrié que pour les douze premiers messages ; au-delà il se charge à l'ouverture, en `EXAMINE` et non `SELECT` — **en lecture seule**, pour qu'ouvrir un message ne le marque pas comme lu à votre insu. Soixante allers-retours de 8 Ko auraient fait attendre une minute avant le premier affichage.

Une **pastille d'initiales** porte la couleur de l'expéditeur, tirée de son adresse : le même correspondant garde sa teinte d'une session à l'autre, et on le reconnaît avant d'avoir lu son nom. Douze teintes, et non une roue continue, où deux adresses voisines donneraient deux couleurs qu'on ne distingue pas. La pastille de non-lu devient un écusson posé sur ce disque.

**Balayez une carte.** Vers la gauche pour supprimer, vers la droite pour répondre : le fond coloré apparaît sous la carte qui glisse, et la couleur s'affirme au passage du seuil. La suppression demande confirmation — un balayage est vite fait sans le vouloir — alors que « Répondre » part directement, puisque répondre ne détruit rien. Rien n'est effacé : le message va à la **corbeille du compte**, dont le nom est demandé au serveur par son rôle `\Trash`, car il est localisé.

Un trackpad n'envoie pas de « geste de balayage » mais des événements de défilement avec une phase. La direction est donc décidée **une fois**, au début du geste, et tenue jusqu'au relâchement : arbitrer à chaque événement ferait sauter la carte entre défilement et balayage au moindre tremblement. Le défilement vertical de la liste reste intact, et une molette de souris ne balaie pas. Le sens suit le **doigt** et non le réglage : AppKit applique déjà « défilement naturel » à `scrollingDeltaX`, et sans défaire cette inversion le geste aurait déclenché l'action contraire chez qui a désactivé ce réglage.

Le mode **Lecture** ouvre le message en entier — en-tête, date écrite au long, verdict, pièces jointes, puis le corps sélectionnable avec un interligne large. Un clic sur une ligne y mène : lire est ce qu'on veut faire d'un courriel. Aucun aller-retour réseau de plus, le corps étant déjà rapatrié et décodé au relevé de la boîte. Les courriels qui n'ont qu'une version HTML ne sont pas *rendus* : BUD en extrait le texte, en transformant d'abord les balises de bloc en sauts de ligne — sans quoi tout se recollerait en un seul paragraphe.

Trois détails de lisibilité qui n'en sont pas :

- **La pastille de non-lu garde sa place, occupée ou non.** Sans cette réserve, le texte d'un message lu commençait 12 pt à gauche de celui d'un non-lu, et la colonne ondulait d'une ligne à l'autre.
- **La date est analysée, pas tronquée.** Couper l'en-tête à 17 caractères donnait « Sun, 22 Nov 2026 », et n'importe quel autre format de fuseau la coupait au milieu d'un mot. Elle est lue en locale POSIX — un Mac en français ne reconnaît ni « Sun » ni « Nov » — puis réécrite dans la langue du système : l'heure aujourd'hui, « hier », le jour et le mois cette année.
- **L'objet occupe toute la largeur.** La place réservée à la date et au verdict ne vaut que pour la première ligne ; l'objet en héritait et se trouvait tronqué pour rien.

L'aperçu vient du corps déjà récupéré pour citer le message dans une réponse. Par la passerelle Mail.app, il est **coupé à 200 caractères du côté d'AppleScript** : un message de plusieurs mégaoctets n'a pas à traverser la sortie d'`osascript` pour qu'on n'en garde qu'une ligne.

**Répondre à la voix** — « Hey Bud, réponds au mail de Free ». BUD retrouve le message par le nom de l'expéditeur, puis son domaine, puis l'objet, et propose trois réponses : accusé de réception, réponse sur le fond, demande de délai. Le corps est assemblé à partir de **vos propres phrases**, relevées dans vos messages envoyés et classées par fonction ; l'ouverture « Bonjour, Monsieur ou Madame, » et la clôture « Cordialement, merci. » sont imposées. Rien ne part seul : il faut **Valider** avant que **Envoyer** s'active, et les mêmes garde-fous qu'au clic s'appliquent.

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

Le lecteur règle **deux volumes, nommés** : celui du Mac — `output volume`, celui des touches du clavier, avec sa coupure du son — et celui de Musique, qui n'est que le niveau de l'application dans le mélangeur. Les confondre, c'est monter l'un pendant que l'autre est à zéro. Monter le son d'un Mac coupé le rallume, sinon le curseur bouge et rien ne sort, et le volume du Mac reste réglable même Musique fermée.

Le transport offre **Arrêt** en plus de Pause : Musique revient au début du morceau, ce que la pause ne fait pas. Le bouton central montre l'action à venir plutôt que l'état présent.

La **pochette** s'affiche en 68 pt dans le panneau et en vignette de 18 pt dans le notch, à gauche de l'égaliseur. En pause elle s'assombrit sans disparaître : l'album ne change pas parce que la lecture s'arrête. Sans pochette — une radio, un flux — une note de musique tient la place.

L'illustration est exportée par son `raw data`, écrit dans un fichier de `Application Support` puis relu : l'image ne traverse jamais la sortie standard d'`osascript`, et le dossier n'est pas protégé, donc aucune autorisation supplémentaire n'est demandée. L'écriture a lieu **hors** du bloc `tell application "Music"`, car `open for access` appartient aux Standard Additions tandis que Musique publie son propre verbe `open`. Un seul export par morceau, partagé par le notch et le panneau, et le script renvoie la piste qu'il a réellement lue : si le morceau change pendant l'export, la pochette est rangée sous la bonne clé au lieu de rester collée au suivant.

Le sondage ne coûte rien quand Musique est fermée : le test d'exécution passe par `NSWorkspace`, sans lancer de processus.

Depuis 24.4, BUD écoute aussi la notification que Musique publie à chaque changement de morceau : le titre arrive au moment même, sans autorisation ni processus. AppleScript reste comme second témoin, toutes ses variables préfixées `bud` pour ne jamais buter sur un mot réservé. Ce que BUD ne sait pas — un volume illisible, une position inconnue — n'est plus affiché comme valant zéro : le contrôle se désactive.

Spotify et Alexa ont été retirés en version 23. Alexa surtout : Amazon n'expose aucune interface locale sur macOS, et le piloter par les touches média d'un lecteur web était un bricolage qui réclamait l'autorisation Accessibilité pour un résultat imprévisible.

### Travail

La section **Stockage** colore l'alerte au lieu de l'écrire en gris : l'anneau, la capsule de l'entête et le pourcentage de chaque volume passent à l'ambre puis au rouge, selon le seuil que vous avez réglé. Les largeurs de ligne ont des planchers, car « 100 % » est plus large que « 7 % » : sur un disque presque plein, la colonne de droite s'élargissait et la barre de progression recevait une largeur négative.

**Stockage** — anneau d'occupation du disque de démarrage, quatre tuiles (libre, occupé, capacité, volumes), liste de tous les volumes avec barre colorée, type et bouton d'éjection. Bouton **Tout éjecter**. Constantes du Mac : CPU, mémoire, uptime. Alerte quand le disque passe sous le seuil configuré.

**Nettoyage** — sept cibles analysées à l'octet : corbeille personnelle, corbeilles des volumes externes, caches, journaux, données Xcode, fichiers `.DS_Store`, téléchargements de plus de 60 jours. Analyse d'abord, confirmation détaillée ensuite. Animation pendant le travail : des poussières sont aspirées vers la corbeille, le compteur d'octets grimpe en direct, et la fin déclenche une gerbe d'accent.

**Focus** — minuteur Pomodoro réglable de 5 à 120 minutes, compte à rebours visible dans le notch replié, cumul des sessions du jour.

**Notes** — bloc sauvegardé à chaque frappe, export Markdown daté sur le Bureau.

**Snippets** — extraits réutilisables dans `snippets.json`, copiés en un clic. La **capture rapide** (⌘⌥D) ouvre un champ flottant en verre dépoli, compatible avec la dictée système, qui route vers le presse-papiers, les notes ou un nouveau snippet. Option de collage automatique dans l'application active.

**Presse-papiers** — les vingt derniers textes copiés, les six derniers affichés, un clic pour les replacer.

**Rangement** — glissez n'importe quel fichier sur le notch : il se classe en onze catégories dans `~/Documents/BUD Rangement`. Les dossiers sont parcourus en profondeur, les doublons renommés, et un bouton annule le dernier rangement.

### Maison

**Météo** — la disposition de l'application Météo d'Apple : la ville, la température en grand, le ciel en mots, maximum et minimum ; douze heures en bande avec ressenti, vent et humidité ; sept jours avec une barre qui situe chaque journée dans les températures de toute la semaine, du bleu froid à l'orange chaud. La probabilité de pluie s'affiche dès 20 %.

Le fond est **un ciel qui bouge** : soleil qui respire, nuages sur trois plans à trois vitesses, pluie oblique plus ou moins dense, neige qui se balance, brouillard, orage qui illumine tout le ciel, lune et étoiles la nuit. La scène ne s'anime que si on la regarde.

Les données viennent d'**Open-Meteo**, gratuit et sans clé pour un usage personnel, sous licence CC BY 4.0 — d'où la mention de la source en bas du panneau. WeatherKit, la météo d'Apple, exige un compte développeur payant. Seules partent les coordonnées de la ville choisie, arrondies au centième ; BUD ne demande pas la position du Mac. Relevé toutes les trente minutes au plus, le dernier gardé sur disque pour un affichage immédiat.

**Maison** — vos objets HomeKit, en tuiles comme dans l'application Maison. HomeKit n'est pas ouvert aux applications AppKit : Apple le réserve sur Mac aux applications Catalyst munies d'un droit délivré à un compte payant. BUD passe donc par **Raccourcis**, qui sait « Contrôler la maison » :

1. Dans Raccourcis, créez un dossier **BUD Maison**.
2. Créez-y un raccourci par commande — « Lumière salon », « Bonne nuit », « Chauffage 20° »…
3. Ajoutez-y l'action *Contrôler la maison* et choisissez la scène ou l'accessoire.
4. Revenez dans BUD et cliquez sur **Recharger**.

Chaque tuile prend une icône et une couleur d'après son nom — ampoule, lune, prise, thermomètre, serrure, volets… —, tourne pendant l'exécution, puis affiche une coche ou un point d'exclamation avec le message rendu par le raccourci. Au-delà de vingt secondes, il est arrêté. À la voix : « Hey Bud, lumière salon ». **BUD ne voit jamais vos appareils** : il ne peut lancer que ce que vous avez mis dans ce dossier.

### Système

**Réglages** — apparence (auto, clair, sombre), matière du panneau (opaque, verre dépoli, cristal), six couleurs d'accent dont le blanc, habillage du compagnon, écoute « Hey Bud », interrupteurs de comportement, et l'accès aux raccourcis clavier et aux pastilles de l'aperçu.

L'ancien onglet **Outils** n'existe plus : ses fonctions sont dans la pilule *Outils* du chat. Le verrouillage passe par `CGSession -suspend` quand le système l'offre ; sinon BUD met l'écran en veille et le dit, parce qu'une mise en veille n'est un verrouillage que si votre réglage de mot de passe le veut.

Le texte posé sur la couleur d'accent choisit le noir ou le blanc d'après la **luminance réelle** de cette couleur. Les six accents d'usine sont clairs, mais « Blanc pur » devient graphite en thème clair, et le noir sur graphite ne se lit plus.

L'habillage emprunte ses principes au verre d'iOS 26 sans prétendre l'imiter : il n'en existe aucune API en AppKit sur macOS 12, et BUD vise Monterey. Les boutons reçoivent un dégradé court plutôt qu'un aplat, un reflet spéculaire sur la moitié haute, et un liseré qui s'éteint vers le bas — c'est ce dernier qui donne l'épaisseur, un contour d'intensité constante se lisant comme un trait dessiné. Les deux primitives sont écrites une fois et partagées : vingt reflets réglés séparément finissent par diverger.

---

## Sous-agents

BUD exécute des scripts locaux selon un contrat simple : du JSON sur
l'entrée standard, du JSON sur la sortie standard. Le contrat, les règles
de sûreté et trois exemples commentés sont dans **[AGENTS.md](AGENTS.md)**.

Des processus, et non des greffons : un greffon qui plante emporte
l'application, un processus se tue ; et un sous-agent se teste seul,
depuis le Terminal, sans lancer BUD — c'est ce qui rend le système
extensible pour de bon.

Trois exemples sont posés au premier lancement et jamais réécrits
ensuite : `mail-actions` (ce qui attend une réponse, un paiement, une
échéance), `tidy-downloads` (ranger les téléchargements, en simulation par
défaut) et `watch-local` (disque, corbeille, caches, sauvegarde).

---

## Raccourcis

Ce sont les raccourcis d'usine. **Tous se changent** : Réglages → *Raccourcis clavier et pastilles de l'aperçu…* (ou pilule *Outils* du chat → *Raccourcis clavier…*), puis cliquez celui à remplacer et tapez la combinaison. Échap annule.

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

Une combinaison **déjà prise** est refusée, en nommant l'action qui l'utilise : deux actions sur la même touche, et l'une des deux ne part jamais — laquelle dépendrait de l'ordre du tableau, ce qui est indéfendable.

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
├── weather.json            le dernier relevé météo
├── update.log              le journal des mises à jour
├── agents/                 demandes et réponses des agents
├── scripts/                vos sous-agents
└── bud-ask                 passerelle en ligne de commande
```

Le trousseau macOS garde les jetons OAuth, l'identifiant client, les mots de passe d'application et la clé Google Safe Browsing facultative, sous le service `fr.lahbib.bud.gmail`. Rien de sensible n'est écrit sur disque.

Le schéma JSON est tolérant : chaque clé inconnue est ignorée, chaque clé absente prend sa valeur par défaut, et les clés devenues inutiles sont conservées. Une ancienne configuration survit à toutes les montées de version.

---

## Autorisations macOS

| Demandée pour | Où l'accorder |
|---|---|
| Piloter Mail, Musique, apparence système | Confidentialité → Automatisation |
| Collage automatique, dictée | Confidentialité → Accessibilité |
| Capture d'écran | Confidentialité → Enregistrement de l'écran — BUD le vérifie avant et propose d'ouvrir le réglage |
| Dictée et « Hey Bud » | Confidentialité → Microphone, et Reconnaissance vocale |
| Ranger et nettoyer des fichiers | Confidentialité → Fichiers et dossiers |
| Commandes Maison | Raccourcis peut demander votre accord à la première exécution d'un raccourci |

Aucune n'est demandée au lancement : chacune arrive à la première utilisation réelle de la fonction concernée.

---

## Mises à jour

BUD se met à jour **depuis l'application**, sans navigateur. Il interroge l'API des releases de ce dépôt une fois par jour, et à la demande depuis la carte « À propos ». La release est la source de vérité : elle porte à la fois le numéro de version, l'archive et les empreintes.

Quand une version paraît, une **bannière de verre** se pose en bas de la barre latérale, visible depuis n'importe quel onglet : la version, la première ligne des notes, *Mettre à jour*, et les notes complètes lisibles dans BUD. Pendant l'installation, BUDs passe au travail — les billes du tréma jonglent — et la bannière déroule les étapes :

| Étape | Ce qui est vérifié |
|---|---|
| Téléchargement | pourcentage et octets réels, annulable |
| Empreinte | SHA-256 recalculé et comparé au `SHA256.txt` publié |
| Extraction | `ditto -x -k` dans un dossier temporaire |
| Paquet | un seul `BUD.app` à la racine, **même identifiant** que l'application installée, version annoncée, architecture de ce Mac (`lipo -archs`) |
| Installation et redémarrage | script détaché, voir ci-dessous |

**Jusqu'à l'installation, rien de ce qui est installé n'est touché** : un échec ne coûte qu'un téléchargement, et BUDs prend l'air déçu.

Une application ne peut pas se réécrire pendant qu'elle tourne. Le remplacement est confié à un script détaché qui :

1. attend la fin de BUD **par son PID**, vingt secondes, puis insiste ;
2. met l'ancien paquet de côté (`BUD.app.bud-old`) au lieu de l'effacer ;
3. pose le nouveau, retire la quarantaine (`xattr -dr com.apple.quarantine`), le signe ad hoc ;
4. le relance (`open -n`) et vérifie qu'il **tient** — présent en quinze secondes, encore là quatre secondes après ;
5. sinon, remet l'ancien et le relance.

Au lancement suivant, BUD dit ce qui s'est passé. Le détail est dans `update.log`.

**Dossier protégé.** Si BUD ne peut pas écrire là où il est installé — un `/Applications` réservé aux administrateurs, un paquet appartenant à root —, macOS demande le mot de passe **avant** que BUD ne quitte ; un refus le laisse ouvert. Le script tourne alors en administrateur, rend le paquet à son propriétaire d'origine et relance BUD en votre nom.

**Ce qui ne peut pas marcher est dit avant** : BUD lancé depuis l'image disque, ou isolé par Gatekeeper (translocation), ne peut pas se remplacer — il explique quoi faire.

Vos réglages, notes et rappels vivent dans `~/Library/Application Support/BUD-Assistant/` et ne sont pas touchés.

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
  "version": "25.5",
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

Le Flux n'est pas n8n : c'est une façon de montrer et d'organiser les agents de BUD, qui tournent tous sur votre Mac. Il ne se connecte à aucun serveur d'automatisation.

L'analyse des liens n'est pas un antivirus ni une liste noire à jour : elle reconnaît les formes d'hameçonnage. Pour confronter les liens à une base de menaces, ajoutez votre propre clé Google Safe Browsing.

BUD ne parle pas à HomeKit directement : il lance les raccourcis que vous avez créés. Il ne connaît ni l'état de vos accessoires, ni leur liste.

La météo n'est pas celle d'Apple : WeatherKit exige un compte développeur payant. Elle vient d'Open-Meteo.

L'application n'est ni signée ni notarisée : elle est compilée sur votre machine, à partir de sources que vous pouvez lire intégralement.
