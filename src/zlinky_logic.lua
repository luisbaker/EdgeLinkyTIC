-- Logique pure du driver ZLinky (sans dépendance SmartThings) pour pouvoir
-- la tester avec un simple interpréteur Lua : voir tests/test_logique.lua.
--
-- Référence des attributs : https://github.com/fairecasoimeme/Zlinky_TIC#clusters

local M = {}

-- Attribut 0xFF66/0x0300 (mode Linky), d'après la documentation LiXee :
--   bit 0 : standard (1) / historique (0)
--   bit 1 : triphasé (1) / monophasé (0)
--   bit 2 : producteur (1) / non producteur (0), uniquement en mode standard
function M.decode_mode(mode)
  if type(mode) ~= "number" or mode < 0 or mode > 7 then
    return nil
  end
  local standard = (mode & 1) == 1
  return {
    standard   = standard,
    tri        = (mode & 2) == 2,
    production = standard and (mode & 4) == 4,
  }
end

-- Nombres d'index proposés par les profils (voir tools/generer-profils.sh).
M.INDEX_STEPS = { 1, 2, 6, 10 }

-- Plus petit nombre d'index de profil couvrant l'index le plus élevé observé.
function M.index_slots(highest_index)
  if type(highest_index) ~= "number" or highest_index <= 1 then
    return 1
  end
  for _, step in ipairs(M.INDEX_STEPS) do
    if highest_index <= step then
      return step
    end
  end
  return M.INDEX_STEPS[#M.INDEX_STEPS]
end

-- Nom du profil SmartThings ; doit rester aligné avec tools/generer-profils.sh.
function M.profile_name(mode_info, index_slots)
  local name = "zigbee-zlinky"
  if mode_info and mode_info.tri then
    name = name .. "-tri"
  end
  if index_slots and index_slots > 1 then
    name = name .. "-idx" .. index_slots
  end
  if mode_info and mode_info.production then
    name = name .. "-prod"
  end
  return name
end

-- Attribut 0x0B01/0x000D :
--   historique : ISOUSC, intensité souscrite en A ; convention Enedis 1 A = 200 VA
--                (30 A -> 6 kVA) ;
--   standard   : PREF, puissance de référence déjà en kVA.
-- Renvoie nil tant que le mode est inconnu : on ne devine pas l'unité.
function M.subscribed_power_kva(raw, mode_info)
  if type(raw) ~= "number" or mode_info == nil then
    return nil
  end
  if mode_info.standard then
    return raw
  end
  return raw * 200 / 1000
end

-- Le ZLinky renvoie 0xFFFF pour les intensités et puissances non disponibles
-- (valeur par défaut documentée) : ce n'est pas une mesure.
function M.is_valid_measure(value)
  return type(value) == "number" and value ~= 0xFFFF
end

-- Index total en Wh. En historique HC/HP (et autres tarifs multi-index), le
-- ZLinky peut laisser 0x0702/0x0000 à 0 : on prend alors la somme des index,
-- comme le fait zigbee2mqtt. Renvoie nil tant qu'aucune valeur positive n'est
-- connue, pour ne pas afficher un faux 0 kWh au démarrage.
function M.total_energy_wh(total, tiers)
  if type(total) == "number" and total > 0 then
    return total
  end
  local sum = 0
  for _, v in pairs(tiers or {}) do
    if type(v) == "number" and v > 0 then
      sum = sum + v
    end
  end
  if sum > 0 then
    return sum
  end
  return nil
end

-- SmartThings Energy : au plus un rapport toutes les 15 minutes.
M.REPORT_INTERVAL_S = 15 * 60

-- Calcule le prochain rapport powerConsumptionReport, ou nil s'il est trop tôt.
-- Une baisse d'index (compteur changé, remise à zéro) donne un delta nul plutôt
-- qu'une consommation négative.
function M.consumption_report(now, energy_wh, last_time, last_energy_wh)
  if type(energy_wh) ~= "number" then
    return nil
  end
  if last_time and now - last_time < M.REPORT_INTERVAL_S then
    return nil
  end
  local delta = 0
  if type(last_energy_wh) == "number" and energy_wh >= last_energy_wh then
    delta = energy_wh - last_energy_wh
  end
  return {
    start        = last_time or now,
    finish       = now,
    delta_wh     = delta,
    energy_wh    = energy_wh,
  }
end

-- Nettoie les chaînes TIC (bourrage par espaces ou caractères nuls).
function M.clean_string(s)
  if type(s) ~= "string" then
    return nil
  end
  return (s:gsub("\0", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

return M
