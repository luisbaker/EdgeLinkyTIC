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

local HISTO_MONO, STD_MONO, HISTO_TRI, STD_TRI, STD_MONO_PROD, STD_TRI_PROD = 0, 1, 2, 3, 5, 7

-- decode_mode (valeurs documentées par LiXee)
local m = logic.decode_mode(HISTO_MONO)
check("historique mono : standard", m.standard, false)
check("historique mono : tri", m.tri, false)
check("historique mono : production", m.production, false)
m = logic.decode_mode(STD_TRI)
check("standard tri : standard", m.standard, true)
check("standard tri : tri", m.tri, true)
check("standard tri : production", m.production, false)
check("standard tri producteur", logic.decode_mode(STD_TRI_PROD).production, true)
check("bit production ignoré en historique", logic.decode_mode(4).production, false)
check("mode hors limites", logic.decode_mode(8), nil)
check("mode négatif", logic.decode_mode(-1), nil)
check("mode absent", logic.decode_mode(nil), nil)

-- index_slots
local std, histo = logic.decode_mode(STD_MONO), logic.decode_mode(HISTO_MONO)
check("aucun index", logic.index_slots(nil, std), 1)
check("BASE", logic.index_slots(1, std), 1)
check("HC/HP", logic.index_slots(2, std), 2)
check("3 index -> 6", logic.index_slots(3, std), 6)
check("Tempo", logic.index_slots(6, std), 6)
check("7 index -> 10 en standard", logic.index_slots(7, std), 10)
check("au-delà de 10", logic.index_slots(15, std), 10)
check("historique plafonné à 6", logic.index_slots(7, histo), 6)
check("mode inconnu : paliers standard", logic.index_slots(7, nil), 10)

-- profile_name : doit correspondre aux fichiers de profiles/
check("profil mode inconnu", logic.profile_name(nil, 2), "zigbee-zlinky")
check("profil historique HC/HP", logic.profile_name(histo, 2), "zigbee-zlinky-histo-idx2")
check("profil standard tri Tempo prod", logic.profile_name(logic.decode_mode(STD_TRI_PROD), 6), "zigbee-zlinky-std-tri-idx6-prod")
local function profile_exists(name)
  local f = io.open("profiles/" .. name .. ".yml", "r")
  if f then f:close() end
  return f ~= nil
end
check("fichier du profil par défaut", profile_exists("zigbee-zlinky"), true)
for _, mode in ipairs({ HISTO_MONO, STD_MONO, HISTO_TRI, STD_TRI, STD_MONO_PROD, STD_TRI_PROD }) do
  local info = logic.decode_mode(mode)
  for _, slots in ipairs(logic.index_steps(info)) do
    local name = logic.profile_name(info, slots)
    check("fichier de profil " .. name, profile_exists(name), true)
  end
end

-- subscribed_power_kva
check("ISOUSC 30 A historique", logic.subscribed_power_kva(30, histo), 6.0)
check("PREF 6 kVA standard", logic.subscribed_power_kva(6, std), 6)
check("mode inconnu", logic.subscribed_power_kva(30, nil), nil)
check("valeur absente", logic.subscribed_power_kva(nil, std), nil)

-- is_valid_measure
check("0xFFFF invalide", logic.is_valid_measure(0xFFFF), false)
check("0 A valide", logic.is_valid_measure(0), true)
check("nil invalide", logic.is_valid_measure(nil), false)

-- total_energy_wh
local e, b = logic.total_energy_wh(12345, { t1 = 1, t2 = 2 })
check("total direct", e, 12345)
check("base total", b, "total")
e, b = logic.total_energy_wh(0, { t1 = 1000, t2 = 2500 })
check("somme HC/HP si total nul", e, 3500)
check("base somme", b, "somme:t1,t2")
e, b = logic.total_energy_wh(0, { t1 = 1000, t2 = 0 })
check("index à 0 compté dans la base", b, "somme:t1,t2")
check("rien de connu", logic.total_energy_wh(0, {}), nil)
check("rien du tout", logic.total_energy_wh(nil, nil), nil)

-- consumption_report
local r = logic.consumption_report(1000, 5000, "total", nil, nil, nil)
check("premier rapport : delta nul", r.delta_wh, 0)
check("premier rapport : fin >= début", r.finish >= r.start, true)
check("trop tôt", logic.consumption_report(1000 + 60, 5100, "total", 1000, 5000, "total"), nil)
r = logic.consumption_report(1000 + 900, 5100, "total", 1000, 5000, "total")
check("delta après 15 min", r.delta_wh, 100)
check("début du rapport", r.start, 1000)
check("fin 1 s avant le rapport", r.finish, 1000 + 899)
check("heure du rapport", r.time, 1000 + 900)
r = logic.consumption_report(1000 + 900, 10, "total", 1000, 5000, "total")
check("index en baisse : delta nul", r.delta_wh, 0)
-- Régression : en historique HC/HP, les index arrivent un par un au démarrage.
-- Le passage de « HC seul » à « HC + HP » n'est pas une consommation.
r = logic.consumption_report(1000 + 900, 3500, "somme:t1,t2", 1000, 1000, "somme:t1")
check("changement de base : delta nul", r.delta_wh, 0)
check("changement de base : nouvelle base retenue", r.basis, "somme:t1,t2")
check("énergie absente", logic.consumption_report(1000, nil, nil, nil, nil, nil), nil)

-- should_emit_signal
check("signal : premier message", logic.should_emit_signal(100, nil), true)
check("signal : trop tôt", logic.should_emit_signal(100 + 60, 100), false)
check("signal : après 5 min", logic.should_emit_signal(100 + 300, 100), true)

-- clean_string
check("bourrage", logic.clean_string("HC..\0\0  "), "HC..")
check("non chaîne", logic.clean_string(nil), nil)

print(string.format("%d vérifications, %d échec(s)", count, failures))
os.exit(failures == 0 and 0 or 1)
