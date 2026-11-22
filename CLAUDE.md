# NotchRAM

Widget macOS qui colle une jauge RAM à l'encoche du MacBook. Au survol, il se déplie : mémoire
utilisée / totale, pression, swap, et les 5 process les plus gourmands (bouton pour les quitter).

## Stack

- Swift 5 (mode `-swift-version 5`), AppKit + SwiftUI, un seul fichier : `main.swift` (~310 lignes).
- Aucune dépendance, pas de Package.swift ni de .xcodeproj : compilation directe avec `swiftc`.
- Cible : binaire universel (arm64 + x86_64, assemblé par `lipo`), macOS 14.0 minimum. App d'agent (`LSUIElement`, pas d'icône dans le Dock).
- Dépôt public `lepalph/notch-ram` (licence MIT, README anglais + `README.fr.md`). Pas de tests ni de lint à part `--selftest`.

## Arborescence

- `main.swift` : mesures (sysctl, `host_statistics64`, `proc_pid_rusage`), `Model`, vues SwiftUI,
  `Controller` (NSPanel sans bordure, sondage de la souris), point d'entrée et `--selftest`.
- `Info.plist` : bundle `io.github.lepalph.notchram`, version 0.1.0.
- `build.sh` : compile, signe, autotest, installe.
- `build/` : sortie du build (`build/NotchRAM.app`), régénérée à chaque `build.sh`.

## Commandes

- Build + autotest + installation : `./build.sh` (produit `build/NotchRAM.app`, copie vers
  `~/Applications/NotchRAM.app` après `rm -rf` de l'ancienne version).
- Lancer : `open ~/Applications/NotchRAM.app` ou `build/NotchRAM.app/Contents/MacOS/NotchRAM`.
- Autotest seul : `build/NotchRAM.app/Contents/MacOS/NotchRAM --selftest` (affiche les mesures, `exit(0)`).
- Mode capture QA (panneau déplié, sans minuteurs) : `... --open`.
- Aperçu du README : `... --capture docs/apercu.png` (rendu SwiftUI hors écran, sans autorisation d'enregistrement d'écran).
- Quitter : bouton « Fermer le widget » dans le panneau, ou `pkill NotchRAM`.

## Règles d'or

- Rester sans dépendance et en un seul fichier tant que ça tient ; pas de refactor non demandé.
- Signature ad hoc uniquement (`codesign --sign -`) : pas de compte développeur, pas de notarisation.
- Le noir du fond est volontaire (`Color.black`) pour se fondre dans l'encoche matérielle.
- « Mémoire utilisée » = app (internal - purgeable) + câblée + compressée, comme le Moniteur d'activité.
- Quitter un process demande deux clics (armement 3 s) et passe par `NSRunningApplication.terminate()`
  (l'app peut proposer d'enregistrer) ; `SIGTERM` seulement si ce n'est pas une app.
- Messages et textes d'interface en français.

## Pièges

- `--selftest` utilise `precondition` (pas `assert`, que `-O` retire) : ses vérifications tiennent en build optimisé.
- Sous Rosetta, la tranche x86_64 sous-estime la mémoire (pages de 4 Ko contre 16 Ko) ; sans effet réel, un Mac Apple Silicon lance la tranche arm64.
- `topProcesses` ne voit que les process lisibles sans root (les tiens) : WindowServer, kernel_task etc.
  sont absents (marqué `shortcut:` dans le code). Le process courant est exclu.
- Le survol est détecté par sondage de la souris toutes les 50 ms (fiable app inactive) ; rafraîchissement
  des mesures toutes les 2 s. Le panneau ignore la souris quand il est replié pour ne pas bloquer la barre des menus.
- Sans encoche (écran externe, capot fermé), `layout()` retombe sur une pastille centrée sous la barre des menus.
- Le niveau de pression vient de `kern.memorystatus_vm_pressure_level` : 1 normale, 2 élevée, 4 critique.
- `build.sh` échoue (`set -e`) si l'autotest plante, et dans ce cas rien n'est installé.
