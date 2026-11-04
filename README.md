# Zigbee Luis — driver SmartThings Edge (ZLinky TIC + Tuya)

Un seul driver SmartThings Edge, open source (Apache-2.0), pour :

| Appareil | Modèle / fabricant | Code |
|---|---|---|
| Module ZLinky TIC (compteur Linky) | LiXee `ZLinky_TIC` | `src/zlinky/` (sous-driver) |
| Prise avec mesure de conso (Nous A7Z) | Tuya `TS011F` / `_TZ3210_rwmitwj4` | `src/init.lua` |
| Capteur de luminosité | Tuya `TS0222` / `_TZ3000_hy6ncvmw` | `src/init.lua` |
| Capteur température / humidité | HOBEIAN `ZG-227Z` | `src/init.lua` |
| Prise murale sans mesure (BSEED) | Tuya `TS011F` / `_TZ3000_o1jzcxou` | `src/init.lua` |

## Appareils Tuya

- **Prise TS011F** : marche/arrêt, puissance (W), énergie (kWh), tension (V), courant (A), rapports **SmartThings Energy** toutes les 15 min. La tuile affiche les watts (présentation `presentation/plug.json`). Lecture de la prise toutes les 120 s (réglable).
- **Prises TS011F (toutes)** : réglages Tuya dans l'app : état après coupure de courant, mode du voyant, verrouillage enfant (attributs 0x8002, 0x8001, 0x8000 du cluster On/Off). Envoyés à la prise quand tu les changes.
- **BSEED TS011F `_TZ3000_o1jzcxou`** : prise sans mesure de consommation, profil marche/arrêt seul.
- **TS0222** : lit le canal Tuya 0xEF00 (DP 2 = lux, DP 4 = batterie), avec repli sur le cluster standard 0x0400. Anti-spam réglable (intervalle minimum, changement minimum en %), multiplicateur de correction.
- **ZG-227Z** : lit le canal Tuya 0xEF00 (DP 1 = température ÷10, DP 2 = humidité, DP 4 = batterie), avec repli sur les clusters standard. Corrections de température et d'humidité, intervalle d'envoi réglable (5 à 60 min, appliqué au réveil du capteur).
- Échelles et datapoints repris de [Zigbee2MQTT](https://github.com/Koenkk/zigbee-herdsman-converters).

Pour ajouter un appareil Tuya : ajoute son empreinte dans `fingerprints.yml` et, si besoin, ses datapoints dans `handle_tuya_dp` (`src/init.lua`).

## Module ZLinky TIC

Sous-driver pour le module Zigbee [ZLinky TIC de LiXee](https://lixee.fr/), qui lit la téléinformation (TIC) d'un compteur Linky.

> Ancien driver « Zigbee ZLinky » (`packageKey: zigbee-zlinky`) : après installation de ce driver, bascule le module dessus (appareil → ⋮ → Informations → Driver).

Fork maintenu de [sdalu/EdgeLinkyTIC](https://github.com/sdalu/EdgeLinkyTIC). Les contributions sont les bienvenues.

> ⚠️ **Tests en cours.** Cette version (triphasé, index tarifaires, production, capacités standard) n’a pas encore été testée sur un hub SmartThings ni avec un vrai compteur Linky. Les retours sont les bienvenus : ouvre une issue en précisant le mode du Linky (historique ou standard), le nombre de phases et ton option tarifaire.

![zlinky_tic](https://user-images.githubusercontent.com/1355524/209728509-ae196622-ae63-4290-ac8f-e47ee9a3c4b0.png)

## Données remontées

| Donnée | Mode historique | Mode standard | Composant |
|---|---|---|---|
| Index total (kWh) et `powerConsumptionReport` | BASE ou somme des index | EAST | `main` |
| Index tarifaires (HC/HP, Tempo, EJP…) | jusqu'à 6 | EASF01 à EASF10 | `index1`… |
| Intensité (A) | IINST, IINST1-3 | IRMS1-3 | `main` ou `phase1-3` |
| Tension (V) | — | URMS1-3 | `main` ou `phase1-3` |
| Puissance apparente (VA) | PAPP | SINSTS, SINSTS1-3 | `main` ou `phase1-3` |
| Puissance souscrite (kVA) | ISOUSC × 200 VA | PREF | `main` |
| Option tarifaire | OPTARIF | NGTF | `main` |
| Production : énergie injectée et puissance | — | EAIT, SINSTI | `production` |
| Puissance active moyenne (W, `powerMeter`) | — | CCASN | `main` |
| Qualité du signal Zigbee (LQI, RSSI) | ✓ | ✓ | `linky` |
| Mode, numéro de série, tension du module | ✓ | ✓ | `linky` |

Le driver lit le mode du Linky (attribut `0xFF66/0x0300`) et le nombre d'index utilisés, puis bascule automatiquement sur le profil adapté (monophasé ou triphasé, 1, 2, 6 ou 10 index, avec ou sans production).

L'onglet SmartThings Energy n'affiche que les appareils certifiés pour ce service à la demande du fabricant : le ZLinky n'y apparaîtra probablement pas, même si le driver envoie les rapports de consommation au bon format.

La puissance instantanée est une puissance **apparente** (VA). La seule puissance active (W) disponible, CCASN, est une moyenne sur la période de la courbe de charge du Linky : elle n'est pas instantanée.

## Installation

Avec la [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) :

```
smartthings edge:channels:create
smartthings edge:channels:enroll
smartthings edge:drivers:package . --channel <ID_CANAL> --hub <ID_HUB>
```

Puis bascule chaque appareil sur **Zigbee Luis (Tuya et ZLinky)** : appareil → ⋮ → Informations → Driver. Les capteurs sur batterie doivent être réveillés (appui sur leur bouton) juste après la bascule.

Fil de la communauté SmartThings pour le ZLinky : [ST Edge ZLinky TIC](https://community.smartthings.com/t/st-edge-zlinky-tic/254857).

## Développement

- Structure : `src/init.lua` (driver principal + appareils Tuya), `src/zlinky/init.lua` (sous-driver ZLinky), `src/zlinky_logic.lua` (logique pure du ZLinky, testée).
- Spécification du module : [Zlinky_TIC](https://github.com/fairecasoimeme/Zlinky_TIC/blob/master/README.md)
- Les profils `zigbee-zlinky*` de `profiles/` sont générés : modifier `tools/generer-profils.sh` puis le relancer. Les profils Tuya (`plug-power-energy`, `illuminance-battery-tuya`, `temp-humidity-battery-tuya`) sont écrits à la main.
- La tuile de la prise utilise la présentation `presentation/plug.json`. Si tu publies le driver depuis un autre compte, recrée-la avec `smartthings presentation:device-config:create -i presentation/plug.json` et remplace le `vid` dans `profiles/plug-power-energy.yml`.
- Tests de la logique pure (sans hub) : `lua tests/test_logique.lua`
- Installation sur un hub : `smartthings edge:drivers:package .` puis `smartthings edge:drivers:install`.

Les capacités personnalisées `stormachieve25639.*` appartiennent au compte de l'auteur d'origine : les fichiers de `capabilities/` servent de référence, et leur modification n'a d'effet que si elles sont recréées dans un autre espace de noms.
