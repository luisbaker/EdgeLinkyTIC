-- Driver Edge LAN pour ampoules Yeelight Wi-Fi (Controle LAN), sans app ni cloud Yeelight.
--
-- Protocole Yeelight (public) :
--   * decouverte : requete type SSDP en multicast 239.255.255.250:1982 (ST: wifi_bulb),
--     chaque ampoule repond avec Location: yeelight://IP:55443, id, model, fw_ver, support...
--   * commandes  : JSON sur TCP (port 55443), une ligne par message, termine par \r\n
--   * etat       : l'ampoule envoie {"method":"props","params":{...}} a chaque changement,
--     sur toutes les connexions ouvertes (meme si on utilise l'interrupteur mural).
-- Plusieurs ampoules : chacune devient un appareil SmartThings avec sa propre connexion.

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local json = require "st.json"
local log = require "log"
local cosock = require "cosock"
local socket = cosock.socket

local SSDP_IP = "239.255.255.250"
local SSDP_PORT = 1982
local CONTROL_PORT = 55443
local DISCOVERY_WINDOW_S = 3
local RECEIVE_TIMEOUT_S = 90   -- sans nouvelles pendant 90 s : on verifie la connexion
local KEEPALIVE_REPLY_S = 10   -- delai de reponse au get_prop de verification, sinon hors ligne
local CT_MIN, CT_MAX = 1700, 6500

-- Definis plus bas (dependances croisees entre connexion et decouverte)
local connect, disconnect, search_once
-- Le driver lui-meme, memorise au demarrage (pour la decouverte lancee depuis une connexion)
local the_driver

-- Champs memorises sur chaque appareil
local F_IP = "ip"
local F_MODEL = "model"
local F_FW = "fw_ver"

-- Etat des connexions, par appareil (device.id)
local connections = {}
-- Infos des ampoules trouvees pendant la decouverte, par id Yeelight
local discovered = {}

---------------------------------------------------------------------------
-- Outils
---------------------------------------------------------------------------
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function transition(device)
  local ms = tonumber(device.preferences and device.preferences.transition) or 400
  if ms <= 0 then return "sudden", 0 end
  return "smooth", math.max(30, ms) -- Yeelight impose 30 ms minimum
end

local function device_ip(device)
  local manual = device.preferences and device.preferences.ipAddress
  if manual ~= nil and manual:match("^%d+%.%d+%.%d+%.%d+$") then return manual end
  return device:get_field(F_IP)
end

-- RGB entier -> teinte (0-100) et saturation (0-100) pour SmartThings
local function rgb_to_hue_sat(rgb)
  local r = ((rgb >> 16) & 0xFF) / 255
  local g = ((rgb >> 8) & 0xFF) / 255
  local b = (rgb & 0xFF) / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local d = max - min
  local h = 0
  if d > 0 then
    if max == r then h = ((g - b) / d) % 6
    elseif max == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h * 60
  end
  local s = (max == 0) and 0 or d / max
  return math.floor(h / 3.6 + 0.5), math.floor(s * 100 + 0.5)
end

---------------------------------------------------------------------------
-- Etat : propriete Yeelight -> evenements SmartThings
---------------------------------------------------------------------------
local function apply_props(device, props)
  if props.power ~= nil then
    if props.power == "on" then device:emit_event(capabilities.switch.switch.on())
    else device:emit_event(capabilities.switch.switch.off()) end
  end
  local bright = tonumber(props.bright)
  if bright then device:emit_event(capabilities.switchLevel.level(clamp(bright, 0, 100))) end

  local mode = tonumber(props.color_mode)
  local ct = tonumber(props.ct)
  if ct and ct > 0 and (mode == nil or mode == 2) then
    device:emit_event(capabilities.colorTemperature.colorTemperature(clamp(ct, CT_MIN, CT_MAX)))
  end
  local hue, sat = tonumber(props.hue), tonumber(props.sat)
  if mode == 3 and hue and sat then
    device:emit_event(capabilities.colorControl.hue(math.floor(hue / 3.6 + 0.5)))
    device:emit_event(capabilities.colorControl.saturation(clamp(sat, 0, 100)))
  end
  local rgb = tonumber(props.rgb)
  if mode == 1 and rgb then
    local h, s = rgb_to_hue_sat(rgb)
    device:emit_event(capabilities.colorControl.hue(h))
    device:emit_event(capabilities.colorControl.saturation(s))
  end
end

local PROP_NAMES = { "power", "bright", "ct", "rgb", "hue", "sat", "color_mode" }

---------------------------------------------------------------------------
-- Connexion TCP (une par ampoule) et envoi des commandes
---------------------------------------------------------------------------
local function send(device, method, params)
  local conn = connections[device.id]
  if conn == nil or conn.sock == nil then
    log.warn(string.format("[%s] pas connecte, commande %s ignoree", device.label, method))
    connect(device)
    return false
  end
  conn.next_id = (conn.next_id % 9999) + 1
  local line = json.encode({ id = conn.next_id, method = method, params = params }) .. "\r\n"
  local _, err = conn.sock:send(line)
  if err then
    log.warn(string.format("[%s] envoi impossible (%s), reconnexion", device.label, err))
    conn.sock:close()
    conn.sock = nil
    connect(device)
    return false
  end
  if method == "get_prop" then conn.pending_get[conn.next_id] = true end
  return true
end

local function request_state(device)
  send(device, "get_prop", PROP_NAMES)
end

local function handle_line(device, line)
  local ok, msg = pcall(json.decode, line)
  if not ok or type(msg) ~= "table" then
    log.debug(string.format("[%s] message illisible : %s", device.label, tostring(line)))
    return
  end
  local conn = connections[device.id]
  if msg.method == "props" and type(msg.params) == "table" then
    apply_props(device, msg.params)
  elseif msg.id ~= nil and type(msg.result) == "table" and conn and conn.pending_get[msg.id] then
    conn.pending_get[msg.id] = nil
    local props = {}
    for i, name in ipairs(PROP_NAMES) do props[name] = msg.result[i] end
    apply_props(device, props)
  elseif msg.error ~= nil then
    log.warn(string.format("[%s] erreur de l'ampoule : %s", device.label, json.encode(msg.error)))
  end
end

-- Boucle de reception. Une ampoule eteinte au mur ne ferme pas la connexion TCP :
-- sans nouvelles pendant RECEIVE_TIMEOUT_S, on envoie un get_prop et on exige une
-- reponse sous KEEPALIVE_REPLY_S, sinon l'ampoule est declaree hors ligne.
local function receive_loop(device, conn, sock)
  local awaiting_reply = false
  while connections[device.id] == conn and conn.sock == sock do
    local line, err = sock:receive("*l")
    if line then
      awaiting_reply = false
      sock:settimeout(RECEIVE_TIMEOUT_S)
      handle_line(device, line)
    elseif err == "timeout" then
      if awaiting_reply then
        err = "pas de reponse au keepalive"
      else
        awaiting_reply = true
        sock:settimeout(KEEPALIVE_REPLY_S)
        request_state(device)
      end
    end
    if err and err ~= "timeout" then
      log.warn(string.format("[%s] connexion perdue (%s)", device.label, tostring(err)))
      if conn.sock == sock then
        sock:close()
        conn.sock = nil
        device:offline()
        connect(device)
      end
      return
    end
  end
end

-- Apres plusieurs echecs de connexion, l'ampoule a peut-etre change d'adresse IP
-- (bail DHCP). On relance une recherche multicast : si elle repond avec une autre
-- adresse, search_once la met a jour et relance la connexion.
local REDISCOVER_AFTER_FAILURES = 2

connect = function(device)
  local conn = connections[device.id]
  if conn == nil then
    conn = { next_id = 0, pending_get = {}, backoff = 5, failures = 0 }
    connections[device.id] = conn
  end
  if conn.sock ~= nil or conn.connecting then return end
  conn.connecting = true

  cosock.spawn(function()
    while connections[device.id] == conn and conn.sock == nil do
      local ip = device_ip(device)
      if ip == nil then
        log.warn(string.format("[%s] adresse IP inconnue : recherche sur le reseau", device.label))
        device:offline()
        search_once(the_driver)
        if device_ip(device) == nil then
          socket.sleep(conn.backoff)
          conn.backoff = math.min(conn.backoff * 2, 300)
        end
      else
        local sock = socket.tcp()
        sock:settimeout(5)
        local ok, err = sock:connect(ip, CONTROL_PORT)
        if ok then
          sock:settimeout(RECEIVE_TIMEOUT_S)
          conn.sock = sock
          conn.backoff = 5
          conn.failures = 0
          log.info(string.format("[%s] connecte a %s:%d", device.label, ip, CONTROL_PORT))
          device:online()
          request_state(device)
          cosock.spawn(function() receive_loop(device, conn, sock) end, "yeelight-recv-" .. device.id)
          break
        end
        sock:close()
        conn.failures = conn.failures + 1
        log.warn(string.format("[%s] connexion a %s impossible (%s), nouvel essai dans %d s", device.label, ip, tostring(err), conn.backoff))
        device:offline()
        if conn.failures >= REDISCOVER_AFTER_FAILURES and not (device.preferences and device.preferences.ipAddress ~= "") then
          log.info(string.format("[%s] l'ampoule a peut-etre change d'adresse : recherche sur le reseau", device.label))
          search_once(the_driver)
          if connections[device.id] ~= conn then return end -- search_once a relance une connexion avec la nouvelle IP
        end
        socket.sleep(conn.backoff)
        conn.backoff = math.min(conn.backoff * 2, 300)
      end
    end
    conn.connecting = false
  end, "yeelight-connect-" .. device.id)
end

disconnect = function(device)
  local conn = connections[device.id]
  connections[device.id] = nil
  if conn and conn.sock then conn.sock:close() end
end

---------------------------------------------------------------------------
-- Commandes SmartThings
---------------------------------------------------------------------------
local function ensure_on(device)
  if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" then
    local effect, ms = transition(device)
    send(device, "set_power", { "on", effect, ms })
  end
end

local function switch_on(driver, device, command)
  local effect, ms = transition(device)
  send(device, "set_power", { "on", effect, ms })
end

local function switch_off(driver, device, command)
  local effect, ms = transition(device)
  send(device, "set_power", { "off", effect, ms })
end

local function set_level(driver, device, command)
  local level = math.floor(tonumber(command.args.level) or 0)
  if level <= 0 then return switch_off(driver, device, command) end
  ensure_on(device)
  local effect, ms = transition(device)
  send(device, "set_bright", { clamp(level, 1, 100), effect, ms })
end

local function set_color(driver, device, command)
  local color = command.args.color or {}
  local hue = clamp(math.floor((tonumber(color.hue) or 0) * 3.6 + 0.5), 0, 359)
  local sat = clamp(math.floor((tonumber(color.saturation) or 100) + 0.5), 0, 100)
  ensure_on(device)
  local effect, ms = transition(device)
  send(device, "set_hsv", { hue, sat, effect, ms })
end

local function set_hue(driver, device, command)
  local sat = device:get_latest_state("main", capabilities.colorControl.ID, capabilities.colorControl.saturation.NAME) or 100
  set_color(driver, device, { args = { color = { hue = command.args.hue, saturation = sat } } })
end

local function set_saturation(driver, device, command)
  local hue = device:get_latest_state("main", capabilities.colorControl.ID, capabilities.colorControl.hue.NAME) or 0
  set_color(driver, device, { args = { color = { hue = hue, saturation = command.args.saturation } } })
end

local function set_color_temperature(driver, device, command)
  local ct = clamp(math.floor(tonumber(command.args.temperature) or 4000), CT_MIN, CT_MAX)
  ensure_on(device)
  local effect, ms = transition(device)
  send(device, "set_ct_abx", { ct, effect, ms })
end

local function refresh(driver, device, command)
  if connections[device.id] and connections[device.id].sock then
    request_state(device)
  else
    connect(device)
  end
end

---------------------------------------------------------------------------
-- Decouverte (bouton « Rechercher les appareils a proximite » de l'app)
---------------------------------------------------------------------------
local function parse_reply(text)
  local info = {}
  for line in text:gmatch("[^\r\n]+") do
    local k, v = line:match("^([%w_]+):%s*(.-)%s*$")
    if k then info[k:lower()] = v end
  end
  if info.location then
    info.ip, info.port = info.location:match("yeelight://([%d%.]+):(%d+)")
  end
  return info
end

local function known_device(driver, dni)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == dni then return d end
  end
  return nil
end

search_once = function(driver)
  local udp = socket.udp()
  udp:setsockname("*", 0)
  udp:settimeout(DISCOVERY_WINDOW_S)
  local request = table.concat({
    "M-SEARCH * HTTP/1.1",
    "HOST: " .. SSDP_IP .. ":" .. SSDP_PORT,
    "MAN: \"ssdp:discover\"",
    "ST: wifi_bulb",
    "", "",
  }, "\r\n")
  udp:sendto(request, SSDP_IP, SSDP_PORT)

  local deadline = socket.gettime() + DISCOVERY_WINDOW_S
  while socket.gettime() < deadline do
    udp:settimeout(math.max(0.1, deadline - socket.gettime()))
    local data = udp:receivefrom()
    if data then
      local info = parse_reply(data)
      if info.id and info.ip then
        discovered[info.id] = info
        local existing = known_device(driver, info.id)
        if existing then
          if existing:get_field(F_IP) ~= info.ip then
            log.info(string.format("[%s] nouvelle adresse IP : %s", existing.label, info.ip))
            existing:set_field(F_IP, info.ip, { persist = true })
            disconnect(existing)
            connect(existing)
          end
        else
          local model = info.model or "bulb"
          local label = (info.name and info.name ~= "") and info.name or ("Yeelight " .. model)
          log.info(string.format("Ampoule trouvee : %s (%s) a %s, firmware %s", info.id, model, info.ip, tostring(info.fw_ver)))
          driver:try_create_device({
            type = "LAN",
            device_network_id = info.id,
            label = label,
            profile = "yeelight-color",
            manufacturer = "Yeelight",
            model = model,
            vendor_provided_label = "Yeelight " .. model,
          })
        end
      end
    end
  end
  udp:close()
end

local function discovery(driver, opts, should_continue)
  log.info("Recherche des ampoules Yeelight (Controle LAN active requis)")
  while should_continue() do
    search_once(driver)
    socket.sleep(2)
  end
end

---------------------------------------------------------------------------
-- Cycle de vie
---------------------------------------------------------------------------
local function remember_discovery_info(device)
  local info = discovered[device.device_network_id]
  if info then
    device:set_field(F_IP, info.ip, { persist = true })
    if info.model then device:set_field(F_MODEL, info.model, { persist = true }) end
    if info.fw_ver then device:set_field(F_FW, info.fw_ver, { persist = true }) end
    log.info(string.format("[%s] modele %s, firmware %s, IP %s", device.label,
      tostring(info.model), tostring(info.fw_ver), tostring(info.ip)))
  end
end

local function device_init(driver, device)
  remember_discovery_info(device)
  connect(device)
end

local function device_added(driver, device)
  remember_discovery_info(device)
end

local function device_removed(driver, device)
  disconnect(device)
end

local function info_changed(driver, device, event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  if old.ipAddress ~= device.preferences.ipAddress then
    disconnect(device)
    connect(device)
  end
end

-- Verification periodique : une ampoule hors ligne dont l'IP a change est
-- retrouvee par la decouverte meme sans action dans l'app.
local RECHECK_S = 300
local function start_periodic_rediscovery(driver)
  driver:call_on_schedule(RECHECK_S, function()
    local offline = false
    for _, d in ipairs(driver:get_devices()) do
      local conn = connections[d.id]
      if conn == nil or conn.sock == nil then offline = true end
    end
    if offline then search_once(driver) end
  end, "yeelight-rediscover")
end

local driver = Driver("yeelight-lan-luis", {
  discovery = discovery,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    removed = device_removed,
    infoChanged = info_changed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level,
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = set_color,
      [capabilities.colorControl.commands.setHue.NAME] = set_hue,
      [capabilities.colorControl.commands.setSaturation.NAME] = set_saturation,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = set_color_temperature,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
  },
})

the_driver = driver
start_periodic_rediscovery(driver)
driver:run()
