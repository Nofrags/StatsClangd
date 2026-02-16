# clangd-diagnostics-collector

Collecte des diagnostics `clangd` depuis VS Code via l'extension **problems-as-file**, par morceaux (chunks), afin d'éviter la saturation de VS Code sur de gros workspaces.

## Contenu du dépôt

- `scripts/collect_clangd_diagnostics.sh` : collecte en 2 passes par chunk (`srclib` puis `include`) et fusion des exports.
- `scripts/report_diagnostics.py` : génération de rapports CSV (simple + détaillé) à partir d'un JSON fusionné.
- `tests/test_report_diagnostics.py` : tests unitaires du reporting Python.

## Prérequis

- VS Code côté serveur (Remote / WSL / SSH)
- Extensions:
  - `clangd` (`llvm-vs-code-extensions.vscode-clangd`)
  - `problems-as-file` (nom variable, cherchez *problems as file*)

Installation (si autorisé):

```bash
code --install-extension llvm-vs-code-extensions.vscode-clangd
code --install-extension problems-as-file
```

## Collecte des diagnostics

Le script de collecte:

- vérifie `compile_commands.json` (sauf `--no-compile-db-check`),
- impose une structure complète des chunks avant lancement,
- exécute 2 passes par chunk (`srclib` puis `include`),
- affiche une trace batch par batch avec le nombre de fichiers restants à ouvrir,
- fusionne les passes par chunk puis fusionne tous les chunks,
- restaure la configuration `problems-as-file` à la fin (même en cas d'interruption).

### Validation bloquante de structure

Le lancement est **bloqué** si un des répertoires requis est absent:

- `sou/<chunk>`
- `sou/<chunk>/<rel-srclib>` (par défaut `srclib`)
- `sou/<chunk>/<rel-include>` (par défaut `include`)

## Reporting CSV

`report_diagnostics.py` produit:

- un CSV simple: `file;count`
- un CSV détaillé: `file;line;column;code;source;message`

### Durcissement sécurité

Le script applique des protections pour entrées non fiables:

- assainissement anti **CSV formula injection** (`=`, `+`, `-`, `@`)
- limite de taille du JSON d'entrée (100 MiB)
- validation minimale des diagnostics (`source` et `message` doivent être des chaînes)
- option `--max-items` pour plafonner le nombre de diagnostics traités

## Tests

```bash
python3 -m py_compile scripts/report_diagnostics.py
bash -n scripts/collect_clangd_diagnostics.sh
python3 -m unittest -v tests/test_report_diagnostics.py
```
