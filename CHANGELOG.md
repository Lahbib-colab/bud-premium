# Journal des versions

Les numéros suivent `budVersion` dans `Sources/BudCore.swift`.

## 23.5 — lisibilité du courrier, remise en ordre des outils

**Le courrier**

- **Trois lignes par message** au lieu de deux : expéditeur, objet, et enfin un **aperçu du corps**. Le texte était déjà récupéré — il servait à citer le message dans une réponse — mais la liste ne le montrait jamais.
- **Les colonnes s'alignent.** La pastille de non-lu décalait le texte de 12 pt vers la droite : un message lu et un non-lu ne commençaient pas à la même abscisse, et la colonne ondulait d'une ligne à l'autre. La pastille garde maintenant sa place, occupée ou non.
- **Les dates deviennent lisibles.** `String(date.prefix(17))` coupait l'en-tête au caractère près, au milieu d'un mot dès que le fuseau s'écrivait autrement. La date est analysée puis réécrite comme dans un logiciel de courrier : l'heure aujourd'hui, « hier », le jour et le mois cette année. L'analyse se fait en locale POSIX — un Mac en français ne reconnaît ni « Sun » ni « Nov » — et l'affichage suit la langue du système.
- **L'objet occupe toute la largeur.** Il héritait de la largeur réservée à la date et au verdict, qui ne concernent que la première ligne, et se trouvait tronqué pour rien.
- L'interligne était de 1 pt entre l'expéditeur et l'objet, avec 7 pt perdus en haut et en bas. Les trois lignes descendent maintenant d'un pas régulier.
- La passerelle Mail.app rapporte l'aperçu elle aussi, **coupé à 200 caractères du côté d'AppleScript** : un message de plusieurs mégaoctets n'a pas à traverser la sortie d'`osascript` pour qu'on n'en garde qu'une ligne.
- La carte d'analyse **reste en place** même sans sélection : elle apparaissait et disparaissait au clic, et le bas du panneau sursautait.
- Les deux modes — Boîte et Rédiger — partagent désormais le même cadre, bord haut et bord bas : la bascule ne décale plus rien.

**Les outils**

- Quatre groupes titrés — Recherche, Système, Applications, Capture d'écran — là où un seul des quatre portait un intertitre.
- Un seul rythme vertical. Les rangées mesuraient 42, 44 et 48 pt selon l'endroit ; les positions, calculées une à une, se contredisaient. Elles descendent maintenant d'un pas constant, donc elles ne peuvent plus diverger.
- Le trou de 60 pt au-dessus du pied est comblé.
- **Une seule zone de compte rendu** au lieu de deux étiquettes concurrentes — l'une sous les outils système, l'autre sous la capture. Apparence basculée, adresse IP, application ouverte, capture enregistrée : tout arrive au même endroit, dans une carte qui le distingue des boutons.

## 23.4 — la pochette

- **La pochette de l'album s'affiche** : en grand dans le panneau Musique, et en vignette de 18 pt dans le notch replié, à côté des barres de l'égaliseur et du titre défilant. En pause, elle reste mais s'assombrit — l'album ne change pas parce que la lecture s'arrête.
- Un morceau sans pochette, une radio, un flux : une note de musique tient la place, et BUD ne redemande pas l'export à chaque sondage.
- L'export passe par le `raw data` de l'illustration, écrit dans un fichier puis relu : l'image ne traverse jamais la sortie standard d'`osascript`. L'écriture a lieu **hors** du bloc `tell application "Music"`, car `open for access` appartient aux Standard Additions et Music publie son propre verbe `open` — à l'intérieur, c'est le sien qui gagnait.
- Le fichier est écrit dans `Application Support`, pas sur le Bureau : un dossier protégé aurait fait surgir une demande d'autorisation pour `osascript`.
- Le script renvoie la piste qu'il a réellement lue, et non celle qu'on croyait lui demander : si le morceau change pendant l'export, la pochette est rangée sous la bonne clé au lieu de rester collée au suivant.
- Un seul export par morceau, partagé par le notch et le panneau : les appelants simultanés sont servis par le même aller-retour.
- `persistent ID` identifie le morceau ; à défaut — radio, flux — le couple titre/artiste/album en tient lieu. Le champ est lu à part, pour qu'un identifiant absent ne fasse pas perdre les huit autres propriétés.

## 23.3 — mise à jour intégrée

- **Empreinte vérifiée.** BUD télécharge le `SHA256.txt` publié avec la release, retrouve la ligne de son archive et recalcule le SHA-256 du fichier reçu, par tranches de 1 Mo. Une empreinte qui diffère interrompt tout : un téléchargement abîmé ne s'installe pas. Si la release ne publie aucune empreinte, l'installation continue mais le dit — « intégrité non vérifiée ».
- **Version du paquet contrôlée** : l'`Info.plist` de l'archive doit annoncer la version attendue. Sans ce contrôle, une release mal assemblée réinstallerait l'ancienne version en boucle.
- **Barre de progression réelle** dans la carte « À propos ». Elle se remplit pendant le téléchargement, et passe en navette va-et-vient pour les étapes de durée inconnue — vérification de l'empreinte, décompression — plutôt que d'inventer un pourcentage.
- La progression n'est remontée qu'au changement de pourcentage entier : la notification KVO se déclenche des centaines de fois par seconde, et l'interface redessinait pour rien.
- L'archive est mise à l'abri dès réception : le fichier temporaire d'URLSession est supprimé dès le retour du bloc de complétion, ce qui faisait disparaître le téléchargement avant même sa vérification.
- Rien ne bloque le fil principal : téléchargement, empreinte, décompression et échange de paquets se déroulent en arrière-plan. BUD reste utilisable pendant l'opération.

## 23.2

- Corrige `SHA256.txt`, qui ne contenait que des noms de fichiers. Le `sed 's|.*/||'` destiné à retirer le chemin était glouton et avalait l'empreinte avec lui. Les empreintes sont maintenant calculées depuis le dossier, sans chemin à nettoyer, et la publication échoue si le fichier ne contient pas de ligne d'empreinte valide — un fichier qui a l'air de garantir quelque chose sans rien garantir est pire qu'absent.
- Le fichier publié avec la v23.1 est donc erroné ; cette version le remplace.

## 23.1

- **Les releases GitHub deviennent le canal de mise à jour.** Le bouton télécharge l'archive de l'application, remplace le paquet et redémarre BUD. Il n'ouvre plus de page web. Une confirmation précède toujours le remplacement, et un troisième bouton permet de lire les notes d'abord.
- **Binaire universel.** Les machines GitHub sont en arm64 ; un installeur compilé tel quel ne démarrerait pas sur un Mac Intel. `build.sh --universal` compile les deux architectures depuis la même machine et les fusionne avec `lipo`. La CI vérifie que les deux tranches sont présentes avant de publier.
- **Garde-fou à l'installation** : BUD lit `lipo -archs` sur le binaire téléchargé et refuse une version qui ne contient pas son architecture, plutôt que de se faire tuer au lancement sans explication.
- **Remplacement réversible** : une application ne peut pas se réécrire pendant qu'elle tourne. Un script attend la fin de BUD, échange les paquets, et restaure l'ancien si le nouveau ne démarre pas.
- La publication se déclenche sur un changement de `budVersion` dans `Sources/BudCore.swift` — pas de tag à créer à la main. Trois fichiers sont joints : le `.dmg` à glisser, le `.zip` que l'updater consomme, et l'installeur par les sources, plus les empreintes SHA-256.
- L'API des releases est désormais la source de vérité : la release porte le numéro et les installeurs, il n'y a plus de fichier de version à tenir en parallèle. `version.json` reste accepté comme canal personnalisé.

## 23.0

- **Capture d'écran** — tout l'écran, une fenêtre, ou une sélection, vers le Bureau ou le presse-papiers. BUD délègue à `screencapture`, l'outil du système, qui sait déjà gérer les écrans multiples, le Retina et l'espace colorimétrique. Le notch se replie avant la prise, sinon il figurerait sur chaque capture. Une image de moins de 4 Ko trahit l'autorisation « Enregistrement de l'écran » manquante : BUD le dit au lieu de laisser un fichier noir sur le Bureau.
- **Courrier en deux modes** — *Boîte* et *Rédiger* se partageaient 570 pt et se retrouvaient tous deux à l'étroit. Chacun occupe maintenant toute la hauteur : la liste passe de 174 à 274 pt, le corps du message de 70 à 294 pt. « Répondre » bascule en rédaction, l'envoi réussi ramène à la boîte.
- **Musique recentrée sur Apple Music.** Spotify et surtout Alexa sont retirés : Amazon n'expose aucune interface locale sur macOS, et le piloter par les touches média d'un lecteur web était un bricolage qui réclamait l'autorisation Accessibilité pour un résultat imprévisible.
- Contrôle enrichi : barre de progression, position et durée, recul et avance de 15 s, curseur de volume, lecture aléatoire, répétition (aucune, tout, ce titre). Un seul aller-retour AppleScript rapporte l'état complet, chaque propriété lue dans son propre `try`.
- **BUD danse pendant la lecture.** Le notch replié montre le titre défilant à la place de l'heure, avec quatre barres d'égaliseur, et le personnage prend le rythme par impulsions dans ses ressorts. Honnêteté : macOS n'expose aucun niveau audio en sortie sans capturer le flux, ce que BUD ne fait pas — le rythme est régulier et synthétique, c'est un signe de vie, pas une mesure du morceau.
- Le sondage de lecture ne coûte rien quand Musique est fermée : le test d'exécution passe par `NSWorkspace`, sans lancer de processus.

## 22.0

- **Compilation réparée.** Les versions 20 et 21 appelaient `swiftc` par son chemin résolu (`xcrun --find swiftc`) au lieu de passer par `xcrun`. Or c'est `xcrun` qui positionne `SDKROOT` : sans lui le compilateur échouait sur `unable to load standard library`. Toutes les compilations repassent par `xcrun --sdk macosx swiftc`.
- Repli sur le `swiftc` du PATH si `xcrun` est muet, puis sur un Xcode complet si la chaîne ne compile rien.
- Un SDK illisible n'est plus diagnostiqué comme « antérieur à Big Sur » : seul un numéro réellement inférieur à 11 déclenche ce verdict.

## 21.0 — courrier

- **Répondre.** Objet préfixé, corps cité, et reprise du `Message-ID` en `In-Reply-To` et `References` pour que la réponse se range dans le fil. Si le `Reply-To` diverge du `From`, BUD garde le `From` : c'est la manœuvre employée pour détourner une réponse.
- **Analyse de hameçonnage locale** (`Sources/BudGuard.swift`) — SPF, DKIM et DMARC lus dans les en-têtes, puis usurpation de nom affiché, marque citée sans le domaine qui va avec (29 marques françaises), punycode, alphabets mélangés, lien affichant un domaine et menant à un autre, adresse IP brute, pièce jointe exécutable, double extension, macros, inversion d'écriture, vocabulaire d'urgence. Aucun réseau, aucun modèle de langage.
- **Quarantaine IMAP** par `UID MOVE`, avec repli copie puis purge. Le dossier indésirable est demandé au serveur par son rôle `\Junk`, car son nom est traduit.
- **Analyse des téléchargements** : formes dangereuses repérées par BUD, verdict de signature délégué à Gatekeeper. Les fichiers partent à la corbeille, jamais à la destruction.
- Boîte de réception refaite : huit derniers messages lus ou non, lignes cliquables, liseré de verdict, trombone, trois compteurs.
- La veille annonce « Message dangereux » dans le notch avant ouverture.

## 20.0

- Préflight des outils de développement : outils sélectionnés, SDK, cible, affichés avant de compiler. Arrêt net avec les commandes de remède si le SDK est antérieur à macOS 11.
- Le diagnostic s'exécute **avant** toute suppression : un échec laisse l'installation précédente intacte. La 19 effaçait `BUD.app` puis échouait.
- Sondage de l'orthographe de la cible (`macos12.0`, puis `macosx12.0`, puis `MACOSX_DEPLOYMENT_TARGET`).

## 19.0 — Monterey à Sequoia

- Signature ad hoc du paquet : **obligatoire pour exécuter du arm64**.
- `-swift-version 5` explicite, pour qu'une chaîne Swift 6 ne bascule pas en concurrence stricte.
- Écouteur OAuth restreint à `127.0.0.1` — durcissement de sécurité, non une exigence de macOS 15 : d'après la note technique TN3179 d'Apple, accepter une connexion TCP entrante ne demande aucune autorisation « Réseau local ». Avec repli si le port résolu revient à zéro.

## 18.0

- Troisième habillage **Métal** : tête de robot, coque ardoise, cadre argenté, écran facial sombre, yeux carrés lumineux prenant la couleur d'accent. Sélecteur à trois voies dans Compagnon → Habillage.

## 17.0

- Nouveau personnage : squircle blanc, joues pastel, bouche en « O ». Six humeurs, ressorts amortis en exponentielle, ombre au sol réactive. Second habillage nacré-or.

## 16.0

- Appairage Gmail **par téléphone** : QR code dessiné par Core Image, mot de passe d'application ou OAuth consenti sur le téléphone. Le *device flow* de Google n'accepte pas les scopes Gmail, d'où ces deux voies.

## 15.0 et avant

Notch à quatre états, rangement par glisser-déposer, tableau de bord de stockage, nettoyage, focus, notes, snippets, presse-papiers, agents IA, chat local, rappels avec alarme, musique, courrier, thèmes et accents, vérification de mise à jour animée.
