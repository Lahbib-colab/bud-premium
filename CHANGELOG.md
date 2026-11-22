# Journal des versions

Les numéros suivent `budVersion` dans `Sources/BudCore.swift`.

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
