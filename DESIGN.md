# Charte graphique de BUD

Ce document décrit le système. Le système lui-même vit dans
[`Sources/BudDesign.swift`](Sources/BudDesign.swift) — et c'est le point
le plus important de cette page.

## Pourquoi il n'y a pas de CSS ici

BUD est une application AppKit native, écrite en Swift, sans vue web.
Une feuille de style n'aurait rien à styler : aucune vue de BUD ne lit
de CSS, et aucun navigateur n'intervient entre le code et l'écran.

Les jetons de `BudDesign.swift` tiennent exactement le rôle qu'auraient
des variables CSS — nommer les valeurs une fois, les employer partout —
avec un avantage que le CSS n'a pas ici : le compilateur refuse un jeton
qui n'existe pas.

## Le principe

Un système de design n'est pas une liste de règles écrites quelque part.
C'est le fait qu'il n'existe **qu'un seul endroit d'où sortent les
valeurs**. Tant qu'un rayon de 12 peut être tapé à la main dans un
panneau, il vaudra 13 dans un autre, et aucune relecture ne rattrapera
cela durablement.

BUD a seize panneaux. Les harmoniser un par un serait un travail à
refaire à chaque ajout. Ils partagent en revanche six primitives :

| Primitive | Emplois |
|---|---|
| `GlassButton` | 12 fichiers |
| `mkCard` → `GlassCard` | 9 fichiers |
| `SegmentedBar` | Courrier, Réglages, Capture, Musique |
| `HeroHeader` | tous les panneaux |
| `StatTile` | Courrier, Stockage, Agents |
| `ToggleRow` | Réglages |

Corriger la matière dans ces six endroits la corrige dans Compagnon,
Chat, Agents et Courrier d'un seul coup. **La cohérence n'est pas à
maintenir : elle est structurelle.**

---

## 1. Espacement

Échelle géométrique de base 4. Les valeurs intermédiaires n'existent pas.

| Jeton | Valeur | Emploi |
|---|---|---|
| `Space.xxs` | 2 | ajustement optique |
| `Space.xs` | 4 | entre une icône et son texte |
| `Space.s` | 8 | **entre un intertitre et son groupe** |
| `Space.m` | 12 | **entre deux groupes** |
| `Space.l` | 16 | marge intérieure d'une carte |
| `Space.xl` | 24 | respiration d'un panneau |
| `Space.xxl` | 32 | séparation majeure |

Un espace de 10 points dans une interface réglée sur 8 et 12 ne se
remarque pas isolément. Trois d'entre eux suffisent à donner cette
impression d'à-peu-près qu'on n'arrive plus à nommer.

L'écart **entre groupes** (12) est plus grand que l'écart **dans un
groupe** (8). Cette différence de quatre points est ce qui dit au regard
quels éléments vont ensemble. C'est la seule hiérarchie qui fonctionne
sans libellé.

## 2. Rayons

| Jeton | Valeur | Emploi |
|---|---|---|
| `Radius.xs` | 6 | étiquettes, puces |
| `Radius.s` | 10 | champs, cellules |
| `Radius.m` | 13 | cartes de contenu |
| `Radius.l` | 16 | panneaux |
| `Radius.xl` | 20 | entêtes |
| `Radius.pill(h)` | h ÷ 2 | **tous les boutons** |

Les boutons sont des capsules. C'est le seul rayon qui ne change pas
d'aspect avec la hauteur, donc le seul qui reste identique d'un bouton
de 28 points à un bouton de 56.

## 3. Typographie

Six rôles, et des graisses franchement contrastées.

| Rôle | Taille | Graisse | Emploi |
|---|---|---|---|
| `Typo.display` | 22 | gras | titre d'entête |
| `Typo.title` | 17 | gras | titre de carte |
| `Typo.heading` | 13,5 | demi-gras | sous-titre, expéditeur |
| `Typo.body` | 12,5 | moyen | texte courant |
| `Typo.caption` | 11 | normal | légende, aide |
| `Typo.micro` | 9,5 | gras, capitales | intertitre |

Le contraste de **graisse** fait la hiérarchie bien mieux que le
contraste de **taille**, et il survit aux écrans à faible densité, où
deux points d'écart ne se distinguent plus.

Opacités d'encre : `strong` 1,00 · `normal` 0,78 · `muted` 0,55 ·
`faint` 0,38 · `ghost` 0,26.

Les chiffres qui changent — heures, pourcentages, volumes — passent en
**chasse fixe**. Sans cela la valeur tremble à chaque mise à jour, un
« 1 » étant plus étroit qu'un « 8 ».

### Lisibilité selon le thème

Le texte posé sur la couleur d'accent choisit le noir ou le blanc selon
la **luminance réelle** de cette couleur, jamais selon une supposition.
Les six accents d'usine sont clairs, mais « Blanc pur » devient graphite
en thème clair : le noir y devient illisible.

## 4. Matières

Le verre dépoli tient en quatre couches, **toujours dans cet ordre** :

1. le fond translucide, légèrement dégradé ;
2. le reflet spéculaire sur la moitié haute ;
3. le liseré, vif en haut, éteint en bas ;
4. le contour de base, qui ferme la forme.

Les intervertir donne du plastique.

Le liseré fait le plus gros du travail : un contour d'intensité
constante se lit comme **un trait dessiné**, un contour qui s'éteint se
lit comme **une épaisseur**. AppKit ne sait pas dégrader le long d'un
tracé — il est donc peint en quatre bandes horizontales, dont les
marches ne se voient pas à cette échelle.

### Élévation

| Niveau | Emploi |
|---|---|
| 0 | le fond d'un conteneur creux |
| 1 | une carte, un bouton au repos |
| 2 | un bouton survolé, une cellule choisie |
| 3 | un élément saisi |

### La valeur la plus discrète

Les fonds portent **une pointe de bleu** (0,76 / 0,82 / 0,95 en thème
sombre). Un gris parfaitement neutre sur fond sombre paraît sale ; deux
pour cent de bleu suffisent à le rendre calme, sans qu'on puisse dire
pourquoi. C'est le jeton le moins visible et le plus utile de la charte.

### Couleur

L'accent appartient à l'utilisateur : six teintes, qu'il choisit. Le
système ne le remplace pas, il l'encadre — l'accent ne sert qu'à **une
seule chose par vue** (l'élément actif), et jamais à décorer.

Les couleurs de sens sont fixes et ne se négocient pas :

| Rôle | Emploi |
|---|---|
| `dangerColor` | destruction, menace, disque saturé |
| `warnColor` | seuil approché |
| teintes de catégorie | type de courrier, groupe d'outils |

## 5. Mouvement

Trois durées, pas davantage.

| Jeton | Durée | Emploi |
|---|---|---|
| `Motion.quick` | 0,12 s | survol, pression |
| `Motion.base` | 0,22 s | bascule, apparition |
| `Motion.slow` | 0,38 s | ouverture de panneau |

Une interface où chaque transition a sa propre durée paraît hésitante,
alors même que chaque animation prise séparément semble correcte.

Les courbes ne sont **pas symétriques** : ce qui apparaît démarre vite
et ralentit (`Motion.enter`), ce qui disparaît fait l'inverse
(`Motion.exit`). Une sortie lente donne l'impression que l'application
réfléchit avant d'obéir.

`Motion.ease(value:to:rate:dt:)` approche une cible indépendamment de la
cadence d'affichage : une animation réglée en « fraction par image »
s'emballe sur un écran à 120 Hz.

### Micro-animations

- **Boutons** : élévation 1 → 2 au survol, enfoncement à la pression.
- **Barre segmentée** : la cellule choisie s'élève et prend l'accent.
- **Navigation** : l'indicateur glisse d'une entrée à l'autre.
- **Compagnon** : BUD salue quand on ouvre son panneau, tressaille quand
  on en ouvre un autre — mais seulement **au changement**. Rejouer
  l'animation sur un clic répété donnerait l'air d'une application qui
  n'a pas compris.
- **Lecture en cours** : pas de côté et inclinaison partent du même
  temps et du même côté, et le côté alterne. C'est leur accord qui fait
  la danse ; les dissocier donne deux mouvements qui se contrarient.

---

## Ce que la charte ne fait pas

Elle ne reproduit pas le verre d'iOS 26. Il n'en existe aucune API en
AppKit sur macOS 12, et BUD vise Monterey. Les principes en sont repris
à la main — matière, reflet, liseré — sans prétendre à l'équivalence.

Elle ne remplace pas non plus les couleurs choisies par l'utilisateur,
ni ne redessine les seize panneaux un par un. Elle agit sur les six
primitives qu'ils partagent, et c'est par là que l'harmonie se propage.
