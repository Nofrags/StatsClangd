# clangd-diagnostics-collector

Collecte des diagnostics `clangd` depuis VS Code via l'extension **problems-as-file**, par morceaux (chunks), afin d'éviter la saturation de VS Code sur de gros workspaces.

## Prérequis

- VS Code côté serveur (Remote / WSL / SSH)
- Extension:
  - `clangd` (`llvm-vs-code-extensions.vscode-clangd`)
  - `problems-as-file` (nom variable, cherchez "problems as file")

Installation (si autorisé) :

```bash
code --install-extension llvm-vs-code-extensions.vscode-clangd
code --install-extension problems-as-file
```

## Durcissement sécurité (report_diagnostics.py)

Le script applique désormais quelques protections utiles sur des entrées non fiables :

- assainissement anti **CSV formula injection** sur les champs texte exportés
- limite de taille du fichier JSON d'entrée (100 MiB)
- option `--max-items` pour plafonner le nombre de diagnostics traités
- validation minimale des diagnostics (`source` et `message` doivent être des chaînes)
