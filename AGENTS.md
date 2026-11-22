# Sous-agents de BUD

Un sous-agent est un exécutable qui reçoit du JSON sur son entrée standard
et en rend sur sa sortie standard. Rien d'autre.

```
~/Library/Application Support/BUD-Assistant/scripts/
└── mon-agent/
    ├── manifest.json     ce que BUD affiche et comment il l'exécute
    └── run               l'exécutable, bit +x, inscriptible par vous seul
```

## Pourquoi des processus et non des greffons

Trois raisons, dans l'ordre où elles comptent.

**Un greffon partage la mémoire de l'application.** Un script qui boucle,
qui épuise la mémoire ou qui plante emporte BUD avec lui. Un processus
séparé, on le tue.

**Un greffon impose un langage et une interface binaire.** Un processus
accepte du shell, du Python, du Swift compilé, n'importe quoi d'exécutable.

**Un sous-agent se teste seul, sans lancer BUD.** C'est ce qui rend le
système réellement extensible, bien plus que son API :

```bash
cd ~/Library/Application\ Support/BUD-Assistant/scripts/mail-actions
echo '{"contract":1,"agent":"mail-actions"}' | ./run
```

## Le contrat

Versionné par le champ `contract`. BUD refuse ce qu'il ne sait pas lire
plutôt que de l'interpréter de travers.

### `manifest.json`

```json
{
  "title":   "Actions en attente",
  "detail":  "Ce que BUD affiche sous le titre.",
  "timeout": 15,
  "every":   30,
  "contract": 1
}
```

| Champ | Rôle |
| --- | --- |
| `title` | le nom lisible |
| `detail` | une phrase, pas un paragraphe |
| `timeout` | secondes avant arrêt forcé |
| `every` | minutes entre deux exécutions automatiques ; `0` = sur demande |
| `contract` | `1` |

Le **nom du dossier** fait foi comme identifiant. Un manifeste qui s'en
écarte serait un moyen de désigner l'exécutable d'un autre agent.

### Entrée, sur `stdin`

```json
{
  "contract": 1,
  "agent": "mail-actions",
  "invokedAt": "2026-11-22T16:30:00Z",
  "support": "/Users/vous/Library/Application Support/BUD-Assistant",
  "payload": { "apply": "yes" }
}
```

`payload` est libre : c'est par lui que BUD passe les options.

### Sortie, sur `stdout`

```json
{
  "contract": 1,
  "ok": true,
  "summary": "2 actions en attente",
  "items": [
    { "title": "Paiement — Facture de novembre",
      "detail": "EDF <facture@edf.fr>",
      "level": "action",
      "open": "" }
  ],
  "error": null
}
```

`level` vaut `info`, `action` ou `warning`. `open` est un chemin ou une
adresse, facultatif.

En cas d'échec : `{"contract":1,"ok":false,"error":"ce qui n'a pas marché"}`.
Un code de sortie non nul suffit aussi — BUD reprend alors la sortie
d'erreur dans son message.

## Ce que BUD garantit

- **L'exécution ne bloque jamais l'interface.** Tout se passe hors du fil
  principal ; le résultat revient sur le fil principal.
- **Délai maximal, puis mise à mort.** `terminate` envoie SIGTERM, que
  certains scripts ignorent ; SIGKILL suit deux secondes plus tard, et
  lui ne s'ignore pas.
- **Sortie plafonnée à 256 Ko.** Un script qui écrit sans fin ne fait pas
  gonfler la mémoire de BUD.
- **Environnement réduit** : `PATH`, `HOME`, `BUD_SUPPORT`, `LANG`. Pas
  l'environnement complet de l'application.

## Ce que BUD exige

**Les entrées passent par l'entrée standard, jamais par la ligne de
commande.** Un argument se retrouve dans la table des processus, visible
de tout le système, et finit tôt ou tard interpolé dans un shell. BUD ne
passe donc aucun argument — `arguments` est toujours vide.

**Le dossier de l'agent ne doit être inscriptible que par son
propriétaire.** BUD refuse d'exécuter un dossier ouvert en écriture au
groupe ou à tous, et dit pourquoi. Ce n'est pas du zèle : un dossier
inscriptible par n'importe quoi est une élévation de privilège — qui peut
y écrire fait exécuter son code sous votre compte, par BUD.

```bash
chmod 755 ~/Library/Application\ Support/BUD-Assistant/scripts/mon-agent
chmod 755 .../mon-agent/run
```

**Le nom doit être `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`.** Tout ce qui
pourrait remonter l'arborescence est écarté avant toute autre chose.

## Les trois exemples fournis

Posés au premier lancement, **jamais réécrits ensuite** : vos
modifications survivent aux mises à jour de BUD. Les copier est la façon
la plus courte d'en écrire un quatrième.

### `mail-actions` — ce qui attend une réponse

Relit le cache que BUD écrit déjà (`inbox-cache.json`) et en extrait les
paiements, échéances, confirmations et réponses attendues. **Aucun accès
au réseau, aucun identifiant** : le travail coûteux est fait une fois par
BUD, les sous-agents le relisent.

Une décision mérite d'être connue : **un message signalé ne devient jamais
une tâche.** « Confirmez votre compte sous 24 h » dans un courriel
dangereux n'est pas une action à faire — c'est exactement le piège. Il
remonte en avertissement, pas dans la liste des choses à faire.

### `tidy-downloads` — ranger les téléchargements

Classe par type. **Par défaut il ne déplace rien** : il dit ce qu'il
ferait. Un agent qui range des fichiers dès son installation est un agent
qu'on désinstalle. Pour agir : `{"payload":{"apply":"yes"}}`, ou « applique
le rangement » dans le chat.

Jamais d'écrasement — un homonyme est numéroté. Les téléchargements en
cours (`.part`, `.download`, `.crdownload`) sont laissés tranquilles.

### `watch-local` — la veille

Espace disque, corbeille, caches, dernière sauvegarde Time Machine. Sans
réseau ni privilèges. Chaque contrôle est indépendant et protégé : un
disque absent ou une commande manquante ne fait pas échouer les autres.
Le calcul de taille d'un dossier est borné en temps — parcourir une
corbeille de cent mille fichiers ne doit pas occuper l'agent.

## Les lancer

Depuis le chat de BUD :

```
mes actions              →  mail-actions
range mes téléchargements →  tidy-downloads, en simulation
applique le rangement     →  tidy-downloads, pour de bon
veille                    →  watch-local
mes sous-agents           →  la liste de ce qui est installé
```

## Écrire le sien

```bash
mkdir -p ~/Library/Application\ Support/BUD-Assistant/scripts/mon-agent
cd ~/Library/Application\ Support/BUD-Assistant/scripts/mon-agent

cat > manifest.json <<'EOF'
{"title":"Mon agent","detail":"Ce qu'il fait.","timeout":10,"every":0,"contract":1}
EOF

cat > run <<'EOF'
#!/usr/bin/env python3
import json, sys
json.load(sys.stdin)
print(json.dumps({"contract": 1, "ok": True, "summary": "Bonjour",
                  "items": [{"title": "Première ligne", "level": "info"}]},
                 ensure_ascii=False))
EOF

chmod 755 run .
echo '{"contract":1}' | ./run      # à tester avant de passer par BUD
```

Il apparaît dans « mes sous-agents » au prochain lancement de BUD.
