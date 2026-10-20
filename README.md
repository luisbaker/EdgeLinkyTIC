# Driver SmartThings Edge pour le module ZLinky TIC

Driver SmartThings Edge pour le module Zigbee [ZLinky TIC de LiXee](https://lixee.fr/), qui lit la téléinformation (TIC) d'un compteur Linky.

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

Voir le [fil de la communauté SmartThings](https://community.smartthings.com/t/st-edge-zlinky-tic/254857).

## Développement

- Spécification du module : [Zlinky_TIC](https://github.com/fairecasoimeme/Zlinky_TIC/blob/master/README.md)
- Les profils de `profiles/` sont générés : modifier `tools/generer-profils.sh` puis le relancer.
- Tests de la logique pure (sans hub) : `lua tests/test_logique.lua`
- Installation sur un hub : `smartthings edge:drivers:package .` puis `smartthings edge:drivers:install`.

Les capacités personnalisées `stormachieve25639.*` appartiennent au compte de l'auteur d'origine : les fichiers de `capabilities/` servent de référence, et leur modification n'a d'effet que si elles sont recréées dans un autre espace de noms.
