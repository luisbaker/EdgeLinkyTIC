-- Driver Edge pour SmartThings (Station, hubs v2/v3, Aeotec)
--   * ZLinky TIC (LiXee)                       : compteur Linky -> sous-driver src/zlinky/
--   * Prise TS011F (_TZ3210_rwmitwj4, Nous A7Z) : on/off, puissance, energie, tension, courant
--   * Capteur lux TS0222 (_TZ3000_hy6ncvmw)     : luminosite + batterie (canal Tuya), anti-spam
--   * Capteur ZG-227Z (HOBEIAN)                : temperature + humidite + batterie (canal Tuya)
--
-- Sources utilisees pour les echelles / datapoints : Zigbee2MQTT (zigbee-herdsman-converters)
--   src/devices/tuya.ts   -> TS011F_plug_1 (Nous A7Z), TS0222 "Light intensity sensor"
--   src/devices/hobeian.ts -> ZG-227ZL / ZG-227Z (DP1 temp /10, DP2 humidite, DP4 batterie)
--   src/lib/legacy.ts     -> TS0222 (DP2 lux, DP4 batterie)

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"
local log = require "log"

local OnOff = clusters.OnOff
local ElectricalMeasurement = clusters.ElectricalMeasurement
local SimpleMetering = clusters.SimpleMetering
local Illuminance = clusters.IlluminanceMeasurement
local TemperatureMeasurement = clusters.TemperatureMeasurement
local RelativeHumidity = clusters.RelativeHumidity
local PowerConfiguration = clusters.PowerConfiguration
local Basic = clusters.Basic

-- Cluster proprietaire Tuya
local TUYA_CLUSTER = 0xEF00
local TUYA_DATA_RESPONSE = 0x01
local TUYA_DATA_REPORT = 0x02
local TUYA_TYPE_VALUE = 0x02 -- entier signe 32 bits

-- Champs memorises sur l'appareil
local POLL_TIMER = "poll_timer"
local LAST_LUX = "last_lux"
local LAST_LUX_TIME = "last_lux_time"
local HAS_BATTERY_PCT = "has_battery_pct"
local USES_TUYA_LUX = "uses_tuya_lux"
local USES_TUYA_TEMP = "uses_tuya_temp"
local USES_TUYA_HUM = "uses_tuya_hum"
local CONFIGURED_INTERVAL = "configured_interval_v2" -- v2 : force un vrai envoi (v1 etait note a tort)

-- Ces capteurs envoient par le canal standard ET (plus rarement) par le canal Tuya.
-- Apres une mesure Tuya, le canal standard est ignore pendant 10 min seulement
-- (evite les doublons), puis de nouveau pris en compte.
local TUYA_PRIORITY_S = 600
local function tuya_recent(device, field)
  local t = device:get_field(field)
  return type(t) == "number" and (os.time() - t) < TUYA_PRIORITY_S
end

-- Defini plus bas : envoie la config au capteur quand il est reveille
local maybe_reconfigure
-- Defini plus bas : passe une prise "sans mesure" sur le profil avec consommation
local enable_metering
local METERING_DETECTED = "metering_detected"

-- Echelles de la prise (Z2M TS011F_plug_1). Tension et puissance : lues sur la prise.
local CURRENT_DIVISOR = 1000 -- mA -> A
local ENERGY_DIVISOR = 100   -- -> kWh
local VOLT_MULT, VOLT_DIV = "volt_mult", "volt_div"
local POWER_MULT, POWER_DIV = "power_mult", "power_div"

---------------------------------------------------------------------------
-- Utilitaires
---------------------------------------------------------------------------
local function is_plug(device) return device:get_model() == "TS011F" end

-- Prises TS011F sans mesure de consommation (Z2M : TS011F_plug_2).
-- Certaines versions materielles mesurent quand meme : le driver le detecte
-- (voir enable_metering) et bascule alors sur le profil avec consommation.
local NON_METERED_PLUGS = {
  ["_TZ3000_o1jzcxou"] = true, -- BSEED prise murale
}
local function is_metered_plug(device)
  if not is_plug(device) then return false end
  if device:get_field(METERING_DETECTED) then return true end
  return not NON_METERED_PLUGS[device:get_manufacturer()]
end
local function is_lux(device) return device:get_model() == "TS0222" end
local function is_light(device) return device:get_model() == "TS0503B" end
local function is_temp(device) return device:get_model() == "ZG-227Z" end

local function pref(device, name, default)
  local v = device.preferences and device.preferences[name]
  if v == nil then return default end
  return v
end

local function round(v, decimals)
  local m = 10 ^ (decimals or 0)
  return math.floor(v * m + 0.5) / m
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function bind(driver, device, cluster_id)
  device:send(device_management.build_bind_request(device, cluster_id, driver.environment_info.hub_zigbee_eui))
end

-- "Magic packet" Tuya (comme tuya.configureMagicPacket dans Z2M) :
-- sans cette lecture, beaucoup d'appareils Tuya n'envoient pas leurs mesures.
local function tuya_magic(device)
  device:send(Basic.attributes.ManufacturerName:read(device))
  device:send(Basic.attributes.ZCLVersion:read(device))
  device:send(Basic.attributes.ApplicationVersion:read(device))
  device:send(Basic.attributes.ModelIdentifier:read(device))
  device:send(Basic.attributes.PowerSource:read(device))
  local ok, err = pcall(function()
    device:send(cluster_base.read_attribute(device, data_types.ClusterId(Basic.ID), data_types.AttributeId(0xFFFE)))
  end)
  if not ok then log.warn("Lecture 0xFFFE impossible : " .. tostring(err)) end
end

-- Demande a l'appareil de verifier s'il existe une mise a jour firmware
-- (comme les drivers officiels, ex. Inovelli). L'appareil interroge alors la
-- Station, qui ne propose que les firmwares deposes chez Samsung.
local TUYA_MFG_CODE = 0x1141
local function ota_image_notify(device)
  local ok, err = pcall(function()
    device:send(clusters.OTAUpgrade.commands.ImageNotify(device, 0x00, 100, TUYA_MFG_CODE, 0xFFFF, 0xFFFFFFFF))
  end)
  if not ok then log.warn("ImageNotify impossible : " .. tostring(err)) end
end

local function emit_battery(device, pct)
  device:emit_event(capabilities.battery.battery(clamp(math.floor(pct + 0.5), 0, 100)))
end

---------------------------------------------------------------------------
-- Prise TS011F
---------------------------------------------------------------------------
local function plug_refresh(device)
  device:send(OnOff.attributes.OnOff:read(device))
  if not is_metered_plug(device) then
    -- Sonde : si la prise repond avec une vraie mesure, on active la consommation
    device:send(ElectricalMeasurement.attributes.ActivePower:read(device))
    device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
    return
  end
  device:send(ElectricalMeasurement.attributes.ActivePower:read(device))
  device:send(ElectricalMeasurement.attributes.RMSVoltage:read(device))
  device:send(ElectricalMeasurement.attributes.RMSCurrent:read(device))
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
end

local function read_plug_scales(device)
  device:send(ElectricalMeasurement.attributes.ACVoltageMultiplier:read(device))
  device:send(ElectricalMeasurement.attributes.ACVoltageDivisor:read(device))
  device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
  device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
end

-- Lecture periodique en plus des rapports (certaines TS011F en ratent).
local function start_polling(device)
  local old = device:get_field(POLL_TIMER)
  if old ~= nil then device.thread:cancel_timer(old) end
  local interval = pref(device, "pollInterval", 120)
  local timer = device.thread:call_on_schedule(interval, function() plug_refresh(device) end, "plug_poll")
  device:set_field(POLL_TIMER, timer)
  log.info(string.format("Prise %s : lecture toutes les %d s", tostring(device.label), interval))
end

-- SmartThings Energy : un rapport de consommation toutes les 15 min
local ENERGY_TIMER = "energy_timer"
local LAST_REPORT_WH = "last_report_wh"
local LAST_REPORT_TIME = "last_report_time"
local ENERGY_REPORT_INTERVAL = 15 * 60

local function iso_time(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- Meme format que les appareils Samsung (ex. lave-linge) : periode start/end,
-- energie totale et consommee sur la periode (Wh), puissance actuelle (W).
local function emit_consumption_report(device)
  local kwh = device:get_latest_state("main", capabilities.energyMeter.ID, capabilities.energyMeter.energy.NAME)
  if kwh == nil then return end
  local wh = kwh * 1000
  local now = os.time()
  local last_wh = device:get_field(LAST_REPORT_WH)
  local last_t = device:get_field(LAST_REPORT_TIME) or (now - ENERGY_REPORT_INTERVAL)
  local delta = 0
  if last_wh ~= nil and wh >= last_wh then delta = wh - last_wh end
  local power = device:get_latest_state("main", capabilities.powerMeter.ID, capabilities.powerMeter.power.NAME) or 0
  device:emit_event(capabilities.powerConsumptionReport.powerConsumption({
    start = iso_time(last_t),
    ["end"] = iso_time(now - 1),
    energy = round(wh, 1),
    deltaEnergy = round(delta, 1),
    power = power,
  }))
  device:set_field(LAST_REPORT_WH, wh, { persist = true })
  device:set_field(LAST_REPORT_TIME, now, { persist = true })
end

local function start_energy_reports(device)
  local old = device:get_field(ENERGY_TIMER)
  if old ~= nil then device.thread:cancel_timer(old) end
  local timer = device.thread:call_on_schedule(ENERGY_REPORT_INTERVAL, function() emit_consumption_report(device) end, "energy_report")
  device:set_field(ENERGY_TIMER, timer)
  -- Premier rapport 1 min apres le demarrage si le dernier date de plus de 15 min
  -- (sinon chaque redemarrage du driver repoussait le rapport de 15 min).
  local last_t = device:get_field(LAST_REPORT_TIME) or 0
  if os.time() - last_t >= ENERGY_REPORT_INTERVAL then
    device.thread:call_with_delay(60, function() emit_consumption_report(device) end, "energy_first_report")
  end
end

local function scale(device, mult_field, div_field, raw)
  local mult = device:get_field(mult_field) or 1
  local div = device:get_field(div_field) or 1
  if mult == 0 then mult = 1 end
  if div == 0 then div = 1 end
  return raw * mult / div
end

local function store_scale(field)
  return function(driver, device, value, zb_rx)
    device:set_field(field, value.value, { persist = true })
  end
end

local function onoff_handler(driver, device, value, zb_rx)
  if value.value then
    device:emit_event(capabilities.switch.switch.on())
  else
    device:emit_event(capabilities.switch.switch.off())
  end
end

-- Prise declaree "sans mesure" qui renvoie une vraie valeur (> 0) : elle mesure.
local function probe_metering(driver, device, raw)
  if is_metered_plug(device) then return false end
  if type(raw) == "number" and raw > 0 then
    enable_metering(driver, device)
  else
    log.debug(tostring(device.label) .. " : pas de mesure de consommation (valeur " .. tostring(raw) .. ")")
  end
  return true
end

local function active_power_handler(driver, device, value, zb_rx)
  if probe_metering(driver, device, value.value) then return end
  local w = scale(device, POWER_MULT, POWER_DIV, value.value)
  if w < 0 then w = 0 end
  device:emit_event(capabilities.powerMeter.power({ value = round(w, 1), unit = "W" }))
end

local function voltage_handler(driver, device, value, zb_rx)
  if not is_metered_plug(device) then return end
  local v = scale(device, VOLT_MULT, VOLT_DIV, value.value)
  device:emit_event(capabilities.voltageMeasurement.voltage({ value = round(v, 1), unit = "V" }))
end

local function current_handler(driver, device, value, zb_rx)
  if not is_metered_plug(device) then return end
  device:emit_event(capabilities.currentMeasurement.current({ value = round(value.value / CURRENT_DIVISOR, 3), unit = "A" }))
end

-- Consommation par periode, affichee sur la page de la prise (composants
-- "today", "week", "month" du profil). Remise a zero a minuit, le lundi et le 1er.
local PERIODS = {
  { component = "today", key = function(t) return os.date("!%Y-%m-%d", t) end },
  { component = "week",  key = function(t) return os.date("!%Y-S%W", t) end }, -- semaine commencant le lundi
  { component = "month", key = function(t) return os.date("!%Y-%m", t) end },
}

local function update_periods(device, kwh)
  local local_time = os.time() + pref(device, "utcOffset", 1) * 3600
  for _, p in ipairs(PERIODS) do
    local component = device.profile.components[p.component]
    if component ~= nil then
      local key = p.key(local_time)
      local key_field = "period_key_" .. p.component
      local base_field = "period_base_" .. p.component
      if device:get_field(key_field) ~= key or device:get_field(base_field) == nil then
        device:set_field(key_field, key, { persist = true })
        device:set_field(base_field, kwh, { persist = true })
      end
      local used = math.max(0, kwh - device:get_field(base_field))
      device:emit_component_event(component, capabilities.energyMeter.energy({ value = round(used, 2), unit = "kWh" }))
    end
  end
end

local function energy_handler(driver, device, value, zb_rx)
  if probe_metering(driver, device, value.value) then return end
  local kwh = round(value.value / ENERGY_DIVISOR, 2)
  device:emit_event(capabilities.energyMeter.energy({ value = kwh, unit = "kWh" }))
  update_periods(device, kwh)
end

local function configure_plug(driver, device)
  bind(driver, device, OnOff.ID)
  bind(driver, device, ElectricalMeasurement.ID)
  bind(driver, device, SimpleMetering.ID)
  read_plug_scales(device)
  -- Memes seuils que Zigbee2MQTT
  device:send(OnOff.attributes.OnOff:configure_reporting(device, 0, 300))
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 5, 3600, 1))
  device:send(ElectricalMeasurement.attributes.RMSVoltage:configure_reporting(device, 5, 3600, 5))
  device:send(ElectricalMeasurement.attributes.RMSCurrent:configure_reporting(device, 5, 3600, 50))
  device:send(ElectricalMeasurement.attributes.ActivePower:configure_reporting(device, 5, 3600, 10))
  plug_refresh(device)
end

enable_metering = function(driver, device)
  if device:get_field(METERING_DETECTED) then return end
  log.info(tostring(device.label) .. " : mesure de consommation detectee, passage au profil avec consommation")
  device:set_field(METERING_DETECTED, true, { persist = true })
  device:try_update_metadata({ profile = "plug-power-energy" })
  configure_plug(driver, device)
  start_polling(device)
  start_energy_reports(device)
end

local function configure_basic_plug(driver, device)
  bind(driver, device, OnOff.ID)
  device:send(OnOff.attributes.OnOff:configure_reporting(device, 0, 300))
  plug_refresh(device)
end

---------------------------------------------------------------------------
-- Ruban LED RGB TS0503B : clusters standard (comme Z2M tuyaLight({color: true}))
-- Variation et couleur : gestionnaires par defaut du SDK SmartThings.
---------------------------------------------------------------------------
local Level = clusters.Level
local ColorControl = clusters.ColorControl

local function light_refresh(device)
  device:send(OnOff.attributes.OnOff:read(device))
  device:send(Level.attributes.CurrentLevel:read(device))
  device:send(ColorControl.attributes.CurrentHue:read(device))
  device:send(ColorControl.attributes.CurrentSaturation:read(device))
end

local function configure_light(driver, device)
  bind(driver, device, OnOff.ID)
  bind(driver, device, Level.ID)
  bind(driver, device, ColorControl.ID)
  device:send(OnOff.attributes.OnOff:configure_reporting(device, 0, 300))
  device:send(Level.attributes.CurrentLevel:configure_reporting(device, 1, 3600, 1))
  device:send(ColorControl.attributes.CurrentHue:configure_reporting(device, 1, 3600, 0x0010))
  device:send(ColorControl.attributes.CurrentSaturation:configure_reporting(device, 1, 3600, 0x0010))
  light_refresh(device)
end

-- Reglages Tuya des prises TS011F (attributs du cluster On/Off, cf. Z2M lib/tuya.ts)
local TUYA_CHILD_LOCK = 0x8000     -- booleen
local TUYA_INDICATOR_MODE = 0x8001 -- 0 eteint, 1 allume quand eteinte, 2 allume quand allumee, 3 toujours
local TUYA_POWER_ON = 0x8002       -- 0 eteinte, 1 allumee, 2 etat precedent

local function write_onoff_attribute(device, attribute, data_type, value)
  device:send(cluster_base.write_attribute(device,
    data_types.ClusterId(OnOff.ID),
    data_types.AttributeId(attribute),
    data_types.validate_or_build_type(value, data_type)))
end

-- N'ecrit que les reglages modifies : la prise garde ses propres reglages
-- tant que l'utilisateur n'y touche pas.
local function apply_plug_settings(device, old)
  local p = device.preferences or {}
  if p.powerOnBehavior ~= nil and p.powerOnBehavior ~= old.powerOnBehavior then
    write_onoff_attribute(device, TUYA_POWER_ON, data_types.Enum8, tonumber(p.powerOnBehavior))
  end
  if p.indicatorMode ~= nil and p.indicatorMode ~= old.indicatorMode then
    write_onoff_attribute(device, TUYA_INDICATOR_MODE, data_types.Enum8, tonumber(p.indicatorMode))
  end
  if p.childLock ~= nil and p.childLock ~= old.childLock then
    write_onoff_attribute(device, TUYA_CHILD_LOCK, data_types.Boolean, p.childLock)
  end
end

---------------------------------------------------------------------------
-- Capteur de luminosite TS0222
---------------------------------------------------------------------------
local function emit_lux(device, lux)
  lux = math.floor(lux * pref(device, "luxMultiplier", 1) + 0.5)

  -- Anti-spam : le TS0222 envoie une mesure toutes les ~20 s.
  local now = os.time()
  local last = device:get_field(LAST_LUX)
  local last_t = device:get_field(LAST_LUX_TIME) or 0
  if last ~= nil then
    local change_pct
    if last == 0 then
      change_pct = (lux > 0) and 100 or 0
    else
      change_pct = math.abs(lux - last) * 100 / last
    end
    if (now - last_t) < pref(device, "luxMinInterval", 60) and change_pct < pref(device, "luxMinChange", 15) then
      return
    end
  end
  device:set_field(LAST_LUX, lux)
  device:set_field(LAST_LUX_TIME, now)
  device:emit_event(capabilities.illuminanceMeasurement.illuminance({ value = lux, unit = "lux" }))
end

-- Cluster standard 0x0400 (utilise seulement si le canal Tuya n'envoie rien)
local function lux_handler(driver, device, value, zb_rx)
  if tuya_recent(device, USES_TUYA_LUX) then return end
  local raw = value.value
  if raw == 0xFFFF then return end -- valeur invalide
  local lux
  if pref(device, "luxMode", "log") == "raw" then
    lux = raw
  else
    lux = (raw > 0) and 10 ^ ((raw - 1) / 10000) or 0
  end
  emit_lux(device, lux)
end

local function configure_lux(driver, device)
  bind(driver, device, Illuminance.ID)
  bind(driver, device, PowerConfiguration.ID)
  device:send(Illuminance.attributes.MeasuredValue:configure_reporting(device, pref(device, "luxMinInterval", 60), 3600, 500))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 3600, 21600, 1))
end

---------------------------------------------------------------------------
-- Capteur temperature / humidite ZG-227Z
---------------------------------------------------------------------------
local function emit_temperature(device, celsius)
  local c = celsius + pref(device, "tempCorrection", 0)
  device:emit_event(capabilities.temperatureMeasurement.temperature({ value = round(c, 1), unit = "C" }))
end

local function emit_humidity(device, pct)
  local h = clamp(pct + pref(device, "humCorrection", 0), 0, 100)
  device:emit_event(capabilities.relativeHumidityMeasurement.humidity({ value = round(h, 0) }))
end

-- Clusters standard 0x0402 / 0x0405 : toujours pris en compte, comme le driver officiel
-- SmartThings (zigbee-humidity-sensor). Le canal Tuya ne fait que s'y ajouter.
local function temp_handler(driver, device, value, zb_rx)
  maybe_reconfigure(driver, device)
  local raw = value.value
  if raw == -32768 then return end -- 0x8000 = valeur invalide
  emit_temperature(device, raw / (tonumber(pref(device, "tempDivisor", "100")) or 100))
end

local function humidity_handler(driver, device, value, zb_rx)
  maybe_reconfigure(driver, device)
  local raw = value.value
  if raw == 0xFFFF then return end -- valeur invalide
  emit_humidity(device, raw / (tonumber(pref(device, "humDivisor", "100")) or 100))
end

local function sensor_refresh(device)
  -- Appareil sur batterie : il ne repond que s'il est reveille (appui sur son bouton).
  device:send(TemperatureMeasurement.attributes.MeasuredValue:read(device))
  device:send(RelativeHumidity.attributes.MeasuredValue:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
end

local function report_interval_s(device)
  return (tonumber(pref(device, "reportInterval", "15")) or 15) * 60
end

local function configure_temp(driver, device)
  local max_interval = report_interval_s(device)
  bind(driver, device, TemperatureMeasurement.ID)
  bind(driver, device, RelativeHumidity.ID)
  bind(driver, device, PowerConfiguration.ID)
  device:send(TemperatureMeasurement.attributes.MeasuredValue:configure_reporting(device, 30, max_interval, 10))  -- 0,1 C
  device:send(RelativeHumidity.attributes.MeasuredValue:configure_reporting(device, 30, max_interval, 100))      -- 1 %
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 3600, 21600, 1))
  log.info(string.format("%s : envoi au moins toutes les %d min", tostring(device.label), max_interval // 60))
  sensor_refresh(device)
end

-- Le capteur dort : on profite de chaque message recu (il est reveille a ce moment-la)
-- pour lui envoyer la configuration si elle n'est pas encore a jour. La config n'est
-- notee comme appliquee qu'ici, quand on sait que le capteur ecoute.
maybe_reconfigure = function(driver, device)
  if is_temp(device) and device:get_field(CONFIGURED_INTERVAL) ~= report_interval_s(device) then
    log.info(tostring(device.label) .. " est reveille : envoi de la configuration")
    configure_temp(driver, device)
    device:set_field(CONFIGURED_INTERVAL, report_interval_s(device), { persist = true })
  end
end

---------------------------------------------------------------------------
-- Canal proprietaire Tuya (cluster 0xEF00, "datapoints")
-- Trame : seq(2 octets) puis, pour chaque DP : id(1) type(1) longueur(2) valeur(longueur)
---------------------------------------------------------------------------
local function handle_tuya_dp(device, dp, dp_type, value)
  if is_lux(device) then
    if dp == 2 then
      device:set_field(USES_TUYA_LUX, os.time())
      emit_lux(device, value)
    elseif dp == 4 then
      emit_battery(device, value)
    else
      log.debug(string.format("TS0222 : DP %d inconnu (valeur %s)", dp, tostring(value)))
    end
  elseif is_temp(device) then
    if dp == 1 then
      device:set_field(USES_TUYA_TEMP, os.time())
      emit_temperature(device, value / 10)
    elseif dp == 2 then
      device:set_field(USES_TUYA_HUM, os.time())
      emit_humidity(device, value)
    elseif dp == 4 then
      emit_battery(device, value)
    else
      log.debug(string.format("ZG-227Z : DP %d inconnu (valeur %s)", dp, tostring(value)))
    end
  end
end

local function tuya_cluster_handler(driver, device, zb_rx)
  maybe_reconfigure(driver, device)
  local bytes = zb_rx.body.zcl_body.body_bytes
  local i = 3 -- on saute le numero de sequence (2 octets)
  while i + 3 <= #bytes do
    local dp = bytes:byte(i)
    local dp_type = bytes:byte(i + 1)
    local len = bytes:byte(i + 2) * 256 + bytes:byte(i + 3)
    if i + 3 + len > #bytes then break end
    local value = 0
    for k = 0, len - 1 do
      value = value * 256 + bytes:byte(i + 4 + k)
    end
    if dp_type == TUYA_TYPE_VALUE and len == 4 and value >= 0x80000000 then
      value = value - 0x100000000 -- valeur negative (ex. temperature sous 0)
    end
    handle_tuya_dp(device, dp, dp_type, value)
    i = i + 4 + len
  end
end

---------------------------------------------------------------------------
-- Batterie (cluster standard)
---------------------------------------------------------------------------
local function battery_pct_handler(driver, device, value, zb_rx)
  maybe_reconfigure(driver, device)
  if value.value == 0xFF then return end
  device:set_field(HAS_BATTERY_PCT, true, { persist = true })
  emit_battery(device, value.value / 2)
end

local function battery_voltage_handler(driver, device, value, zb_rx)
  -- Utilise seulement si l'appareil n'envoie pas de pourcentage.
  if device:get_field(HAS_BATTERY_PCT) then return end
  if value.value == 0xFF or value.value == 0 then return end
  local volts = value.value / 10
  emit_battery(device, (volts - 2.1) / (3.0 - 2.1) * 100)
end

---------------------------------------------------------------------------
-- Commandes
---------------------------------------------------------------------------
local function switch_on(driver, device, command)
  device:send(OnOff.server.commands.On(device))
end

local function switch_off(driver, device, command)
  device:send(OnOff.server.commands.Off(device))
end

local function refresh_handler(driver, device, command)
  if is_plug(device) then
    plug_refresh(device)
  elseif is_temp(device) then
    sensor_refresh(device)
  elseif is_light(device) then
    light_refresh(device)
  end
end

---------------------------------------------------------------------------
-- Cycle de vie
---------------------------------------------------------------------------
local function do_configure(driver, device)
  log.info("Configuration de " .. tostring(device.label) .. " (" .. tostring(device:get_model()) .. ")")
  tuya_magic(device)
  ota_image_notify(device)
  if is_metered_plug(device) then
    configure_plug(driver, device)
  elseif is_plug(device) then
    configure_basic_plug(driver, device)
  elseif is_light(device) then
    configure_light(driver, device)
  elseif is_lux(device) then
    configure_lux(driver, device)
  elseif is_temp(device) then
    configure_temp(driver, device)
  end
  pcall(function() device:try_update_metadata({ provisioning_state = "PROVISIONED" }) end)
end

local function device_init(driver, device)
  if is_metered_plug(device) then
    start_polling(device)
    start_energy_reports(device)
  end
end

local function device_added(driver, device)
  if is_plug(device) then plug_refresh(device) end
  if is_light(device) then light_refresh(device) end
end

local function info_changed(driver, device, event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  if is_metered_plug(device) and old.pollInterval ~= device.preferences.pollInterval then
    start_polling(device)
  end
  if is_plug(device) then
    apply_plug_settings(device, old)
  end
  if is_lux(device) and old.luxMinInterval ~= device.preferences.luxMinInterval then
    device:send(Illuminance.attributes.MeasuredValue:configure_reporting(device, device.preferences.luxMinInterval, 3600, 500))
  end
  if is_temp(device) and old.reportInterval ~= device.preferences.reportInterval then
    -- Le capteur dort : la config partira a son prochain reveil (maybe_reconfigure)
    device:set_field(CONFIGURED_INTERVAL, nil, { persist = true })
  end
end

local function driver_switched(driver, device, event, args)
  do_configure(driver, device)
end

---------------------------------------------------------------------------
-- Driver
---------------------------------------------------------------------------
local driver_template = {
  -- Ancienne surveillance des attributs, depreciee par le SDK (avertissement toutes les 30 s)
  health_check = false,
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.voltageMeasurement,
    capabilities.currentMeasurement,
    capabilities.powerConsumptionReport,
    capabilities.illuminanceMeasurement,
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.battery,
    capabilities.refresh,
    capabilities.switchLevel,    -- ruban LED
    capabilities.colorControl,   -- ruban LED
    capabilities.signalStrength, -- ZLinky
  },
  -- Repris tel quel du driver ZLinky d'origine
  additional_zcl_profiles = {
    [0x0702] = true,
    [0x0B01] = true,
    [0x0B04] = true,
    [0xFF66] = true,
  },
  sub_drivers = {
    require("zlinky"), -- LiXee ZLinky TIC (compteur Linky)
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
  },
  zigbee_handlers = {
    attr = {
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = onoff_handler,
      },
      [ElectricalMeasurement.ID] = {
        [ElectricalMeasurement.attributes.ActivePower.ID] = active_power_handler,
        [ElectricalMeasurement.attributes.RMSVoltage.ID] = voltage_handler,
        [ElectricalMeasurement.attributes.RMSCurrent.ID] = current_handler,
        [ElectricalMeasurement.attributes.ACVoltageMultiplier.ID] = store_scale(VOLT_MULT),
        [ElectricalMeasurement.attributes.ACVoltageDivisor.ID] = store_scale(VOLT_DIV),
        [ElectricalMeasurement.attributes.ACPowerMultiplier.ID] = store_scale(POWER_MULT),
        [ElectricalMeasurement.attributes.ACPowerDivisor.ID] = store_scale(POWER_DIV),
      },
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_handler,
      },
      [Illuminance.ID] = {
        [Illuminance.attributes.MeasuredValue.ID] = lux_handler,
      },
      [TemperatureMeasurement.ID] = {
        [TemperatureMeasurement.attributes.MeasuredValue.ID] = temp_handler,
      },
      [RelativeHumidity.ID] = {
        [RelativeHumidity.attributes.MeasuredValue.ID] = humidity_handler,
      },
      [PowerConfiguration.ID] = {
        [PowerConfiguration.attributes.BatteryPercentageRemaining.ID] = battery_pct_handler,
        [PowerConfiguration.attributes.BatteryVoltage.ID] = battery_voltage_handler,
      },
    },
    cluster = {
      [TUYA_CLUSTER] = {
        [TUYA_DATA_RESPONSE] = tuya_cluster_handler,
        [TUYA_DATA_REPORT] = tuya_cluster_handler,
      },
    },
  },
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    doConfigure = do_configure,
    infoChanged = info_changed,
    driverSwitched = driver_switched,
  },
}

-- Variation et couleur du ruban LED : gestionnaires par defaut du SDK
-- (uniquement pour ces 2 capacites, nos propres gestionnaires restent prioritaires).
defaults.register_for_default_handlers(driver_template, { capabilities.switchLevel, capabilities.colorControl })

local driver = ZigbeeDriver("zigbee-tuya-luis", driver_template)
driver:run()
