# Journal des modifications

## Non publié

### Fusion avec les appareils Tuya
- Le driver devient **Zigbee Luis (Tuya et ZLinky)** (`packageKey: zigbee-tuya-luis`). Le code ZLinky est désormais un sous-driver (`src/zlinky/init.lua`), activé seulement pour LiXee ZLinky_TIC. Les utilisateurs de l'ancien driver « Zigbee ZLinky » doivent basculer leur module sur ce driver.
- Prise Tuya TS011F `_TZ3210_rwmitwj4` (Nous A7Z) : énergie (kWh), tension, courant, rapports SmartThings Energy, tuile qui affiche les watts.
- Prise BSEED TS011F `_TZ3000_o1jzcxou` (sans mesure) et réglages Tuya pour toutes les TS011F : état après coupure, voyant, verrouillage enfant.
- Ruban LED RGB Tuya TS0503B `_TZ3210_wp1k8xws` : marche/arrêt, variation, couleur (non testé : appareil hors ligne).
- Capteur de luminosité Tuya TS0222 `_TZ3000_hy6ncvmw` : lecture du canal Tuya (lux et batterie), anti-spam réglable.
- Capteur température/humidité HOBEIAN ZG-227Z : lecture du canal Tuya (DP 1/2/4), corrections, intervalle d'envoi réglable.
- Échelles et datapoints repris de Zigbee2MQTT (`zigbee-herdsman-converters`).

### Corrigé
- Puissance souscrite : en mode standard, PREF est déjà en kVA (elle était divisée par 5).
- `linky-mode.presentation.json` : JSON invalide (virgules finales) ; « Unknown » remplacé par « Inconnu ».
- Les attributs en lecture seule (mode, option tarifaire, numéro de série, ISOUSC/PREF) ne sont plus configurés en rapport sans intervalle ; ils sont lus au démarrage, au rafraîchissement et toutes les heures.
- Les valeurs 0xFFFF (« non disponible » pour le ZLinky) ne sont plus affichées comme des mesures.
- Le bouton Rafraîchir relit réellement les données du module.
- En historique multi-index, l'index total est la somme des index si BASE vaut 0.

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
