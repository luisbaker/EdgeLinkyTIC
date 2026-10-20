-- SmartThings Edge driver pour le module ZLinky TIC de LiXee.
--
-- Référence des attributs :
--   https://github.com/fairecasoimeme/Zlinky_TIC#clusters
-- ZCL :
--   https://zigbeealliance.org/wp-content/uploads/2019/12/07-5123-06-zigbee-cluster-library-specification.pdf

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local clusters     = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local data_types   = require "st.zigbee.data_types"
local log          = require "log"

local logic        = require "zlinky_logic"

local c_linkyPoweringModule = capabilities["stormachieve25639.linkyPoweringModule"]
local c_linkyMode           = capabilities["stormachieve25639.linkyMode"]
local c_linkySerial         = capabilities["stormachieve25639.linkySerial"]
local c_subscription        = capabilities["stormachieve25639.subscription"]
local c_instantaneous       = capabilities["stormachieve25639.instantaneous"]

local CLUSTER_METERING    = clusters.SimpleMetering.ID          -- 0x0702
local CLUSTER_METER_ID    = 0x0B01                              -- Meter Identification
local CLUSTER_ELECTRICAL  = clusters.ElectricalMeasurement.ID   -- 0x0B04
local CLUSTER_LIXEE       = 0xFF66                              -- LiXee privé
local CLUSTER_POWER_CFG   = clusters.PowerConfiguration.ID      -- 0x0001
local ATTR_MAINS_VOLTAGE  = clusters.PowerConfiguration.attributes.MainsVoltage

-- Index tarifaires : 0x0702 / 0x0100, 0x0102, … 0x0112 (index 1 à 10).
local TIER_COUNT = 10
local function tier_attribute(i) return 0x0100 + 2 * (i - 1) end

-- Champs persistants
local F_MODE          = "linky_mode"          -- valeur brute de 0xFF66/0x0300
local F_HIGHEST_INDEX = "highest_index"       -- plus haut index tarifaire non nul vu
local F_PROFILE       = "profile_name"        -- dernier profil demandé
local F_CONFIGURED    = "configured_for"      -- profil pour lequel les rapports sont configurés
local F_RAW_POWER     = "subscribed_raw"      -- ISOUSC/PREF brut
local F_TOTAL         = "total_wh"
local F_TIERS         = "tiers_wh"            -- clés "t1"…"t10" (sérialisation JSON stable)
local F_REPORT_T      = "report_time"
local F_REPORT_E      = "report_energy_wh"

local POLL_INTERVAL_S = 3600   -- attributs en lecture seule (mode, tarif, abonnement…)
local READ_SPACING_S  = 1      -- le ZLinky est alimenté par le Linky : on espace les lectures

local PERSIST = { persist = true }

------------------------------------------------------------------------------
-- Outils
------------------------------------------------------------------------------

local function mode_info(device)
  return logic.decode_mode(device:get_field(F_MODE))
end

local function emit_to(device, component_id, event)
  local component = device.profile.components[component_id]
  if component == nil then
    -- Le profil n'a pas (encore) ce composant, par ex. avant la détection du triphasé.
    log.debug(string.format("[%s] composant %s absent du profil, événement ignoré", device.id, component_id))
    return
  end
  device:emit_component_event(component, event)
end

-- Composant recevant les mesures d'une phase : « phaseN » en triphasé,
-- « main » pour la phase 1 en monophasé.
local function phase_component(device, phase)
  if device.profile.components["phase" .. phase] ~= nil then
    return "phase" .. phase
  end
  if phase == 1 then
    return "main"
  end
  return nil
end

local function iso8601(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

local function read(device, cluster, attribute)
  device:send(cluster_base.read_attribute(device,
                                          data_types.ClusterId(cluster),
                                          data_types.AttributeId(attribute)))
end

-- Lectures espacées pour ne pas saturer le module.
local function read_spaced(device, list)
  for i, item in ipairs(list) do
    device.thread:call_with_delay((i - 1) * READ_SPACING_S, function()
      read(device, item[1], item[2])
    end)
  end
end

local READ_ONLY_ATTRIBUTES = {
  { CLUSTER_LIXEE,    0x0300 },  -- mode Linky
  { CLUSTER_LIXEE,    0x0000 },  -- OPTARIF / NGTF
  { CLUSTER_METERING, 0x0308 },  -- ADCO / ADSC
  { CLUSTER_METER_ID, 0x000D },  -- ISOUSC / PREF
}

local function read_all(device)
  local list = {}
  for _, a in ipairs(READ_ONLY_ATTRIBUTES) do table.insert(list, a) end
  table.insert(list, { CLUSTER_POWER_CFG, ATTR_MAINS_VOLTAGE.ID })
  table.insert(list, { CLUSTER_METERING, 0x0000 })
  -- Tous les index sont lus pour détecter combien le contrat en utilise.
  for i = 1, TIER_COUNT do table.insert(list, { CLUSTER_METERING, tier_attribute(i) }) end
  table.insert(list, { CLUSTER_ELECTRICAL, 0x0508 })
  table.insert(list, { CLUSTER_ELECTRICAL, 0x050F })
  local info = mode_info(device)
  if info and info.standard then
    table.insert(list, { CLUSTER_ELECTRICAL, 0x0505 })
  end
  if info and info.tri then
    table.insert(list, { CLUSTER_ELECTRICAL, 0x0908 })
    table.insert(list, { CLUSTER_ELECTRICAL, 0x0A08 })
  end
  if info and info.production then
    table.insert(list, { CLUSTER_METERING, 0x0001 })
    table.insert(list, { CLUSTER_LIXEE, 0x0207 })
  end
  read_spaced(device, list)
end

------------------------------------------------------------------------------
-- Rapports configurés selon le mode du compteur
------------------------------------------------------------------------------

local function reportable(cluster, attribute, data_type, min, max, change)
  return {
    cluster           = cluster,
    attribute         = attribute,
    data_type         = data_type,
    minimum_interval  = min,
    maximum_interval  = max,
    reportable_change = change,
  }
end

-- Intervalles : 30 s / 60 s pour les mesures déjà présentes dans les versions
-- précédentes du driver (comportement conservé), 60 s / 900 s pour les nouvelles
-- (valeurs reprises de zigbee2mqtt, pour ménager l'alimentation du module).
-- Les attributs en lecture seule (mode, tarif, série, ISOUSC/PREF) ne sont
-- plus configurés en rapport : ils sont lus périodiquement (voir poll).
local function reportable_attributes(info, index_slots)
  local list = {
    reportable(CLUSTER_POWER_CFG, ATTR_MAINS_VOLTAGE.ID, ATTR_MAINS_VOLTAGE.base_type, 30, 21600, 1),
    reportable(CLUSTER_METERING, 0x0000, data_types.Uint48, 30, 60, 1),
    reportable(CLUSTER_ELECTRICAL, 0x0508, data_types.Uint16, 30, 60, 1),
    reportable(CLUSTER_ELECTRICAL, 0x050F, data_types.Uint16, 30, 60, 1),
  }
  for i = 1, (index_slots or 1) do
    table.insert(list, reportable(CLUSTER_METERING, tier_attribute(i), data_types.Uint48, 60, 900, 1))
  end
  if info == nil then
    return list
  end
  if info.tri then
    table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x0908, data_types.Uint16, 30, 60, 1))
    table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x0A08, data_types.Uint16, 30, 60, 1))
  end
  if info.standard then
    table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x0505, data_types.Uint16, 60, 900, 1))
    if info.tri then
      table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x0905, data_types.Uint16, 60, 900, 1))
      table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x0A05, data_types.Uint16, 60, 900, 1))
      table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x090F, data_types.Uint16, 30, 60, 1))
      table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x0A0F, data_types.Uint16, 30, 60, 1))
      -- SINSTS total en triphasé. Type à confirmer sur un vrai module (cf. changelog v0016).
      table.insert(list, reportable(CLUSTER_ELECTRICAL, 0x0306, data_types.Uint16, 30, 60, 1))
    end
  end
  if info.production then
    table.insert(list, reportable(CLUSTER_METERING, 0x0001, data_types.Uint48, 60, 900, 1))
    table.insert(list, reportable(CLUSTER_LIXEE, 0x0207, data_types.Uint16, 30, 60, 1))
  end
  return list
end

-- Enregistre les rapports attendus et renvoie le nom du profil correspondant.
local function register_reporting(device)
  local info = mode_info(device)
  local slots = logic.index_slots(device:get_field(F_HIGHEST_INDEX))
  for _, config in ipairs(reportable_attributes(info, slots)) do
    device:add_configured_attribute(config)
    device:add_monitored_attribute(config)
  end
  return logic.profile_name(info, slots)
end

-- Applique le profil adapté au compteur et (re)configure les rapports si besoin.
local function update_profile(device)
  local wanted = register_reporting(device)
  if device:get_field(F_PROFILE) ~= wanted then
    log.info(string.format("[%s] profil %s", device.id, wanted))
    device:try_update_metadata({ profile = wanted })
    device:set_field(F_PROFILE, wanted, PERSIST)
  end
  if device:get_field(F_CONFIGURED) ~= wanted then
    device:configure()
    device:set_field(F_CONFIGURED, wanted, PERSIST)
  end
end

------------------------------------------------------------------------------
-- Énergie
------------------------------------------------------------------------------

local function report_consumption(device, energy_wh)
  local report = logic.consumption_report(os.time(), energy_wh,
                                          device:get_field(F_REPORT_T),
                                          device:get_field(F_REPORT_E))
  if report == nil then
    return
  end
  emit_to(device, "main", capabilities.powerConsumptionReport.powerConsumption({
    start       = iso8601(report.start),
    ["end"]     = iso8601(report.finish),
    deltaEnergy = report.delta_wh,
    energy      = report.energy_wh,
  }))
  device:set_field(F_REPORT_T, report.finish, PERSIST)
  device:set_field(F_REPORT_E, report.energy_wh, PERSIST)
end

local function emit_total_energy(device)
  local energy_wh = logic.total_energy_wh(device:get_field(F_TOTAL), device:get_field(F_TIERS))
  if energy_wh == nil then
    return
  end
  emit_to(device, "main", capabilities.energyMeter.energy({ value = energy_wh / 1000, unit = "kWh" }))
  report_consumption(device, energy_wh)
end

local function total_handler(driver, device, value, zb_rx)
  device:set_field(F_TOTAL, value.value, PERSIST)
  emit_total_energy(device)
end

local function tier_handler(index)
  return function(driver, device, value, zb_rx)
    local tiers = device:get_field(F_TIERS) or {}
    tiers["t" .. index] = value.value
    device:set_field(F_TIERS, tiers, PERSIST)

    emit_to(device, "index" .. index, capabilities.energyMeter.energy({ value = value.value / 1000, unit = "kWh" }))

    if value.value > 0 and index > (device:get_field(F_HIGHEST_INDEX) or 0) then
      device:set_field(F_HIGHEST_INDEX, index, PERSIST)
      if device:get_field(F_MODE) ~= nil then
        update_profile(device)
      end
    end

    local total = device:get_field(F_TOTAL)
    if total == nil or total == 0 then
      emit_total_energy(device)
    end
  end
end

local function injected_energy_handler(driver, device, value, zb_rx)
  emit_to(device, "production", capabilities.energyMeter.energy({ value = value.value / 1000, unit = "kWh" }))
end

------------------------------------------------------------------------------
-- Mesures instantanées
------------------------------------------------------------------------------

local function current_handler(phase)
  return function(driver, device, value, zb_rx)
    if not logic.is_valid_measure(value.value) then return end
    local component = phase_component(device, phase)
    if component == nil then return end
    emit_to(device, component, capabilities.currentMeasurement.current({ value = value.value, unit = "A" }))
    -- Compatibilité : la capacité Instantaneous reste alimentée sur « main ».
    if component == "main" then
      emit_to(device, "main", c_instantaneous.current({ value = value.value, unit = "A" }))
    end
  end
end

-- URMS1..3 : mode standard uniquement.
local function voltage_handler(phase)
  return function(driver, device, value, zb_rx)
    if not logic.is_valid_measure(value.value) then return end
    local component = phase_component(device, phase)
    if component == nil then return end
    emit_to(device, component, capabilities.voltageMeasurement.voltage({ value = value.value, unit = "V" }))
    if component == "main" then
      emit_to(device, "main", c_instantaneous.voltage({ value = value.value, unit = "V" }))
    end
  end
end

-- 0x050F : PAPP (historique, total) / SINSTS (standard monophasé) / SINSTS1 (standard triphasé).
local function apparent_power_050F(driver, device, value, zb_rx)
  if not logic.is_valid_measure(value.value) then return end
  local info = mode_info(device)
  local component = "main"
  if info and info.standard and info.tri then
    component = "phase1"
  end
  emit_to(device, component, c_instantaneous.power({ value = value.value, unit = "VA" }))
end

local function apparent_power_phase(phase)
  return function(driver, device, value, zb_rx)
    if not logic.is_valid_measure(value.value) then return end
    emit_to(device, "phase" .. phase, c_instantaneous.power({ value = value.value, unit = "VA" }))
  end
end

-- 0x0306 : SINSTS, puissance apparente totale. Utilisée seulement en triphasé
-- standard : en monophasé, 0x050F donne déjà la même valeur.
local function total_apparent_power(driver, device, value, zb_rx)
  if not logic.is_valid_measure(value.value) then return end
  local info = mode_info(device)
  if info and info.standard and info.tri then
    emit_to(device, "main", c_instantaneous.power({ value = value.value, unit = "VA" }))
  end
end

local function injected_power_handler(driver, device, value, zb_rx)
  if not logic.is_valid_measure(value.value) then return end
  emit_to(device, "production", c_instantaneous.power({ value = value.value, unit = "VA" }))
end

------------------------------------------------------------------------------
-- Informations du compteur
------------------------------------------------------------------------------

local function emit_subscription_power(device)
  local kva = logic.subscribed_power_kva(device:get_field(F_RAW_POWER), mode_info(device))
  if kva ~= nil then
    emit_to(device, "main", c_subscription.power({ value = kva, unit = "kVA" }))
  end
end

local function mode_handler(driver, device, value, zb_rx)
  if logic.decode_mode(value.value) == nil then
    log.warn(string.format("[%s] mode Linky inattendu : %s", device.id, tostring(value.value)))
    return
  end
  emit_to(device, "linky", c_linkyMode.mode({ value = value.value }))
  local changed = device:get_field(F_MODE) ~= value.value
  device:set_field(F_MODE, value.value, PERSIST)
  if changed then
    emit_subscription_power(device)
  end
  update_profile(device)
end

local function serial_handler(driver, device, value, zb_rx)
  local serial = logic.clean_string(value.value)
  if serial then
    emit_to(device, "linky", c_linkySerial.serial({ value = serial }))
  end
end

local function tariff_handler(driver, device, value, zb_rx)
  local tariff = logic.clean_string(value.value)
  if tariff then
    emit_to(device, "main", c_subscription.mode({ value = tariff }))
  end
end

local function subscribed_power_handler(driver, device, value, zb_rx)
  device:set_field(F_RAW_POWER, value.value, PERSIST)
  emit_subscription_power(device)
end

-- Tension d'alimentation du module (et non du réseau), en mV d'après les
-- seuils documentés par LiXee (2600 / 3600).
local function module_voltage_handler(driver, device, value, zb_rx)
  emit_to(device, "linky", c_linkyPoweringModule.voltage({ value = value.value, unit = "mV" }))
end

------------------------------------------------------------------------------
-- Cycle de vie
------------------------------------------------------------------------------

local function poll(device)
  read_spaced(device, READ_ONLY_ATTRIBUTES)
end

local function device_init(driver, device)
  log.info("[" .. device.id .. "] Initialisation du ZLinky")
  register_reporting(device)
  device.thread:call_on_schedule(POLL_INTERVAL_S, function() poll(device) end, "zlinky_poll")
  device:online()
end

local function device_added(driver, device)
  read_all(device)
end

local function do_configure(driver, device)
  local profile = register_reporting(device)
  device:configure()
  device:set_field(F_CONFIGURED, profile, PERSIST)
  read_all(device)
end

local function refresh_handler(driver, device, command)
  read_all(device)
end

------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------

local metering_handlers = {
  [0x0000] = total_handler,            -- BASE / EAST
  [0x0001] = injected_energy_handler,  -- EAIT (production)
  [0x0308] = serial_handler,           -- ADCO / ADSC
}
for i = 1, TIER_COUNT do
  metering_handlers[tier_attribute(i)] = tier_handler(i)
end

local zigbee_zlinky_template = {
  supported_capabilities = {
    capabilities.refresh,
    capabilities.energyMeter,
    capabilities.powerConsumptionReport,
    capabilities.currentMeasurement,
    capabilities.voltageMeasurement,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
  },
  additional_zcl_profiles = {
    [CLUSTER_METERING]   = true,
    [CLUSTER_METER_ID]   = true,
    [CLUSTER_ELECTRICAL] = true,
    [CLUSTER_LIXEE]      = true,
  },
  zigbee_handlers = {
    attr = {
      [CLUSTER_POWER_CFG] = {
        [ATTR_MAINS_VOLTAGE.ID] = module_voltage_handler,
      },
      [CLUSTER_METERING] = metering_handlers,
      [CLUSTER_ELECTRICAL] = {
        [0x0306] = total_apparent_power,     -- SINSTS (triphasé)
        [0x0505] = voltage_handler(1),       -- URMS1
        [0x0905] = voltage_handler(2),       -- URMS2
        [0x0A05] = voltage_handler(3),       -- URMS3
        [0x0508] = current_handler(1),       -- IINST / IINST1 / IRMS1
        [0x0908] = current_handler(2),       -- IINST2 / IRMS2
        [0x0A08] = current_handler(3),       -- IINST3 / IRMS3
        [0x050F] = apparent_power_050F,      -- PAPP / SINSTS / SINSTS1
        [0x090F] = apparent_power_phase(2),  -- SINSTS2
        [0x0A0F] = apparent_power_phase(3),  -- SINSTS3
      },
      [CLUSTER_LIXEE] = {
        [0x0000] = tariff_handler,           -- OPTARIF / NGTF
        [0x0207] = injected_power_handler,   -- SINSTI (production)
        [0x0300] = mode_handler,             -- mode Linky
      },
      [CLUSTER_METER_ID] = {
        [0x000D] = subscribed_power_handler, -- ISOUSC / PREF
      },
    },
  },
  lifecycle_handlers = {
    init        = device_init,
    added       = device_added,
    doConfigure = do_configure,
  },
}

local zigbee_zlinky = ZigbeeDriver("zigbee_zlinky", zigbee_zlinky_template)
zigbee_zlinky:run()
