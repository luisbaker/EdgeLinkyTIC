-- Tests de la logique pure du driver (src/zlinky_logic.lua).
-- Aucune dépendance : lancer depuis la racine du dépôt avec
--   lua tests/test_logique.lua
-- Ces tests vérifient des calculs sur des valeurs synthétiques ; ils ne
-- prouvent pas le comportement sur un vrai hub ni avec un vrai Linky.

package.path = "src/?.lua;" .. package.path
local logic = require "zlinky_logic"

local failures, count = 0, 0
local function check(name, got, expected)
  count = count + 1
  if got ~= expected then
    failures = failures + 1
    print(string.format("ÉCHEC %s : obtenu %s, attendu %s", name, tostring(got), tostring(expected)))
  end
end

-- decode_mode (valeurs documentées par LiXee)
local m = logic.decode_mode(0)
check("historique mono : standard", m.standard, false)
check("historique mono : tri", m.tri, false)
m = logic.decode_mode(3)
check("standard tri : standard", m.standard, true)
check("standard tri : tri", m.tri, true)
check("standard tri : production", m.production, false)
m = logic.decode_mode(7)
check("standard tri producteur", m.production, true)
check("mode hors limites", logic.decode_mode(8), nil)
check("mode absent", logic.decode_mode(nil), nil)

-- index_slots
check("aucun index", logic.index_slots(nil), 1)
check("BASE", logic.index_slots(1), 1)
check("HC/HP", logic.index_slots(2), 2)
check("3 index -> 6", logic.index_slots(3), 6)
check("Tempo", logic.index_slots(6), 6)
check("7 index -> 10", logic.index_slots(7), 10)
check("au-delà de 10", logic.index_slots(15), 10)

-- profile_name : doit correspondre aux fichiers de profiles/
check("profil par défaut", logic.profile_name(nil, 1), "zigbee-zlinky")
check("profil mono HC/HP", logic.profile_name(logic.decode_mode(0), 2), "zigbee-zlinky-idx2")
check("profil tri Tempo prod", logic.profile_name(logic.decode_mode(7), 6), "zigbee-zlinky-tri-idx6-prod")
for _, mode in ipairs({0, 1, 2, 3, 5, 7}) do
  for _, slots in ipairs(logic.INDEX_STEPS) do
    local name = logic.profile_name(logic.decode_mode(mode), slots)
    local f = io.open("profiles/" .. name .. ".yml", "r")
    check("fichier de profil " .. name, f ~= nil, true)
    if f then f:close() end
  end
end

-- subscribed_power_kva
check("ISOUSC 30 A historique", logic.subscribed_power_kva(30, logic.decode_mode(0)), 6.0)
check("PREF 6 kVA standard", logic.subscribed_power_kva(6, logic.decode_mode(1)), 6)
check("mode inconnu", logic.subscribed_power_kva(30, nil), nil)

-- is_valid_measure
check("0xFFFF invalide", logic.is_valid_measure(0xFFFF), false)
check("0 A valide", logic.is_valid_measure(0), true)
check("nil invalide", logic.is_valid_measure(nil), false)

-- total_energy_wh
check("total direct", logic.total_energy_wh(12345, { t1 = 1, t2 = 2 }), 12345)
check("somme HC/HP si total nul", logic.total_energy_wh(0, { t1 = 1000, t2 = 2500 }), 3500)
check("rien de connu", logic.total_energy_wh(0, {}), nil)
check("rien du tout", logic.total_energy_wh(nil, nil), nil)

-- consumption_report
local r = logic.consumption_report(1000, 5000, nil, nil)
check("premier rapport : delta nul", r.delta_wh, 0)
check("trop tôt", logic.consumption_report(1000 + 60, 5100, 1000, 5000), nil)
r = logic.consumption_report(1000 + 900, 5100, 1000, 5000)
check("delta après 15 min", r.delta_wh, 100)
check("début du rapport", r.start, 1000)
r = logic.consumption_report(1000 + 900, 10, 1000, 5000)
check("index en baisse : delta nul", r.delta_wh, 0)
check("énergie absente", logic.consumption_report(1000, nil, nil, nil), nil)

-- should_emit_signal
check("signal : premier message", logic.should_emit_signal(100, nil), true)
check("signal : trop tôt", logic.should_emit_signal(100 + 60, 100), false)
check("signal : après 5 min", logic.should_emit_signal(100 + 300, 100), true)

-- clean_string
check("bourrage", logic.clean_string("HC..\0\0  "), "HC..")
check("non chaîne", logic.clean_string(nil), nil)

print(string.format("%d vérifications, %d échec(s)", count, failures))
os.exit(failures == 0 and 0 or 1)
