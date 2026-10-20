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
-- Le mode historique a au plus 6 index (BBR), le mode standard 10 (EASF01 à 10).
M.INDEX_STEPS_HISTO    = { 1, 2, 6 }
M.INDEX_STEPS_STANDARD = { 1, 2, 6, 10 }

function M.index_steps(mode_info)
  if mode_info ~= nil and not mode_info.standard then
    return M.INDEX_STEPS_HISTO
  end
  return M.INDEX_STEPS_STANDARD
end

-- Plus petit nombre d'index de profil couvrant l'index le plus élevé observé.
function M.index_slots(highest_index, mode_info)
  local steps = M.index_steps(mode_info)
  if type(highest_index) ~= "number" or highest_index <= 1 then
    return 1
  end
  for _, step in ipairs(steps) do
    if highest_index <= step then
      return step
    end
  end
  return steps[#steps]
end

-- Nom du profil SmartThings ; doit rester aligné avec tools/generer-profils.sh.
-- Tant que le mode est inconnu, on garde le profil par défaut « zigbee-zlinky ».
function M.profile_name(mode_info, index_slots)
  local name = "zigbee-zlinky"
  if mode_info == nil then
    return name
  end
  name = name .. (mode_info.standard and "-std" or "-histo")
  if mode_info.tri then
    name = name .. "-tri"
  end
  if index_slots and index_slots > 1 then
    name = name .. "-idx" .. index_slots
  end
  if mode_info.production then
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

-- Index total en Wh, et sa « base » de calcul.
-- En historique HC/HP (et autres tarifs multi-index), le ZLinky peut laisser
-- 0x0702/0x0000 à 0 : on prend alors la somme des index, comme zigbee2mqtt.
-- La base identifie les index additionnés : si elle change (un index de plus
-- est connu), le total fait un saut qui n'est pas une consommation.
-- Renvoie nil tant qu'aucune valeur positive n'est connue, pour ne pas
-- afficher un faux 0 kWh au démarrage.
function M.total_energy_wh(total, tiers)
  if type(total) == "number" and total > 0 then
    return total, "total"
  end
  local sum, keys = 0, {}
  for k, v in pairs(tiers or {}) do
    if type(v) == "number" then
      table.insert(keys, k)
      if v > 0 then
        sum = sum + v
      end
    end
  end
  if sum > 0 then
    table.sort(keys)
    return sum, "somme:" .. table.concat(keys, ",")
  end
  return nil, nil
end

-- SmartThings Energy : au plus un rapport toutes les 15 minutes.
M.REPORT_INTERVAL_S = 15 * 60

-- Calcule le prochain rapport powerConsumptionReport, ou nil s'il est trop tôt.
-- Le delta est nul (on repart de la valeur courante) quand :
--   - c'est le premier rapport ;
--   - la base de calcul du total a changé (voir total_energy_wh) ;
--   - l'index a baissé (compteur changé, remise à zéro).
function M.consumption_report(now, energy_wh, basis, last_time, last_energy_wh, last_basis)
  if type(energy_wh) ~= "number" then
    return nil
  end
  if last_time and now - last_time < M.REPORT_INTERVAL_S then
    return nil
  end
  local delta = 0
  if type(last_energy_wh) == "number" and basis == last_basis and energy_wh >= last_energy_wh then
    delta = energy_wh - last_energy_wh
  end
  local start = last_time or now
  return {
    start     = start,
    -- comme les drivers officiels : la période se termine 1 s avant le rapport
    finish    = math.max(start, now - 1),
    time      = now,
    delta_wh  = delta,
    energy_wh = energy_wh,
    basis     = basis,
  }
end

-- Qualité du signal Zigbee : chaque message reçu la porte, mais on ne la
-- publie qu'au plus toutes les 5 minutes pour ne pas inonder l'historique.
M.SIGNAL_INTERVAL_S = 5 * 60

function M.should_emit_signal(now, last_time)
  return last_time == nil or now - last_time >= M.SIGNAL_INTERVAL_S
end

-- Nettoie les chaînes TIC (bourrage par espaces ou caractères nuls).
function M.clean_string(s)
  if type(s) ~= "string" then
    return nil
  end
  return (s:gsub("\0", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

return M
