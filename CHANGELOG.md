# Journal des modifications

## Non publié

### Corrigé
- Puissance souscrite : en mode standard, PREF est déjà en kVA (elle était divisée par 5).
- `linky-mode.presentation.json` : JSON invalide (virgules finales) ; « Unknown » remplacé par « Inconnu ».
- Les attributs en lecture seule (mode, option tarifaire, numéro de série, ISOUSC/PREF) ne sont plus configurés en rapport sans intervalle ; ils sont lus au démarrage, au rafraîchissement et toutes les heures.
- Les valeurs 0xFFFF (« non disponible » pour le ZLinky) ne sont plus affichées comme des mesures.
- Le bouton Rafraîchir relit réellement les données du module.
- En historique multi-index, l'index total est la somme des index si BASE vaut 0.

### Corrigé (audit)
- Passage depuis un autre driver : les capacités personnalisées sont déclarées, l'appareil n'est plus marqué « non fonctionnel », et les rapports sont configurés.
- SmartThings Energy : plus de faux pic de consommation quand les index d'un contrat multi-index arrivent un par un au démarrage.
- Fin de période des rapports de consommation 1 s avant le rapport, comme les drivers officiels.
- Plus d'avertissements dans les journaux pour les capacités absentes du profil.
- Surveillance d'attributs obsolète (`health_check`) désactivée.
- Une seule série de lectures au jumelage au lieu de deux.

### Affichage
- Profils séparés pour les modes historique et standard : plus de cases vides (tension, puissance en W, production).
- La consommation (kWh) est la première information affichée.
- En triphasé standard, chaque phase affiche intensité, tension et puissance.
- Composant « Linky » renommé « Compteur Linky ».

### Ajouté
- Index tarifaires (HC/HP, Tempo, EJP, EASF01 à EASF10), chacun dans son composant.
- Triphasé : intensité, tension et puissance apparente par phase.
- Mode standard : tension efficace (URMS).
- Production : énergie injectée (EAIT) et puissance injectée (SINSTI).
- Capacités standard SmartThings `currentMeasurement`, `voltageMeasurement` et `powerConsumptionReport` (SmartThings Energy), utilisables dans les automatisations.
- Choix automatique du profil selon le mode du Linky et le nombre d'index.
- Empreinte pour les firmwares qui envoient « ZLinky_TIC » suivi d'un caractère nul.
- Puissance active moyenne (CCASN, mode standard) via la capacité standard `powerMeter`.
- Qualité du signal Zigbee (LQI, RSSI) via `signalStrength`, publiée au plus toutes les 5 minutes.
- Tests de la logique pure (`tests/test_logique.lua`).
