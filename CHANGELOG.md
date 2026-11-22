# Journal des versions

Les numéros suivent `budVersion` dans `Sources/BudCore.swift`.

## 24.0 — la fenêtre réparée, le courrier instantané

**Fenêtre « Raccourcis et aperçu »**

- **Les menus des pastilles ne répondaient pas**, et la cause n'était pas dans les menus. L'étiquette de statut occupait 50 à 80 points, les menus 60 à 86 : elle les recouvrait de vingt points. Posée après eux, elle était au-dessus — et un `NSTextField`, même non modifiable, reste une cible de clic. Elle avalait donc tout ce qui leur était destiné. Les deux symptômes, texte chevauché et contrôles inertes, n'en faisaient qu'un.
- Par précaution, l'étiquette ne prend plus aucun clic, quelle que soit sa position : une ligne de statut n'a rien à intercepter.
- **Les intitulés étaient tronqués** — « Disques ex… », « Focus en c… ». Quatre menus de front recevaient 113 points chacun. Deux rangées de deux leur en donnent 252, où « Disques externes » tient en entier.
- **La fenêtre passait derrière BUD.** Le panneau de BUD vit au niveau `.statusBar` ; une fenêtre ordinaire se retrouvait dessous dès qu'on rouvrait le panneau, et devenait inatteignable. C'est maintenant un `NSPanel` flottant, placé juste au-dessus, qui peut encore devenir fenêtre clé — nécessaire, car le capteur de raccourci écoute par un moniteur local, qui ne reçoit les touches que si la fenêtre a le focus.

**Courrier — le corps n'est plus pollué**

`fetchSnippet` gardait **toutes** les lignes de la réponse IMAP, y compris celle qui l'ouvre — `* 9284 FETCH (UID 9284 BODY[1]<0> {2048}` — et la parenthèse qui la ferme. La commande s'affichait donc en tête du message, et était en plus donnée à l'analyse de hameçonnage comme si c'était du texte de l'expéditeur. Les deux lignes d'encadrement sont écartées, et le cas du corps court renvoyé entre guillemets sur la même ligne est traité. Rejoué sur quatre formes de réponse réelles.

**Courrier — affichage instantané**

- **Un cache sur disque.** La boîte s'affiche immédiatement avec le dernier état connu, au lieu d'une liste vide pendant que le serveur répond. Le cache est lié au compte : changer de compte l'efface, car montrer le courrier du compte précédent serait une fuite et non une optimisation.
- **Un sondage qui coûte un aller-retour.** `STATUS INBOX (UIDNEXT UNSEEN)` dit si quelque chose a bougé sans rapatrier un seul message. Le relevé complet — session TLS, authentification, recherche, soixante en-têtes, douze corps — n'a lieu que si la réponse a changé.
- **Une synchronisation de fond** toutes les quatre-vingt-dix secondes, hors du fil principal, avec une tolérance de vingt secondes pour se grouper avec les autres réveils du système. Le courrier arrive tout seul ; « Actualiser » n'est plus obligatoire.
- La liste n'est **redessinée que si elle a changé** : repeindre soixante cartes identiques ferait sauter le défilement et perdrait la sélection pour rien.
- « Actualiser » impose le relevé complet et saute le sondage, car il doit aussi voir ce que le sondage ne détecte pas — une suppression faite depuis un autre appareil.

**Ce que ce n'est pas.** Pas du push. IMAP IDLE demanderait de tenir une connexion ouverte en permanence, de la rouvrir à chaque réveil de veille et de gérer son expiration toutes les vingt-neuf minutes. C'est faisable ; ce n'est pas fait ici, et le sondage intelligent en donne l'essentiel pour une fraction du risque.

## 23.9 — une charte, et un seul endroit d'où sortent les valeurs

**`Sources/BudDesign.swift`** — la couche de jetons dont toute l'interface hérite : espacement, rayons, rôles typographiques, durées et courbes, matières et élévations.

BUD est une application AppKit : il n'y a pas de CSS, et une feuille de style n'aurait rien à styler. Les jetons en tiennent le rôle — nommer les valeurs une fois, les employer partout — avec un avantage que le CSS n'aurait pas ici : le compilateur refuse un jeton qui n'existe pas.

**Ce qui rend la chose structurelle.** Les seize panneaux partagent six primitives : `GlassButton` (12 fichiers), `mkCard` (9), `SegmentedBar`, `HeroHeader`, `StatTile`, `ToggleRow`. Corriger la matière à ces six endroits la corrige dans Compagnon, Chat, Agents et Courrier d'un seul coup. La cohérence n'est plus à maintenir panneau par panneau.

- **Une seule fonction dessine toute surface de verre** — `drawGlass(in:radius:level:hover:tint:)` — en quatre couches toujours dans le même ordre : fond dégradé, reflet spéculaire, liseré qui s'éteint, contour de fermeture. Les intervertir donne du plastique.
- Les boutons et la barre segmentée y passent : un bouton au repos est une surface de niveau 1 qui monte au niveau 2 sous le curseur, exactement comme une carte. C'est ce partage qui évite qu'un bouton du Courrier ait l'air d'un autre matériau qu'une carte du Chat.
- **`mkCard` rend maintenant une carte qui se dessine** au lieu d'une vue dont on colorait le calque. Elle relit donc le thème à chaque affichage, et un changement de thème ne peut plus la laisser avec une couleur périmée. Les quarante appels existants n'ont pas bougé : le paramètre `alpha` est traduit en niveau d'élévation.
- **Une pointe de bleu dans les fonds.** Un gris parfaitement neutre sur fond sombre paraît sale ; deux pour cent de bleu suffisent à le rendre calme, sans qu'on puisse dire pourquoi. C'est le jeton le moins visible et le plus utile de la charte.
- **Trois durées de mouvement, pas davantage**, et des courbes asymétriques : ce qui apparaît démarre vite et ralentit, ce qui disparaît fait l'inverse. Une sortie lente donne l'impression que l'application réfléchit avant d'obéir.
- **BUD accuse réception d'un changement de mode** : il salue quand on ouvre son panneau, il tressaille quand on en ouvre un autre — seulement au changement, car rejouer l'animation sur un clic répété donnerait l'air d'une application qui n'a pas compris.
- L'écart entre deux groupes (12) est plus grand que l'écart au sein d'un groupe (8). Ces quatre points sont ce qui dit au regard quels éléments vont ensemble : la seule hiérarchie qui fonctionne sans libellé.

**[`DESIGN.md`](DESIGN.md)** — la charte écrite, versionnée avec le code qui l'applique, y compris ce qu'elle ne fait pas : elle ne reproduit pas le verre d'iOS 26, dont aucune API n'existe en AppKit sur macOS 12.

## 23.8 — matière, lisibilité, et BUD qui danse

**Lisibilité selon le thème** — un vrai défaut corrigé

- Le texte posé **sur la couleur d'accent** était du quasi-noir, quelle que soit la teinte. Les six accents d'usine sont clairs, donc cela passait — sauf que « Blanc pur » devient graphite en thème clair, et le noir sur graphite ne se lit plus. La couleur du texte se décide maintenant d'après la **luminance réelle** de l'accent, ce qui tiendra aussi pour toute teinte ajoutée plus tard.

**Affichage du stockage quand le disque est plein** — le bug que vous aviez signalé

- « 100 % » est plus large que « 7 % ». Sur un disque presque plein, la colonne de droite s'élargissait, et la barre de progression recevait alors une **largeur négative** pendant que le nom du volume passait sous le pourcentage. Trois planchers de mise en page corrigent cela, et l'étiquette de type s'efface avant le nom quand la place manque : mieux vaut savoir *quel* volume c'est que de quel *genre* il est.
- L'alerte ressemble enfin à une alerte : la capsule de l'entête et l'anneau prennent l'ambre puis le rouge, et le pourcentage de chaque volume se colore.
- Le seuil est celui que **vous** avez réglé, plus un 10 écrit en dur : annoncer « disque saturé » à 10 % quand vous avez demandé 25 revenait à ignorer le réglage.
- Le seuil n'est plus relu depuis le fichier d'état à chaque rafraîchissement et pour chaque volume : un accès disque pour un entier.

**L'heure de l'aperçu** — l'entête affichait 15:23 pendant que la pastille affichait 15:24. L'heure du titre était posée une seule fois, à l'ouverture de l'aperçu, tandis que la pastille se rafraîchissait chaque seconde. Les deux s'écrivent maintenant au même instant.

**Matière des boutons**

- Le verre d'iOS 26 n'a pas d'API en AppKit sur macOS 12, et BUD vise Monterey : on en reprend les principes à la main, sans prétendre à autre chose. Un dégradé court plutôt qu'un aplat, un **reflet spéculaire** sur la moitié haute, et un **liseré qui s'éteint vers le bas**.
- C'est le liseré qui fait le plus : un contour d'intensité constante se lit comme un trait dessiné, un contour qui s'éteint se lit comme une épaisseur. Comme AppKit ne sait pas dégrader le long d'un tracé, il est peint en quatre bandes horizontales — à cette échelle, les marches ne se voient pas.
- Les deux primitives sont **partagées**, écrites une fois : vingt reflets réglés séparément finissent par diverger, et c'est ce qui défait l'harmonie d'une interface.

**BUD danse**

- Pendant la lecture, un pas de côté et une inclinaison s'ajoutent au rebond, **du même côté et sur le même temps** : c'est leur accord qui fait la danse. Le côté alterne à chaque temps — sans cela BUD tremblerait sur place.
- Le ressort du balancement est plus mou que celui du saut, pour qu'il traîne un peu derrière le temps, comme un corps qui suit la musique.
- L'amplitude est proportionnelle à la taille : BUD danse pareil dans le notch à 34 pt et dans le panneau à 200.

**Raccourcis**

- **Plus de doublon possible** : une combinaison déjà prise est refusée à la saisie, en nommant l'action qui l'utilise. Deux actions sur la même touche, et l'une ne part jamais — laquelle dépendrait de l'ordre du tableau, ce qui est indéfendable.
- Le réglage est maintenant accessible **depuis les Réglages** et plus seulement depuis Outils. Les interrupteurs passent de trois à quatre colonnes, ce qui libère la rangée nécessaire.

## 23.7 — la boîte au complet, le volume du Mac, les pastilles au choix

**La boîte**

- **Toute la boîte** : soixante messages au lieu de huit.
- Le corps n'est rapatrié que pour les douze premiers. Au-delà, il se charge **à l'ouverture** du message : soixante allers-retours de 8 Ko chacun auraient fait attendre une minute avant le premier affichage. Le corps chargé est conservé — y revenir ne redemande rien.
- Ce chargement ouvre la boîte en `EXAMINE` et non `SELECT` : **en lecture seule**, pour qu'ouvrir un message ne le marque pas comme lu à votre insu.
- Par la passerelle Mail.app, la limite reste à vingt : AppleScript n'a pas de chargement différé, chaque message coûte son corps dans la même réponse.

**Classement par type**, façon Mail : Principal, Transactions, Mises à jour, Promotions — avec « Tous » en premier et sélectionné par défaut, parce qu'un classement qui cache du courrier dès l'ouverture serait un piège.

- Le signal décisif n'est **pas dans l'objet** mais dans les en-têtes : `List-Unsubscribe`, `List-Id`, `Precedence`. Un message qui porte un lien de désabonnement est un envoi en masse — l'expéditeur le déclare lui-même et n'a aucun intérêt à mentir, contrairement à un objet, qu'on écrit pour attirer l'œil.
- Une transaction prime sur tout : une confirmation de commande part souvent d'une plateforme qui ajoute un lien de désabonnement, et la ranger en promotions ferait perdre la seule trace d'un achat.
- Règles rejouées en Python sur dix-huit cas réalistes : 18 sur 18 bien rangés, « J'ai bien reçu ton message » compris, qui reste au principal.
- Le type s'affiche en petit sur chaque ligne : on voit pourquoi un message est là où il est.

**Sélection multiple** — bouton *Sélection*, puis une case prend la place de chaque pastille d'initiales, exactement à son emplacement pour que la colonne de texte ne bouge pas. *Supprimer* agit alors sur tout ce qui est coché, en une seule commande IMAP, après confirmation.

**Le lecteur**

- **Le volume du Mac**, enfin, avec sa coupure du son. Jusqu'ici le curseur réglait `sound volume`, le niveau de Musique dans le mélangeur — pas `output volume`, celui des touches du clavier. Baisser l'un n'agit pas sur l'autre, et chercher pourquoi « le volume ne fait rien » quand c'est l'autre qui est à zéro peut durer longtemps. Les deux sont là, nommés.
- Monter le son d'un Mac coupé le rallume : sinon le curseur bouge et rien ne sort.
- Un vrai bouton **Arrêt**, distinct de Pause : Musique revient au début du morceau, ce que la pause ne fait pas.
- Le bouton central montre l'action à venir et non l'état présent — pause pendant la lecture, lecture à l'arrêt.
- Le volume du Mac reste réglable **même Musique fermée** : il ne dépend pas d'elle, et c'est souvent là qu'on le cherche.

**Les pastilles de l'aperçu**

- Les quatre capsules sous la salutation étaient figées et décoratives. Elles sont maintenant **au choix** parmi dix — espace libre, disques externes, agents, focus, heure, batterie, courrier non lu, prochain rappel, lecture en cours, mémoire libre.
- **Teintées** chacune de sa couleur, et **cliquables** : un clic ouvre le panneau correspondant. Celle qu'on survole s'éclaire de sa propre teinte, ce qui dit qu'elle se clique sans ajouter un libellé.
- Les rectangles sont mémorisés au dessin plutôt que recalculés pour le clic : une mise en page faite deux fois, c'est deux occasions de diverger.
- Le réglage vit dans la fenêtre *Raccourcis et aperçu*, avec les raccourcis clavier.

## 23.6 — lire, balayer, dicter

**Lire un message en entier**

- Un troisième mode, **Lecture** : en-tête avec la pastille de l'expéditeur, son adresse, la date écrite en entier, le verdict d'analyse et les pièces jointes — puis le corps, sélectionnable, avec un interligne large.
- Aucun aller-retour réseau de plus : le corps était **déjà rapatrié et décodé** au relevé de la boîte (8 Ko, guillemets-imprimables et base64 défaits) et ne servait qu'à citer un message en réponse. Il suffisait de le présenter.
- Beaucoup de courriels n'ont qu'une version HTML. BUD n'en fait pas un rendu : il en **extrait le texte**, en transformant d'abord les balises de bloc en sauts de ligne — sans quoi tout se recollerait en un seul paragraphe — puis retire les scripts, les balises et les entités.
- Un clic sur une ligne ouvre le message. Lire est ce qu'on veut faire d'un courriel ; viser un onglet pour y arriver serait étrange.

**Balayage**

- **Vers la gauche : supprimer.** Rouge, avec une corbeille, et une confirmation — un balayage est vite fait sans le vouloir.
- **Vers la droite : répondre.** Bleu, et la réponse s'ouvre directement : répondre ne détruit rien.
- La carte glisse, le fond coloré reste dessous, la couleur s'affirme au passage du seuil. Retour élastique dans tous les cas.
- Un trackpad n'envoie pas de « geste de balayage » mais des événements de défilement : la direction est décidée **une fois**, au début du geste, et tenue jusqu'au relâchement. Arbitrer à chaque événement ferait sauter la carte entre défilement et balayage au moindre tremblement. Le défilement vertical de la liste reste intact, et une molette de souris ne balaie pas.
- Le sens suit le **doigt**, pas le réglage. AppKit applique déjà « défilement naturel » à `scrollingDeltaX` : sans défaire cette inversion, un balayage vers la gauche aurait déclenché l'action inverse chez qui a désactivé ce réglage.
- Rien n'est effacé : le message va à la **corbeille du compte**, d'où il se reprend. Le dossier est demandé au serveur par son rôle `\Trash`, car son nom est localisé.

**Couleur**

- Une **pastille d'initiales** par expéditeur, de teinte tirée de son adresse : le même correspondant garde sa couleur d'une session à l'autre, et on le reconnaît avant d'avoir lu son nom. Douze teintes discrètes plutôt qu'une roue continue, où deux adresses voisines donneraient deux couleurs indiscernables.
- La pastille de non-lu devient un **écusson sur le disque**, avec un liseré sombre pour s'en détacher.
- Les icônes des outils sont **teintées par groupe** — indigo, ambre, orange, turquoise, bleu, violet — sans toucher à la lisibilité des titres.

**L'heure comme sur un iPhone**

- Heure en gras à gauche de la barre repliée, date du jour à sa droite en plus discret. Chiffres à largeur fixe, sinon l'heure tremblerait à chaque minute : un « 1 » est plus étroit qu'un « 8 ».

**Le chat sait faire plus**

- Batterie, adresse IP et réseau, verrouillage de l'écran, veille écran, apparence claire ou sombre, capture d'écran, compte à rebours, recherche web.
- **Et il calcule** : « 23 × 7 », « (120 + 80) / 4 », « 20 % de 480 ». L'évaluateur est écrit à la main — descente récursive sur quatre niveaux de priorité — et non confié à `NSExpression`, qui sait instancier des classes et appeler des méthodes par leur nom : lui passer une chaîne venue du champ de saisie serait lui donner les clés de l'application pour additionner deux nombres.
- Un chiffre **et** un opérateur sont exigés avant de répondre par un calcul, sinon « mes 5 mails » deviendrait un résultat.

**Raccourcis au choix**

- Les dix raccourcis sont réglables dans leur propre fenêtre : on clique, on tape la combinaison, Échap annule.
- Un raccourci sans ⌘, ⌃ ni ⌥ est **refusé** : il intercepterait la frappe ordinaire dans toutes les applications.
- Le capteur installe un moniteur **local**, retiré dès la capture finie — un moniteur global avalerait les touches de tout le système pendant l'enregistrement.
- Stockés dans un dictionnaire indexé par action : ajouter une action ne demande aucune migration, et ce qui manque retombe sur l'usine.

**Dictée, sur l'appareil**

- Un micro à côté du champ du chat. Le texte s'écrit au fil des mots, et part quand vous vous arrêtez de parler.
- `requiresOnDeviceRecognition` est posé, **et vérifié** : la documentation d'Apple précise que le drapeau n'est honoré que si `supportsOnDeviceRecognition` est vrai. Si ce Mac ne sait pas reconnaître le français hors ligne, BUD **refuse la dictée et dit pourquoi**, plutôt que d'envoyer silencieusement votre voix aux serveurs d'Apple.
- Le format d'entrée est vérifié avant de poser la prise audio : `installTap` lève autrement une exception Objective-C que Swift ne rattrape pas, et l'application s'arrêterait net.

**Outillage**

- `Tools/braces.py` : un analyseur lexical Swift qui compte vraiment les accolades — interpolations `\(…)`, chaînes multilignes, chaînes brutes, commentaires de bloc imbriqués. Le contrôle par expressions régulières donnait de fausses alertes dès qu'une interpolation contenait une parenthèse.

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
