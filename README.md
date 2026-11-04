# Zigbee Luis — driver SmartThings Edge (Tuya + ZLinky TIC)

Un seul driver **SmartThings Edge**, open source (Apache-2.0), pour des appareils Zigbee Tuya courants et le module **ZLinky TIC** qui lit un compteur Linky. Il tourne en local sur le hub (SmartThings Station, hubs v2/v3, Aeotec), sans cloud.

Les échelles, datapoints et attributs viennent du code open source de [Zigbee2MQTT](https://github.com/Koenkk/zigbee-herdsman-converters) et de [Home Assistant (ZHA)](https://github.com/zigpy/zha-device-handlers), comparés aux [drivers officiels SmartThings](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers).

## Sommaire

- [Appareils pris en charge](#appareils-pris-en-charge)
- [Ce que fait le driver, appareil par appareil](#ce-que-fait-le-driver-appareil-par-appareil)
- [Ce qu'on voit dans l'app SmartThings](#ce-quon-voit-dans-lapp-smartthings)
- [Module ZLinky TIC (compteur Linky)](#module-zlinky-tic-compteur-linky)
- [Installation](#installation)
- [Réglages](#réglages)
- [Limites connues](#limites-connues)
- [Dépannage](#dépannage)
- [Développement](#développement)
- [Crédits et licence](#crédits-et-licence)

## Appareils pris en charge

| Appareil | Modèle / fabricant Zigbee | État |
|---|---|---|
| Prise avec mesure de conso (Nous A7Z) | `TS011F` / `_TZ3210_rwmitwj4` | ✅ testé |
| Prise murale sans mesure (BSEED) | `TS011F` / `_TZ3000_o1jzcxou` | ✅ testé |
| Capteur de luminosité | `TS0222` / `_TZ3000_hy6ncvmw` | ✅ testé |
| Capteur température / humidité | `ZG-227Z` / `HOBEIAN` | ✅ testé |
| Ruban LED RGB | `TS0503B` / `_TZ3210_wp1k8xws` | ⚠️ non testé (appareil hors ligne) |
| Module ZLinky TIC (compteur Linky) | `ZLinky_TIC` / `LiXee` | ⚠️ non testé avec un vrai module |

« Testé » veut dire : installé sur une SmartThings Station, valeurs vérifiées dans les logs du hub et dans l'app.

**Ajouter un appareil Tuya :** ajoute son empreinte (fabricant + modèle) dans `fingerprints.yml` avec le profil adapté. S'il envoie ses mesures par le canal Tuya (cluster `0xEF00`), ajoute ses datapoints dans `handle_tuya_dp` (`src/init.lua`), en t'aidant de sa définition dans Zigbee2MQTT.

## Ce que fait le driver, appareil par appareil

Pour **tous les appareils** :
- **Signal Zigbee** (LQI et RSSI, capacité `signalStrength`), mis à jour au plus toutes les 5 min à partir de n'importe quel message reçu.
- **Version du firmware** (capacité `firmwareUpdate`). À la configuration, le driver envoie un `ImageNotify`, comme les drivers officiels. Voir [Limites connues](#limites-connues) pour les mises à jour.
- **« Magic packet » Tuya** à la configuration (lecture des attributs Basic, comme `tuya.configureMagicPacket` dans Zigbee2MQTT) : sans elle, beaucoup d'appareils Tuya n'envoient pas leurs mesures.

### Prise avec mesure — TS011F `_TZ3210_rwmitwj4`
- Marche/arrêt, **puissance (W)**, **énergie totale (kWh)**, **tension (V)**, **courant (A)**.
- Échelles reprises de Zigbee2MQTT (`TS011F_plug_1`) : courant ÷ 1000, énergie ÷ 100. Les multiplicateurs/diviseurs de tension et de puissance sont lus sur la prise.
- Rapports configurés comme Zigbee2MQTT (puissance à ±10 W, tension à ±5 V, courant à ±50 mA), plus une **lecture périodique** (120 s par défaut), car certaines TS011F ratent des rapports.
- **Rapports SmartThings Energy** (`powerConsumptionReport`) toutes les 15 min, au format des appareils Samsung : `start`, `end`, `energy` et `deltaEnergy` en Wh, `power` en W. Premier rapport 1 min après le démarrage. Voir [Limites connues](#limites-connues) pour l'onglet Energy.
- **Réglages Tuya** : état après une coupure de courant, mode du voyant, verrouillage enfant.

### Prise sans mesure — TS011F `_TZ3000_o1jzcxou` (BSEED)
- Marche/arrêt et réglages Tuya (état après coupure, voyant, verrouillage enfant).
- Zigbee2MQTT (`TS011F_plug_2`) et Home Assistant décrivent cette prise **sans mesure de consommation** : elle répond `0 W` et `0 kWh`. Le driver lui donne un profil marche/arrêt seul.
- **Détection automatique** : à chaque rafraîchissement, le driver interroge la puissance et l'énergie. Si une version de cette prise renvoie une vraie valeur (> 0), il passe tout seul sur le profil avec consommation.

Les réglages Tuya des prises sont les attributs `0x8002` (état après coupure), `0x8001` (voyant) et `0x8000` (verrouillage enfant) du cluster On/Off, comme dans Zigbee2MQTT. Ils ne sont envoyés à la prise que lorsque tu les modifies dans l'app.

### Capteur de luminosité — TS0222
- **Luminosité (lux)** et **batterie**.
- Le capteur envoie par deux canaux : le canal Tuya `0xEF00` (DP 2 = lux bruts, DP 4 = batterie) et le cluster standard `0x0400` (échelle logarithmique Zigbee). Le canal Tuya est prioritaire, et le canal standard est ignoré pendant 10 min après une mesure Tuya pour éviter les doublons.
- **Anti-spam** : le TS0222 envoie une mesure toutes les ~20 s. Le driver ne transmet une valeur que si l'intervalle minimum est écoulé ou si la variation dépasse un seuil (réglables).
- Correction par multiplicateur (réglable).

### Capteur température / humidité — ZG-227Z (HOBEIAN)
- **Température**, **humidité** et **batterie**.
- Le canal standard (`0x0402` / `0x0405`) est **toujours** pris en compte, comme le driver officiel `zigbee-humidity-sensor`. Le canal Tuya (DP 1 = température ÷ 10, DP 2 = humidité, DP 4 = batterie) s'y ajoute.
- **Chaque mesure apparaît comme une mise à jour dans l'app**, même si la valeur n'a pas changé (`state_change`). Sinon, SmartThings ne note rien et le capteur semble bloqué. Les doublons à moins de 60 s sont ignorés.
- **Intervalle d'envoi réglable** (5 à 60 min, 15 par défaut). Le capteur dort : la configuration lui est envoyée à son prochain réveil, et n'est notée comme appliquée qu'à ce moment-là.
- Corrections de température et d'humidité, et échelle ÷100 / ÷10 si un capteur envoie des valeurs 10 fois trop grandes.

### Ruban LED RGB — TS0503B
- Marche/arrêt, **variation** et **couleur**, par les clusters standard On/Off, Level et ColorControl (teinte/saturation), comme Zigbee2MQTT (`tuyaLight({color: true})`).
- Variation et couleur utilisent les gestionnaires par défaut du SDK SmartThings.

## Ce qu'on voit dans l'app SmartThings

La **catégorie** déclarée dans le profil choisit l'icône. Elle choisit aussi (comportement de l'app non documenté, constaté sur captures) une **page spéciale avec graphiques** :

| Appareil | Catégorie | Page dans l'app |
|---|---|---|
| Prise avec mesure | `PowerMeasurementSensor` | wattmètre avec **graphique 24 h**, tension avec graphique, énergie, courant |
| Prise sans mesure | `SmartPlug` | interrupteur |
| Capteur de luminosité | `LightSensor` | éclairement avec **graphique** |
| Capteur température / humidité | `TempHumiditySensor` | carte température + humidité avec **graphique jusqu'à 31 jours** |
| Ruban LED | `Light` | lumière (couleur, variation) |
| ZLinky | `CurbPowerMeter` | compteur d'énergie |

Sur ces pages, le **signal Zigbee** s'affiche en barres en haut à droite, et le **chemin de connexion** montre par quel appareil (souvent une prise) le capteur rejoint le hub.

Le SDK ne permet pas de dessiner ses propres graphiques : les [types d'affichage](https://developer.smartthings.com/docs/devices/capabilities/display-types) se limitent à des valeurs, boutons, curseurs, listes et champs. Les graphiques viennent uniquement de l'app.

La tuile de la prise avec mesure affiche les **watts** grâce à une présentation personnalisée (`presentation/plug.json`).

## Module ZLinky TIC (compteur Linky)

Sous-driver (`src/zlinky/`) pour le module Zigbee [ZLinky TIC de LiXee](https://lixee.fr/), qui lit la téléinformation (TIC) d'un compteur Linky. Il ne s'active que pour les appareils LiXee `ZLinky_TIC`.

> ⚠️ **Non testé avec un vrai module.** Les correspondances viennent de Zigbee2MQTT (`src/devices/lixee.ts`) et de la [spécification du module](https://github.com/fairecasoimeme/Zlinky_TIC/blob/master/README.md). Retours bienvenus : ouvre une issue en précisant le mode du Linky (historique ou standard), le nombre de phases et ton option tarifaire.

> Ancien driver « Zigbee ZLinky » (`packageKey: zigbee-zlinky`) : après installation de ce driver, bascule le module dessus (appareil → ⋮ → Informations → Driver).

![zlinky_tic](https://user-images.githubusercontent.com/1355524/209728509-ae196622-ae63-4290-ac8f-e47ee9a3c4b0.png)

### Données remontées

| Donnée | Mode historique | Mode standard | Composant |
|---|---|---|---|
| Index total (kWh) et `powerConsumptionReport` | BASE ou somme des index | EAST | `main` |
| Index tarifaires (HC/HP, Tempo, EJP…) | jusqu'à 6 | EASF01 à EASF10 | `index1`… |
| Consommation aujourd'hui / semaine / mois | ✓ | ✓ | `main` et chaque `indexN` (Consommation par période) |
| Intensité (A) | IINST, IINST1-3 | IRMS1-3 | `main` ou `phase1-3` |
| Tension (V) | — | URMS1-3 | `main` ou `phase1-3` |
| Puissance apparente (VA) | PAPP | SINSTS, SINSTS1-3 | `main` ou `phase1-3` |
| Puissance active moyenne (W, `powerMeter`) | — | CCASN | `main` |
| Puissance souscrite (kVA) | ISOUSC × 200 VA | PREF | `main` |
| Option tarifaire | OPTARIF | NGTF | `main` |
| Période tarifaire en cours (HP, HC, Tempo…) | PTEC | LTARF | `main` (Infos Linky) |
| Numéro d'index en cours | — | NTARF | `main` (Infos Linky) |
| Couleur Tempo aujourd'hui / demain | DEMAIN (demain) | registre STGE | `main` (Infos Linky) |
| Puissance max du jour (VA) | — | SMAXSN | `main` (Infos Linky) |
| Intensité max (A) | IMAX | — | `main` (Infos Linky) |
| Message du fournisseur | — | MSG1 | `main` (Infos Linky) |
| Production : énergie injectée et puissance | — | EAIT, SINSTI | `production` |
| Qualité du signal Zigbee (LQI, RSSI) | ✓ | ✓ | `linky` |
| Mode, numéro de série, tension du module | ✓ | ✓ | `linky` |

- Le driver lit le mode du Linky (attribut `0xFF66/0x0300`) et le nombre d'index utilisés, puis bascule automatiquement sur le profil adapté : monophasé ou triphasé, 1, 2, 6 ou 10 index, avec ou sans production (16 profils).
- Les **infos tarifaires** ne sont pas envoyées spontanément par le module : le driver les relit toutes les 5 min. La période tarifaire et la couleur Tempo de demain sont utilisables dans les automatisations (par exemple « si période = HC, lancer le lave-linge »).
- La **consommation par période** part de 0 au premier relevé, puis repart à zéro à minuit, le lundi et le 1er du mois (heure locale = UTC + réglage « Décalage horaire »).
- La puissance instantanée est une puissance **apparente** (VA). La seule puissance active (W), CCASN, est une moyenne sur la période de la courbe de charge : elle n'est pas instantanée. Le Linky ne fournit ni puissance active instantanée ni fréquence du réseau.

Pour des graphiques de consommation du Linky, l'espace client **Enedis** (courbe de charge au pas de 30 min, à activer) et l'app de ton fournisseur sont gratuits.

## Installation

Avec la [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) (vérifie que le fichier téléchargé vient bien des *Releases* officielles) :

```
smartthings edge:channels:create
smartthings edge:channels:enroll
smartthings edge:drivers:package . --channel <ID_CANAL> --hub <ID_HUB>
```

`package` avec `--channel` et `--hub` envoie le driver, l'assigne au canal et l'installe sur le hub en une seule commande.

Puis bascule chaque appareil sur **Zigbee Luis (Tuya et ZLinky)** : appareil → ⋮ → Informations → Driver, ou `smartthings edge:drivers:switch`. Les **capteurs sur batterie** doivent être réveillés (appui sur leur bouton) juste après la bascule.

Pour mettre à jour : relance la commande `package`. Les appareils restent sur le driver et passent à la nouvelle version.

## Réglages

Dans l'app : appareil → ⋮ → Paramètres.

| Appareil | Réglages |
|---|---|
| Prise avec mesure | lecture de la conso (10–3600 s), état après coupure, voyant, verrouillage enfant |
| Prise sans mesure | état après coupure, voyant, verrouillage enfant |
| Capteur de luminosité | mode de conversion (standard Zigbee / brut), multiplicateur, intervalle minimum, changement minimum (%) |
| Capteur température / humidité | intervalle d'envoi (5–60 min), correction de température, correction d'humidité, échelles ÷100 / ÷10 |
| ZLinky | décalage horaire (pour couper les journées à minuit) |

## Limites connues

- **Onglet SmartThings Energy** : il est réservé aux appareils **certifiés** par SmartThings. L'équipe SmartThings le confirme sur [le forum](https://community.smartthings.com/t/reporting-consumption-to-smartthings-energy-and-possible-issues/302473). La prise envoie des rapports au bon format, mais elle n'y apparaît pas. La consommation reste visible sur la page de l'appareil.
- **Mises à jour de firmware** : la Station ne propose que les firmwares déposés chez Samsung par les fabricants. Aucun firmware Tuya ni BSEED n'est publié, ni chez Samsung ni dans [l'index OTA de Zigbee2MQTT](https://github.com/Koenkk/zigbee-OTA). Le firmware du ZLinky (v17) existe, mais il s'installe avec les outils LiXee ou Zigbee2MQTT, pas par SmartThings.
- **Capteurs sur batterie** : ils dorment entre deux envois. Une commande (rafraîchir, configurer) envoyée pendant leur sommeil est perdue : il faut attendre leur prochain envoi ou appuyer sur leur bouton.
- **Prise BSEED** : pas de mesure de consommation (matériel).

## Dépannage

Voir les logs du driver en direct (le PC doit être sur le même réseau que le hub) :

```
smartthings edge:drivers:logcat <ID_DRIVER> --hub-address <IP_DU_HUB>
```

| Symptôme | Cause probable | Solution |
|---|---|---|
| Le capteur semble ne plus envoyer | il dort, ou la valeur n'a pas changé | attendre son envoi ou appuyer sur son bouton ; regarder les logs |
| La page n'affiche pas les dernières modifications | l'app garde l'ancienne page en cache | fermer complètement l'app, ou vider son cache (pas ses données) |
| La prise n'apparaît pas dans l'onglet Energy | appareil non certifié | normal, voir [Limites connues](#limites-connues) |
| Un réglage de capteur ne s'applique pas | le capteur dormait | il s'applique à son prochain réveil |
| Valeurs 10 fois trop grandes ou trop petites | échelle différente selon le firmware | changer l'échelle ÷100 / ÷10 dans les réglages |

## Développement

### Structure

```
config.yml                      nom du driver, packageKey (zigbee-tuya-luis)
fingerprints.yml                empreintes : quel appareil utilise quel profil
profiles/                       profils (capacités, catégories, réglages)
  plug-power-energy.yml           prise avec mesure
  plug-tuya-basic.yml             prise sans mesure
  illuminance-battery-tuya.yml    capteur de luminosité
  temp-humidity-battery-tuya.yml  capteur température / humidité
  rgb-light-tuya.yml              ruban LED
  zigbee-zlinky*.yml              ZLinky (16 profils générés)
presentation/plug.json          page personnalisée de la prise (tuile en watts)
capabilities/                   capacités personnalisées et leur affichage
src/init.lua                    driver principal + appareils Tuya
src/zlinky/init.lua             sous-driver ZLinky
src/zlinky_logic.lua            logique pure du ZLinky (testée sans hub)
tests/test_logique.lua          tests de la logique ZLinky
tools/generer-profils.sh        génère les 16 profils ZLinky
```

### Capacités personnalisées

| Capacité | Rôle |
|---|---|
| `smoothcommon59531.linkyInfos` | période tarifaire, index en cours, couleurs Tempo, puissance et intensité max, message (ZLinky) |
| `smoothcommon59531.periodEnergy` | consommation aujourd'hui / semaine / mois (ZLinky) |
| `stormachieve25639.*` | capacités historiques du ZLinky, compte de l'auteur d'origine (référence seulement) |

Les fichiers de `capabilities/` décrivent ces capacités. Si tu publies le driver depuis un autre compte, recrée-les dans ton espace de noms (`smartthings capabilities:create` puis `capabilities:presentation:create`), et remplace l'identifiant dans le code et les profils.

### Présentation de la prise

La page de la prise avec mesure utilise `presentation/plug.json`. Depuis un autre compte, recrée-la avec `smartthings presentation:device-config:create -i presentation/plug.json` et remplace le `vid` dans `profiles/plug-power-energy.yml`.

### Profils ZLinky

Les profils `zigbee-zlinky*` sont générés : modifie `tools/generer-profils.sh`, puis relance-le. Les profils Tuya sont écrits à la main.

### Tests

- Logique pure du ZLinky (sans hub) : `lua tests/test_logique.lua`
- Le reste se teste sur un hub, avec `logcat`.

## Crédits et licence

- Sous-driver ZLinky basé sur [sdalu/EdgeLinkyTIC](https://github.com/sdalu/EdgeLinkyTIC).
- Échelles, datapoints et attributs : [Zigbee2MQTT](https://github.com/Koenkk/zigbee-herdsman-converters), [Home Assistant ZHA](https://github.com/zigpy/zha-device-handlers), [drivers officiels SmartThings](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers).
- Licence : [Apache-2.0](LICENSE).

Le fil de la communauté SmartThings pour le ZLinky : [ST Edge ZLinky TIC](https://community.smartthings.com/t/st-edge-zlinky-tic/254857).
