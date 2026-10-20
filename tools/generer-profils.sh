#!/usr/bin/env bash
# Génère les profils SmartThings du ZLinky dans profiles/.
#
# Le driver choisit le profil à l'exécution (voir src/profiles.lua) selon :
#   - les phases     : monophasé ou triphasé (bit 1 du mode Linky) ;
#   - les index      : nombre d'index tarifaires utilisés (1, 2, 6 ou 10) ;
#   - la production  : injection sur le réseau (bit 2 du mode Linky).
#
# Les noms produits doivent rester alignés avec profiles.name() dans src/profiles.lua.
# « zigbee-zlinky » (mono, 1 index, sans production) garde le nom historique
# pour ne pas casser les appareils déjà installés.
#
# Usage (Git Bash ou Linux) : ./tools/generer-profils.sh
set -euo pipefail
cd "$(dirname "$0")/.."

for phases in mono tri; do
  for index in 1 2 6 10; do
    for prod in non oui; do
      name="zigbee-zlinky"
      [ "$phases" = tri ] && name="$name-tri"
      [ "$index" != 1 ] && name="$name-idx$index"
      [ "$prod" = oui ] && name="$name-prod"
      f="profiles/$name.yml"
      {
        echo "# Fichier généré par tools/generer-profils.sh : ne pas modifier à la main."
        echo "name: $name"
        echo "components:"
        echo "- id: main"
        echo "  capabilities:"
        echo "  - id: refresh"
        echo "    version: 1"
        echo "  - id: energyMeter"
        echo "    version: 1"
        echo "  - id: powerConsumptionReport"
        echo "    version: 1"
        echo "  - id: powerMeter"
        echo "    version: 1"
        if [ "$phases" = mono ]; then
          echo "  - id: currentMeasurement"
          echo "    version: 1"
          echo "  - id: voltageMeasurement"
          echo "    version: 1"
        fi
        echo "  - id: \"stormachieve25639.instantaneous\""
        echo "    version: 1"
        echo "  - id: \"stormachieve25639.subscription\""
        echo "    version: 1"
        echo "  categories:"
        echo "  - name: CurbPowerMeter"
        if [ "$phases" = tri ]; then
          for p in 1 2 3; do
            echo "- id: phase$p"
            echo "  label: \"Phase $p\""
            echo "  capabilities:"
            echo "  - id: currentMeasurement"
            echo "    version: 1"
            echo "  - id: voltageMeasurement"
            echo "    version: 1"
            echo "  - id: \"stormachieve25639.instantaneous\""
            echo "    version: 1"
          done
        fi
        if [ "$index" != 1 ]; then
          for i in $(seq 1 "$index"); do
            echo "- id: index$i"
            echo "  label: \"Index $i\""
            echo "  capabilities:"
            echo "  - id: energyMeter"
            echo "    version: 1"
          done
        fi
        if [ "$prod" = oui ]; then
          echo "- id: production"
          echo "  label: \"Production\""
          echo "  capabilities:"
          echo "  - id: energyMeter"
          echo "    version: 1"
          echo "  - id: \"stormachieve25639.instantaneous\""
          echo "    version: 1"
        fi
        echo "- id: linky"
        echo "  label: \"Linky\""
        echo "  capabilities:"
        echo "  - id: \"stormachieve25639.linkyMode\""
        echo "    version: 1"
        echo "  - id: \"stormachieve25639.linkySerial\""
        echo "    version: 1"
        echo "  - id: \"stormachieve25639.linkyPoweringModule\""
        echo "    version: 1"
        echo "  - id: signalStrength"
        echo "    version: 1"
      } > "$f"
    done
  done
done
echo "Profils générés dans profiles/."
