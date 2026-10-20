#!/usr/bin/env bash
# Génère les profils SmartThings du ZLinky dans profiles/.
#
# Le driver choisit le profil à l'exécution (voir profile_name() dans
# src/zlinky_logic.lua) selon :
#   - le mode TIC    : historique ou standard (bit 0 du mode Linky) ;
#   - les phases     : monophasé ou triphasé (bit 1) ;
#   - les index      : nombre d'index tarifaires utilisés (1, 2, 6, ou 10 en standard) ;
#   - la production  : injection sur le réseau (bit 2, mode standard uniquement).
#
# Chaque profil ne contient que les capacités que le mode peut remplir, pour
# éviter les cases vides dans l'application.
#
# « zigbee-zlinky » (mode encore inconnu) garde le nom historique pour ne pas
# casser les appareils déjà installés ; il contient le jeu le plus courant.
#
# Usage (Git Bash ou Linux) : ./tools/generer-profils.sh
set -euo pipefail
cd "$(dirname "$0")/.."

cap() { echo "  - id: $1"; echo "    version: 1"; }
inst() { cap '"stormachieve25639.instantaneous"'; }

# $1 nom, $2 mode (inconnu|histo|std), $3 phases (mono|tri), $4 index, $5 production (non|oui)
profile() {
  local name=$1 mode=$2 phases=$3 index=$4 prod=$5
  {
    echo "# Fichier généré par tools/generer-profils.sh : ne pas modifier à la main."
    echo "name: $name"
    echo "components:"
    echo "- id: main"
    echo "  capabilities:"
    cap energyMeter                       # en premier : affiché sur la tuile
    [ "$mode" != histo ] && cap powerMeter
    inst
    if [ "$phases" = mono ]; then
      cap currentMeasurement
      [ "$mode" != histo ] && cap voltageMeasurement
    fi
    cap '"stormachieve25639.subscription"'
    cap powerConsumptionReport
    cap refresh
    echo "  categories:"
    echo "  - name: CurbPowerMeter"
    if [ "$phases" = tri ]; then
      for p in 1 2 3; do
        echo "- id: phase$p"
        echo "  label: \"Phase $p\""
        echo "  capabilities:"
        if [ "$mode" = histo ]; then
          # En historique, seule l'intensité par phase est disponible.
          cap currentMeasurement
        else
          inst
          cap currentMeasurement
          cap voltageMeasurement
        fi
      done
    fi
    if [ "$index" != 1 ]; then
      for i in $(seq 1 "$index"); do
        echo "- id: index$i"
        echo "  label: \"Index $i\""
        echo "  capabilities:"
        cap energyMeter
      done
    fi
    if [ "$prod" = oui ]; then
      echo "- id: production"
      echo "  label: \"Production\""
      echo "  capabilities:"
      cap energyMeter
      inst
    fi
    echo "- id: linky"
    echo "  label: \"Compteur Linky\""
    echo "  capabilities:"
    cap '"stormachieve25639.linkyMode"'
    cap '"stormachieve25639.linkySerial"'
    cap '"stormachieve25639.linkyPoweringModule"'
    cap signalStrength
  } > "profiles/$name.yml"
}

profile zigbee-zlinky inconnu mono 1 non

for phases in mono tri; do
  suffix=""; [ "$phases" = tri ] && suffix="-tri"
  for index in 1 2 6; do
    idx=""; [ "$index" != 1 ] && idx="-idx$index"
    profile "zigbee-zlinky-histo$suffix$idx" histo "$phases" "$index" non
  done
  for index in 1 2 6 10; do
    idx=""; [ "$index" != 1 ] && idx="-idx$index"
    profile "zigbee-zlinky-std$suffix$idx" std "$phases" "$index" non
    profile "zigbee-zlinky-std$suffix$idx-prod" std "$phases" "$index" oui
  done
done
echo "Profils générés dans profiles/."
