# Journal des modifications

## Non publié

### Robustesse (Yeelight et capteurs sur pile)
- Yeelight : si une ampoule ne répond plus à son adresse (bail DHCP expiré), le driver relance lui-même une recherche multicast après 2 échecs de connexion, puis toutes les 5 minutes tant qu'une ampoule est hors ligne. Plus besoin de relancer « Rechercher » dans l'app.
- Yeelight : une ampoule coupée au mur passe hors ligne en ~10 s (keepalive avec délai de réponse) au lieu d'attendre 90 s sans réaction.
- Capteurs sur pile (TS0222, ZG-227Z) : lecture de la batterie (pourcentage et tension) à chaque réveil du capteur, au plus une fois par 6 h. Le TS0222 n'envoyait jamais sa batterie spontanément.
- Batterie : la tension sert de repli quand le pourcentage n'est pas fourni (3,0 V = 100 %, 2,2 V = 0 %) ; un premier « 0 % » sans tension connue est ignoré (certains Tuya répondent 0 au lieu de « inconnu »).
- Tous les fichiers Lua sont désormais vérifiés avec `luac -p` avant publication.

### Signal Zigbee sur tous les appareils
- Qualité du signal (LQI, RSSI, capacité `signalStrength`) sur tous les appareils Tuya, publiée à partir de n'importe quel message reçu, au plus toutes les 5 minutes (comme le ZLinky).
- Prise TS011F : les sections Aujourd'hui / Cette semaine / Ce mois-ci ont été retirées de la page.

### ZLinky : infos tarifaires (comme Zigbee2MQTT)
- Nouvelle capacité `smoothcommon59531.linkyInfos` (fichiers dans `capabilities/linky-infos*.json`) sur le composant `main` : période tarifaire en cours (PTEC / LTARF), index en cours (NTARF), couleur Tempo aujourd'hui et demain (DEMAIN / registre STGE), puissance max du jour (SMAXSN), intensité max (IMAX), message du fournisseur (MSG1).
- Ces attributs ne sont pas envoyés spontanément par le module : ils sont relus toutes les 5 minutes.
- Non testé sur un vrai module : correspondances reprises de Zigbee2MQTT (`src/devices/lixee.ts`).

### Fusion avec les appareils Tuya
- Le driver devient **Zigbee Luis (Tuya et ZLinky)** (`packageKey: zigbee-tuya-luis`). Le code ZLinky est désormais un sous-driver (`src/zlinky/init.lua`), activé seulement pour LiXee ZLinky_TIC. Les utilisateurs de l'ancien driver « Zigbee ZLinky » doivent basculer leur module sur ce driver.
- Prise Tuya TS011F `_TZ3210_rwmitwj4` (Nous A7Z) : énergie (kWh), tension, courant, rapports SmartThings Energy, tuile qui affiche les watts.
- Prise BSEED TS011F `_TZ3000_o1jzcxou` (sans mesure) et réglages Tuya pour toutes les TS011F : état après coupure, voyant, verrouillage enfant.
- Ruban LED RGB Tuya TS0503B `_TZ3210_wp1k8xws` : marche/arrêt, variation, couleur (non testé : appareil hors ligne).
- Version du firmware affichée pour tous les appareils Tuya, vérification de mise à jour (ImageNotify) à la configuration.
- Icônes : catégories alignées sur les drivers officiels.
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
