-- forge_items pour Luanti / Mineclonia
--   /add_items <nom> [| <effets|no> [| <infini yes|no>]]
--   /items_menu | /items_get <id> | /items_list | /items_delete <id> | /items_effects
-- Tout est protégé par le privilège "add_items".

local MOD = core.get_current_modname()
local storage = core.get_mod_storage()
local http = core.request_http_api()
if not http then
	core.log("warning", "[" .. MOD .. "] API HTTP indisponible : /ai_items et /ai_enchant ne marcheront pas. Ajoute secure.http_mods = " .. MOD .. " dans minetest.conf")
end

local PRIV = "add_items"
local K_EFFECTS = MOD .. ":effects"
local K_INFINITE = MOD .. ":infinite"
local EFFECT_SECONDS = 4 -- durée de l'effet, rafraîchie chaque seconde tant que l'item est porté/tenu

core.register_privilege(PRIV, {
	description = "Peut forger des items (/add_items) et utiliser le catalogue (/items_menu)",
	give_to_singleplayer = true,
})

---------------------------------------------------------------------
-- Utilitaires
---------------------------------------------------------------------
local function setting(key, default)
	local v = core.settings:get(MOD .. "." .. key)
	if v == nil or v == "" then return default end
	return v
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- <préfixe><nom du joueur><suffixe>, ex : ¥£Excalibur™
local function decorate(name)
	return setting("name_prefix", "¥£") .. tostring(name) .. setting("name_suffix", "™")
end

-- Applique le nom en gardant les enchantements / infobulles de Mineclonia
local function set_display_name(stack, shown)
	local meta = stack:get_meta()
	meta:set_string("name", shown) -- champ utilisé par l'enclume Mineclonia
	meta:set_string("description", shown)
	local t = rawget(_G, "tt")
	if t and t.reload_itemstack_description then
		pcall(t.reload_itemstack_description, stack)
		if not meta:get_string("description"):find(shown, 1, true) then
			meta:set_string("description", shown)
		end
	end
end

local ACCENTS = {
	["à"]="a",["â"]="a",["ä"]="a",["é"]="e",["è"]="e",["ê"]="e",["ë"]="e",
	["î"]="i",["ï"]="i",["ô"]="o",["ö"]="o",["ù"]="u",["û"]="u",["ü"]="u",["ç"]="c",
}

local function slug(s)
	s = tostring(s):lower()
	for k, v in pairs(ACCENTS) do s = s:gsub(k, v) end
	s = s:gsub("[^a-z0-9_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
	if s == "" then s = "item" end
	return s
end

local function give(name, stack)
	local inv = core.get_inventory({type = "player", name = name})
	if not inv then return end
	local left = inv:add_item("main", stack)
	if not left:is_empty() then
		local player = core.get_player_by_name(name)
		if player then core.add_item(player:get_pos(), left) end
	end
end

---------------------------------------------------------------------
-- Stockage (par monde)
---------------------------------------------------------------------
local items = {}

do
	local s = storage:get_string("items")
	if s ~= "" then items = core.parse_json(s) or {} end
end

local function save_items() storage:set_string("items", core.write_json(items)) end

local function sorted_ids()
	local ids = {}
	for id in pairs(items) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function add_item(def, creator)
	local base = slug(def.name)
	local id, n = base, 2
	while items[id] do id = base .. "_" .. n; n = n + 1 end
	def.id = id
	def.creator = creator
	items[id] = def
	save_items()
	return id
end

---------------------------------------------------------------------
-- Effets de potion (Mineclonia) : armure portée / item tenu
---------------------------------------------------------------------
local function potions()
	local P = rawget(_G, "mcl_potions")
	if P and P.registered_effects then return P end
end

-- "no" / vide -> nil (aucun effet) ; sinon liste {{id=, level=}, ...} ; erreur -> nil, message
local function parse_effects(text)
	text = trim(text or "")
	local low = text:lower()
	if text == "" or low == "no" or low == "non" or low == "none" then return nil end

	local P = potions()
	if not P then return nil, "La liste des effets Mineclonia (mcl_potions) est indisponible." end

	local list = {}
	for entry in text:gmatch("[^,;]+") do
		entry = trim(entry)
		local id, lvl = entry:match("^([%w_]+)[%s:=]+(%d+)$")
		if not id then
			id = entry:match("^([%w_]+)$")
			lvl = 1
		end
		if not id then
			return nil, "Effet mal écrit : '" .. entry .. "' (format : id:niveau)"
		end
		id = id:lower()
		if not P.registered_effects[id] then
			return nil, "Effet inconnu : " .. id .. " (voir /items_effects)"
		end
		lvl = math.floor(tonumber(lvl))
		if lvl < 1 or lvl > 255 then
			return nil, "Niveau invalide pour " .. id .. " (1 à 255)"
		end
		list[#list + 1] = {id = id, level = lvl}
	end
	if #list == 0 then return nil end
	return list
end

local function parse_bool(text)
	text = trim(text or ""):lower()
	if text == "" or text == "no" or text == "non" or text == "n" or text == "false" or text == "0" then
		return false
	end
	if text == "yes" or text == "oui" or text == "y" or text == "o" or text == "true" or text == "1" then
		return true
	end
	return nil, "Valeur invalide '" .. text .. "' : écris yes ou no."
end

---------------------------------------------------------------------
-- Construction de l'item depuis sa définition
---------------------------------------------------------------------
local function build_stack(def)
	local stack = ItemStack(def.itemstring)
	if stack:is_empty() then error("item enregistré invalide : " .. tostring(def.itemstring)) end
	stack:set_count(1)
	local meta = stack:get_meta()

	local has_effects = type(def.effects) == "table" and #def.effects > 0
	meta:set_string(K_EFFECTS, has_effects and core.write_json(def.effects) or "")
	meta:set_string(K_INFINITE, def.infinite and "1" or "")

	-- Durabilité infinie : capacités d'outil sans usure (en plus du remise à zéro de l'usure)
	if def.infinite then
		local caps = stack:get_tool_capabilities()
		if caps then
			local tc = table.copy(caps)
			for _, cap in pairs(tc.groupcaps or {}) do cap.uses = 0 end
			tc.punch_attack_uses = 0
			meta:set_tool_capabilities(tc)
		end
	end

	set_display_name(stack, decorate(def.name))

	-- Lignes d'info ajoutées à l'infobulle
	local extra = {}
	if has_effects then
		local parts = {}
		for _, e in ipairs(def.effects) do parts[#parts + 1] = e.id .. " " .. e.level end
		extra[#extra + 1] = "Effets : " .. table.concat(parts, ", ")
	end
	if def.infinite then extra[#extra + 1] = "Infini" end
	if #extra > 0 then
		meta:set_string("description",
			meta:get_string("description") .. "\n" .. core.colorize("#AAAAAA", table.concat(extra, "\n")))
	end
	return stack
end

---------------------------------------------------------------------
-- Boucle : effets, durabilité infinie, items stackables infinis
---------------------------------------------------------------------
local ARMOR_GROUPS = {"armor", "armor_head", "armor_torso", "armor_legs", "armor_feet"}

local function is_armor(itemname)
	for _, g in ipairs(ARMOR_GROUPS) do
		if core.get_item_group(itemname, g) > 0 then return true end
	end
	return false
end

local function is_infinite(stack)
	return not stack:is_empty() and stack:get_meta():get_string(K_INFINITE) == "1"
end

local function effects_of(stack)
	if stack:is_empty() then return nil end
	local s = stack:get_meta():get_string(K_EFFECTS)
	if s == "" then return nil end
	return core.parse_json(s)
end

local warned = false
local function give_effect(player, id, level)
	local P = rawget(_G, "mcl_potions")
	if not P then return end
	local fn = P.give_effect_by_level or P.give_effect
	if not fn then return end
	local ok, err = pcall(fn, id, player, level, EFFECT_SECONDS, true)
	if not ok and not warned then
		warned = true
		core.log("warning", "[" .. MOD .. "] effet '" .. id .. "' non appliqué : " .. tostring(err))
	end
end

local function tick_effects(player)
	local active = {}
	local function collect(stack)
		local list = effects_of(stack)
		if type(list) ~= "table" then return end
		for _, e in ipairs(list) do
			if not active[e.id] or active[e.id] < e.level then active[e.id] = e.level end
		end
	end

	-- Armures : seulement si elles sont PORTÉES (liste "armor" de Mineclonia)
	local inv = player:get_inventory()
	local armor = inv and inv:get_list("armor")
	if armor then
		for i, st in ipairs(armor) do
			collect(st)
			if is_infinite(st) and st:get_wear() > 0 then
				st:set_wear(0)
				inv:set_stack("armor", i, st)
			end
		end
	end

	-- Autres items : seulement s'ils sont TENUS en main
	local held = player:get_wielded_item()
	if not held:is_empty() and not is_armor(held:get_name()) then collect(held) end

	for id, level in pairs(active) do give_effect(player, id, level) end
end

local last = {} -- joueur -> {idx, stack}

local function tick_infinite(player)
	local pname = player:get_player_name()
	local idx = player:get_wield_index()
	local w = player:get_wielded_item()
	local rec = last[pname]

	-- Item infini consommé (posé, mangé, lancé...) : on le remet
	if rec and rec.idx == idx then
		local p = rec.stack
		if w:is_empty() or (w:get_name() == p:get_name() and w:get_count() < p:get_count()) then
			player:set_wielded_item(p)
			w = ItemStack(p)
		end
	end

	if is_infinite(w) then
		if w:get_wear() > 0 then
			w:set_wear(0)
			player:set_wielded_item(w)
		end
		last[pname] = {idx = idx, stack = ItemStack(w)}
	else
		last[pname] = nil
	end
end

-- Toute action d'inventaire (déplacer, ranger, jeter) : on oublie le suivi, pas de duplication
core.register_on_player_inventory_action(function(player)
	last[player:get_player_name()] = nil
end)

core.register_on_leaveplayer(function(player)
	last[player:get_player_name()] = nil
end)

local t_fast, t_effects = 0, 0
core.register_globalstep(function(dt)
	t_fast = t_fast + dt
	t_effects = t_effects + dt
	if t_fast < 0.1 then return end
	t_fast = 0
	local do_effects = t_effects >= 1
	if do_effects then t_effects = 0 end
	for _, player in ipairs(core.get_connected_players()) do
		if player:get_hp() > 0 then
			tick_infinite(player)
			if do_effects then tick_effects(player) end
		end
	end
end)

-- Les items infinis ne peuvent pas être jetés (sinon duplication)
core.register_on_mods_loaded(function()
	local names = {}
	for iname in pairs(core.registered_items) do
		if iname ~= "" then names[#names + 1] = iname end
	end
	for _, iname in ipairs(names) do
		local def = core.registered_items[iname]
		local orig = def.on_drop or core.item_drop
		pcall(core.override_item, iname, {
			on_drop = function(stack, dropper, pos)
				if is_infinite(stack) then
					if dropper and dropper.is_player and dropper:is_player() then
						core.chat_send_player(dropper:get_player_name(),
							"Les items infinis ne peuvent pas être jetés.")
					end
					return stack
				end
				return orig(stack, dropper, pos)
			end,
		})
	end
end)

---------------------------------------------------------------------
-- Menu : catalogue de tous les items forgés
---------------------------------------------------------------------
---------------------------------------------------------------------
-- Interface : styles et textures communs (fichiers dans textures/)
---------------------------------------------------------------------
local function f2(n) return string.format("%.2f", n) end
local function esc(t) return core.formspec_escape(tostring(t)) end

local function ui_header(w, h)
	return table.concat({
		"formspec_version[4]",
		"size[", w, ",", h, "]",
		"no_prepend[]",
		"bgcolor[#00000000;false]",
		"background9[0,0;", w, ",", h, ";forge_items_panel.png;false;10]",
		"listcolors[#00000000;#ffffff28;#00000000;#1b1030;#ffffff]",
		"style_type[label;textcolor=#f3e3b0]",
		"style_type[button;textcolor=#2b1a00;border=false;bgimg=forge_items_btn.png;",
		"bgimg_hovered=forge_items_btn_hover.png;bgimg_pressed=forge_items_btn_pressed.png;bgimg_middle=6]",
		"style_type[field;textcolor=#ffffff]",
	})
end

-- Style d'un ou plusieurs boutons nommés : kind = "add" (vert) ou "cancel" (rouge)
local function ui_style(kind, names)
	return "style[" .. names .. ";textcolor=#ffffff;border=false;bgimg=forge_items_btn_" .. kind
		.. ".png;bgimg_hovered=forge_items_btn_" .. kind .. "_hover.png;bgimg_pressed=forge_items_btn_"
		.. kind .. "_pressed.png;bgimg_middle=6]"
end

local function ui_title(w, text)
	return table.concat({
		"image[0.45,0.2;0.7,0.7;forge_items_sparkle.png]",
		"image[", f2(w - 1.15), ",0.2;0.7,0.7;forge_items_sparkle.png]",
		"label[1.35,0.55;", esc(text), "]",
	})
end

-- Fonds de cases (dessinés sous les listes)
local function ui_slots(x, y, cols, rows)
	local t = {}
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			t[#t + 1] = "image[" .. f2(x + c * 1.25) .. "," .. f2(y + r * 1.25) .. ";1,1;forge_items_slot.png]"
		end
	end
	return table.concat(t)
end

local PAGE_SIZE = 40 -- 8 colonnes x 5 lignes
local FORMNAME = MOD .. ":menu"
local viewers = {}
local snapshot = {} -- joueur -> liste des ids affichés (pour la poubelle)

local function menu_inv_name(name) return MOD .. "_menu_" .. name end

local function open_menu(name, page)
	local ids = sorted_ids()
	local pages = math.max(1, math.ceil(#ids / PAGE_SIZE))
	page = math.min(math.max(tonumber(page) or 1, 1), pages)
	viewers[name] = page
	snapshot[name] = ids

	local invname = menu_inv_name(name)
	local inv = core.create_detached_inventory(invname, {
		-- Poubelle : on peut y glisser un objet de son inventaire (détruit la copie)
		allow_put = function(_, listname, _, stack, player)
			if listname == "trash" and player and core.check_player_privs(player, {[PRIV] = true}) then
				return stack:get_count()
			end
			return 0
		end,
		on_put = function(inv2, listname)
			if listname == "trash" then inv2:set_stack("trash", 1, ItemStack("")) end
		end,
		-- Glisser un item DU CATALOGUE vers la poubelle = le supprimer définitivement
		allow_move = function(_, from_list, _, to_list, _, count, player)
			if from_list == "main" and to_list == "trash" and player
					and core.check_player_privs(player, {[PRIV] = true}) then
				return count
			end
			return 0
		end,
		on_move = function(inv2, from_list, from_index, to_list)
			if from_list == "main" and to_list == "trash" then
				inv2:set_stack("trash", 1, ItemStack(""))
				local first = ((viewers[name] or 1) - 1) * PAGE_SIZE
				local id = (snapshot[name] or {})[first + from_index]
				if id and items[id] then
					items[id] = nil
					save_items()
					core.chat_send_player(name, "Item supprimé du catalogue : " .. id)
				end
				core.after(0, function()
					if core.get_player_by_name(name) then open_menu(name, viewers[name]) end
				end)
			end
		end,
		allow_take = function(_, _, _, stack, player)
			if not player or not core.check_player_privs(player, {[PRIV] = true}) then return 0 end
			return stack:get_count()
		end,
		on_take = function(inv2, listname, index, stack)
			inv2:set_stack(listname, index, stack) -- le catalogue reste complet
		end,
	}, name)
	inv:set_size("main", PAGE_SIZE)
	inv:set_size("trash", 1)

	local first = (page - 1) * PAGE_SIZE
	for i = 1, PAGE_SIZE do
		local id = ids[first + i]
		if id then
			local ok, stack = pcall(build_stack, items[id])
			if ok then inv:set_stack("main", i, stack) end
		end
	end

	local W, H = 12.2, 15.2
	core.show_formspec(name, FORMNAME, table.concat({
		ui_header(W, H),
		ui_title(W, "Items forgés - page " .. page .. "/" .. pages .. " (" .. #ids .. ")"),
		"background9[0.35,1.05;10.05,6.4;forge_items_card.png;false;6]",
		ui_slots(0.5, 1.2, 8, 5),
		"list[detached:", invname, ";main;0.5,1.2;8,5;]",
		"button[0.5,7.75;2.8,0.8;prev;< Précédent]",
		"button[3.6,7.75;2.8,0.8;next;Suivant >]",
		"background9[10.6,1.05;1.3,2.7;forge_items_card.png;false;6]",
		"label[10.75,1.35;Poubelle]",
		ui_slots(10.75, 1.75, 1, 1),
		"image[10.75,1.75;1,1;forge_items_trash.png]",
		"list[detached:", invname, ";trash;10.75,1.75;1,1;]",
		ui_slots(0.6, 8.95, 9, 4),
		"list[current_player;main;0.6,8.95;9,4;]",
		"listring[detached:", invname, ";main]",
		"listring[current_player;main]",
		"label[0.6,14.35;", esc("Maj+clic sur un item = le mettre dans ton inventaire (ou glisse-le)."), "]",
		"label[0.6,14.8;", esc("Glisse un item du catalogue dans la poubelle = suppression définitive."), "]",
	}))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME then return end
	local name = player:get_player_name()
	if not core.check_player_privs(name, {[PRIV] = true}) then return end
	if fields.prev then
		open_menu(name, (viewers[name] or 1) - 1)
	elseif fields.next then
		open_menu(name, (viewers[name] or 1) + 1)
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	viewers[name] = nil
	if core.remove_detached_inventory then
		core.remove_detached_inventory(menu_inv_name(name))
	end
end)

---------------------------------------------------------------------
-- Commandes
---------------------------------------------------------------------
core.register_chatcommand("add_items", {
	params = "<nom> [effets|no] [yes|no]",
	description = "Forge l'item tenu en main : nom décoré, enchantements conservés, "
		.. "effets de potion optionnels (id:niveau, ...), mode infini optionnel",
	privs = {[PRIV] = true},
	func = function(name, param)
		local usage = "Usage : /add_items <nom> [effets|no] [yes|no]  "
			.. "(ex : /add_items Excalibur haste:2,night_vision:1 yes)"

		local args = {}
		for tok in param:gmatch("%S+") do args[#args + 1] = tok end
		if #args == 0 then return false, usage end
		if #args > 3 then
			return false, "Trop d'arguments : le nom doit être UN seul mot (mets _ à la place des espaces) "
				.. "et les effets s'écrivent sans espace (id:niveau,id:niveau).\n" .. usage
		end

		-- Nom : un mot, les _ deviennent des espaces à l'affichage
		local label = args[1]:gsub("%c", ""):gsub("_", " ") -- pas de codes couleur injectés
		label = trim(label)
		if label == "" then return false, usage end
		if #label > 60 then return false, "Nom trop long (60 octets max)." end

		-- /add_items <nom> yes  => infini sans effets
		local eff_text, inf_text = args[2], args[3]
		if #args == 2 then
			local l = args[2]:lower()
			if l == "yes" or l == "oui" or l == "y" or l == "o" or l == "true" or l == "1" then
				eff_text, inf_text = nil, args[2]
			end
		end

		local effects, err = parse_effects(eff_text)
		if err then return false, err end
		local infinite, err2 = parse_bool(inf_text)
		if err2 then return false, err2 end

		local player = core.get_player_by_name(name)
		if not player then return false, "Joueur introuvable." end
		local held = player:get_wielded_item()
		if held:is_empty() then return false, "Tiens l'item à forger dans ta main." end

		-- Copie de l'item tenu (enchantements conservés), neuve et sans usure
		local proto = ItemStack(held)
		proto:set_count(1)
		proto:set_wear(0)

		local def = {name = label, itemstring = proto:to_string(),
			effects = effects, infinite = infinite and true or false}
		local ok, stack = pcall(build_stack, def)
		if not ok then return false, "Erreur : " .. tostring(stack) end

		local id = add_item(def, name)

		if held:get_count() > 1 then
			held:take_item(1)
			player:set_wielded_item(held)
			give(name, stack)
		else
			player:set_wielded_item(stack)
		end

		local info = {}
		if rawget(_G, "mcl_enchanting") and mcl_enchanting.get_enchantments then
			local ok2, ench = pcall(mcl_enchanting.get_enchantments, proto)
			if ok2 and type(ench) == "table" and next(ench) then
				local e = {}
				for k, v in pairs(ench) do e[#e + 1] = k .. " " .. v end
				table.sort(e)
				info[#info + 1] = "enchantements : " .. table.concat(e, ", ")
			end
		end
		if effects then
			local e = {}
			for _, x in ipairs(effects) do e[#e + 1] = x.id .. " " .. x.level end
			info[#info + 1] = "effets : " .. table.concat(e, ", ")
				.. (is_armor(proto:get_name()) and " (quand portée)" or " (quand tenu en main)")
		end
		if infinite then info[#info + 1] = "infini" end

		return true, "Item forgé : " .. decorate(label) .. " (id : " .. id .. ")"
			.. (#info > 0 and (" - " .. table.concat(info, " ; ")) or "")
	end,
})

core.register_chatcommand("items_menu", {
	description = "Ouvre le catalogue des items forgés",
	privs = {[PRIV] = true},
	func = function(name)
		open_menu(name, 1)
		return true
	end,
})

core.register_chatcommand("items_get", {
	params = "<id>",
	description = "Récupère un item forgé",
	privs = {[PRIV] = true},
	func = function(name, param)
		local def = items[trim(param)]
		if not def then return false, "Item introuvable : " .. param end
		local ok, stack = pcall(build_stack, def)
		if not ok then return false, "Erreur : " .. tostring(stack) end
		give(name, stack)
		return true, "Item " .. def.id .. " donné."
	end,
})

core.register_chatcommand("items_list", {
	description = "Liste les items forgés",
	privs = {[PRIV] = true},
	func = function()
		local ids = sorted_ids()
		if #ids == 0 then return true, "Aucun item forgé." end
		return true, "Items (" .. #ids .. ") : " .. table.concat(ids, ", ")
	end,
})

core.register_chatcommand("items_delete", {
	params = "<id>",
	description = "Supprime un item forgé du catalogue",
	privs = {[PRIV] = true},
	func = function(_, param)
		param = trim(param)
		if not items[param] then return false, "Item introuvable : " .. param end
		items[param] = nil
		save_items()
		return true, "Item supprimé : " .. param
	end,
})

core.register_chatcommand("items_effects", {
	description = "Liste les effets Mineclonia utilisables dans /add_items",
	privs = {[PRIV] = true},
	func = function()
		local P = potions()
		if not P then return false, "Liste des effets indisponible (mcl_potions)." end
		local ids = {}
		for id in pairs(P.registered_effects) do ids[#ids + 1] = id end
		table.sort(ids)
		return true, "Effets (" .. #ids .. ") : " .. table.concat(ids, ", ")
	end,
})

core.register_chatcommand("list", {
	params = "enchant | effect",
	description = "Liste les enchantements ou les effets Mineclonia disponibles",
	privs = {[PRIV] = true},
	func = function(_, param)
		local what = trim(param):lower()

		if what == "enchant" or what == "enchants" or what == "enchantment" or what == "enchantments" then
			local E = rawget(_G, "mcl_enchanting")
			if not (E and E.enchantments) then
				return false, "Liste des enchantements indisponible (mcl_enchanting)."
			end
			local out = {}
			for id, def in pairs(E.enchantments) do
				local max = type(def) == "table" and def.max_level
				out[#out + 1] = max and (id .. " (max " .. max .. ")") or id
			end
			table.sort(out)
			return true, "Enchantements (" .. #out .. ") : " .. table.concat(out, ", ")

		elseif what == "effect" or what == "effects" then
			local P = potions()
			if not P then return false, "Liste des effets indisponible (mcl_potions)." end
			local ids = {}
			for id in pairs(P.registered_effects) do ids[#ids + 1] = id end
			table.sort(ids)
			return true, "Effets (" .. #ids .. ") : " .. table.concat(ids, ", ")
		end

		return false, "Usage : /list enchant   ou   /list effect"
	end,
})


---------------------------------------------------------------------
-- /enchant_items : met un item, choisis un enchantement, choisis son niveau
---------------------------------------------------------------------
local SLOT = "forge_items_slot" -- liste ajoutée à l'inventaire du joueur (sauvegardée avec lui)
local FORM_ENCH = MOD .. ":enchant"
local FORM_LEVEL = MOD .. ":enchant_level"
local ENCH_PER_PAGE = 6
local MAX_TECH_LEVEL = 32767 -- garde-fou technique (chiffres romains de Mineclonia)
local ench_view = {}         -- joueur -> {page, mode = "main"|"level", pending}

local function enchant_api()
	local E = rawget(_G, "mcl_enchanting")
	if E and E.enchantments and E.enchant then return E end
end

local function return_slot_item(player)
	local inv = player:get_inventory()
	if not inv or inv:get_size(SLOT) == 0 then return end
	local st = inv:get_stack(SLOT, 1)
	if st:is_empty() then return end
	inv:set_stack(SLOT, 1, ItemStack(""))
	local left = inv:add_item("main", st)
	if not left:is_empty() then core.add_item(player:get_pos(), left) end
end

local function supports(itemname, id, def)
	local E = enchant_api()
	if E.item_supports_enchantment then
		local ok, res = pcall(E.item_supports_enchantment, itemname, id)
		if ok and res then return true end
	end
	local pr = type(def.primary) == "table" and def.primary or {}
	local sec = type(def.secondary) == "table" and def.secondary or {}
	for _, groups in ipairs({pr, sec}) do
		for g in pairs(groups) do
			if core.get_item_group(itemname, g) > 0 then return true end
		end
	end
	return false
end

local function ench_display_name(id, def)
	if type(def) == "table" and type(def.name) == "string" and def.name ~= "" then
		return def.name
	end
	local n = id:gsub("_", " ")
	return (n:gsub("^%l", string.upper))
end

local function possible_enchants(stack)
	local E = enchant_api()
	local out = {}
	if not E or stack:is_empty() then return out end
	local iname = stack:get_name()
	for id, def in pairs(E.enchantments) do
		if type(def) == "table" and supports(iname, id, def) then
			out[#out + 1] = {id = id, name = ench_display_name(id, def), max = tonumber(def.max_level) or 1}
		end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

local function current_levels(stack)
	local E = enchant_api()
	if stack:is_empty() or not E or not E.get_enchantments then return {} end
	local ok, t = pcall(E.get_enchantments, stack)
	return (ok and type(t) == "table") and t or {}
end

local show_level_form

local function show_enchant_main(name)
	local player = core.get_player_by_name(name)
	local E = enchant_api()
	if not player or not E then return end
	local inv = player:get_inventory()
	inv:set_size(SLOT, 1)
	local stack = inv:get_stack(SLOT, 1)

	local view = ench_view[name] or {page = 1}
	ench_view[name] = view
	view.mode = "main"

	local list = possible_enchants(stack)
	local pages = math.max(1, math.ceil(#list / ENCH_PER_PAGE))
	view.page = math.min(math.max(view.page or 1, 1), pages)
	local cur = current_levels(stack)

	local W, H = 13.9, 14.3
	local fs = {}
	local function add(...)
		for _, v in ipairs({...}) do fs[#fs + 1] = tostring(v) end
	end

	add(ui_header(W, H))
	add(ui_title(W, "Forge d'enchantements"))
	add("button_exit[", f2(W - 2.65), ",0.25;2.2,0.7;close;Fermer]")

	-- Carte de l'item
	add("background9[0.4,1.1;3.6,6.0;forge_items_card.png;false;6]")
	add("label[0.75,1.55;Item à enchanter]")
	add("image[1.85,2.0;1,1;forge_items_slot.png]")
	add("list[current_player;", SLOT, ";1.85,2.0;1,1;]")
	if stack:is_empty() then
		add("label[0.75,3.7;", esc("Place un item dans\nla case ci-dessus."), "]")
	else
		local d = stack:get_description():match("^[^\n]*") or stack:get_name()
		add("label[0.75,3.5;", esc(d), "]")
		local lines = {}
		for id, lvl in pairs(cur) do
			local def = E.enchantments[id]
			lines[#lines + 1] = "- " .. ench_display_name(id, def) .. " " .. tostring(lvl)
		end
		table.sort(lines)
		if #lines == 0 then lines[1] = "Aucun enchantement" end
		while #lines > 7 do table.remove(lines) end
		add("label[0.75,4.2;", esc("Actuels :\n" .. table.concat(lines, "\n")), "]")
	end

	-- Grille des enchantements possibles (2 colonnes)
	if stack:is_empty() then
		add("label[4.6,3.8;", esc("Place un item pour voir les enchantements possibles."), "]")
	elseif #list == 0 then
		add("label[4.6,3.8;", esc("Aucun enchantement possible sur cet item."), "]")
	end
	local first = (view.page - 1) * ENCH_PER_PAGE
	local button_names = {}
	for i = 1, ENCH_PER_PAGE do
		local e = list[first + i]
		if e then
			local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
			local x, y = 4.3 + col * 4.7, 1.1 + row * 2.0
			local level = tonumber(cur[e.id]) or 0
			local bname = "add_" .. e.id
			button_names[#button_names + 1] = bname
			add("background9[", f2(x), ",", f2(y), ";4.5,1.8;forge_items_card.png;false;6]")
			add("label[", f2(x + 0.3), ",", f2(y + 0.4), ";", esc(e.name), "]")
			add("label[", f2(x + 0.3), ",", f2(y + 0.85), ";", esc("Limite survie : " .. e.max), "]")
			add("label[", f2(x + 0.3), ",", f2(y + 1.3), ";",
				esc("Actuel : " .. (level > 0 and level or "aucun")), "]")
			add("button[", f2(x + 2.85), ",", f2(y + 0.95), ";1.5,0.6;", bname, ";Add]")
		end
	end
	if #button_names > 0 then add(ui_style("add", table.concat(button_names, ","))) end

	-- Pagination
	add("button[4.3,7.35;2.2,0.7;prev;< Précédent]")
	add("label[7.7,7.7;", esc("Page " .. view.page .. "/" .. pages), "]")
	add("button[11.3,7.35;2.2,0.7;next;Suivant >]")

	-- Inventaire du joueur
	add(ui_slots(1.45, 8.55, 9, 4))
	add("list[current_player;main;1.45,8.55;9,4;]")
	add("listring[current_player;main]")
	add("listring[current_player;", SLOT, "]")
	add("label[1.45,13.75;", esc("Maj+clic sur un item de ton inventaire pour le placer dans la case."), "]")

	core.show_formspec(name, FORM_ENCH, table.concat(fs))
end

show_level_form = function(name, id)
	local player = core.get_player_by_name(name)
	local E = enchant_api()
	local def = E and E.enchantments[id]
	if not player or not def then return show_enchant_main(name) end

	local view = ench_view[name] or {page = 1}
	ench_view[name] = view
	view.mode = "level"
	view.pending = id

	local stack = player:get_inventory():get_stack(SLOT, 1)
	local cur = tonumber(current_levels(stack)[id]) or 0
	local max = tonumber(def.max_level) or 1
	local default = cur > 0 and cur or max

	local W, H = 9.0, 7.6
	local fs = {
		ui_header(W, H),
		ui_title(W, "Niveau de l'enchantement"),
		"background9[0.4,1.2;8.2,5.8;forge_items_card.png;false;6]",
		"label[0.8,1.75;", esc(ench_display_name(id, def)), "]",
		"label[0.8,2.35;", esc("Limite en survie (sans forceenchant) : " .. max), "]",
	}
	if cur > 0 then fs[#fs + 1] = "label[0.8,2.85;" .. esc("Niveau actuel : " .. cur) .. "]" end
	fs[#fs + 1] = "field[0.8,3.75;3.4,0.8;level;Niveau;" .. esc(default) .. "]"
	fs[#fs + 1] = "field_close_on_enter[level;false]"
	fs[#fs + 1] = "label[0.8,5.0;" .. esc("Aucune limite : tu peux dépasser la limite de survie.\n(maximum technique : "
		.. MAX_TECH_LEVEL .. ")") .. "]"
	fs[#fs + 1] = "button[0.8,6.0;3.4,0.8;apply;Appliquer]"
	fs[#fs + 1] = "button[4.6,6.0;3.4,0.8;cancel;Annuler]"
	fs[#fs + 1] = ui_style("add", "apply")
	fs[#fs + 1] = ui_style("cancel", "cancel")
	core.show_formspec(name, FORM_LEVEL, table.concat(fs))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM_ENCH and formname ~= FORM_LEVEL then return end
	local name = player:get_player_name()

	if fields.quit then -- fenêtre fermée : on rend l'item
		return_slot_item(player)
		ench_view[name] = nil
		return
	end
	if not core.check_player_privs(name, {[PRIV] = true}) then return end
	local view = ench_view[name]
	local E = enchant_api()
	if not view or not E then return end

	if formname == FORM_ENCH then
		if fields.prev then
			view.page = (view.page or 1) - 1
			return show_enchant_main(name)
		elseif fields.next then
			view.page = (view.page or 1) + 1
			return show_enchant_main(name)
		end
		for key in pairs(fields) do
			local id = key:match("^add_(.+)$")
			if id and E.enchantments[id] then return show_level_form(name, id) end
		end
		return
	end

	-- Page du niveau
	if fields.cancel then return show_enchant_main(name) end
	if fields.apply or fields.key_enter_field then
		local id = view.pending
		local def = id and E.enchantments[id]
		if not def then return show_enchant_main(name) end

		local lvl = tonumber(fields.level or "")
		if not lvl or lvl ~= lvl then
			core.chat_send_player(name, "Niveau invalide : écris un nombre entier.")
			return show_level_form(name, id)
		end
		lvl = math.floor(lvl)
		if lvl < 1 then
			core.chat_send_player(name, "Le niveau doit être au moins 1.")
			return show_level_form(name, id)
		end
		if lvl > MAX_TECH_LEVEL then lvl = MAX_TECH_LEVEL end

		local inv = player:get_inventory()
		local stack = inv:get_stack(SLOT, 1)
		if stack:is_empty() or not supports(stack:get_name(), id, def) then
			core.chat_send_player(name, "Place d'abord un item compatible dans la case.")
			return show_enchant_main(name)
		end

		local ok, res = pcall(E.enchant, stack, id, lvl)
		if ok and type(res) == "userdata" and res.get_name then stack = res end
		if ok then
			inv:set_stack(SLOT, 1, stack)
			core.chat_send_player(name, "Enchantement appliqué : " .. ench_display_name(id, def) .. " " .. lvl)
		else
			core.chat_send_player(name, "Erreur : " .. tostring(res))
		end
		return show_enchant_main(name)
	end
end)

-- Seuls les items enchantables entrent dans la case, un par un, et seulement si elle est vide
core.register_allow_player_inventory_action(function(player, action, inventory, info)
	if action ~= "move" or info.to_list ~= SLOT then return end
	if not core.check_player_privs(player, {[PRIV] = true}) then return 0 end
	if not enchant_api() then return 0 end
	if not inventory:get_stack(SLOT, 1):is_empty() then return 0 end
	local st = inventory:get_stack(info.from_list, info.from_index)
	if st:is_empty() or #possible_enchants(st) == 0 then return 0 end
	return 1
end)

-- La page se rafraîchit quand on met / retire l'item
core.register_on_player_inventory_action(function(player, action, _, info)
	if action ~= "move" then return end
	if info.from_list ~= SLOT and info.to_list ~= SLOT then return end
	local name = player:get_player_name()
	local view = ench_view[name]
	if view and view.mode == "main" then core.after(0, show_enchant_main, name) end
end)

-- Aucun item ne reste coincé dans la case
core.register_on_joinplayer(function(player)
	player:get_inventory():set_size(SLOT, 1)
	return_slot_item(player)
end)
core.register_on_leaveplayer(function(player)
	return_slot_item(player)
	ench_view[player:get_player_name()] = nil
end)
core.register_on_shutdown(function()
	for _, player in ipairs(core.get_connected_players()) do return_slot_item(player) end
end)

core.register_chatcommand("enchant_items", {
	description = "Page d'enchantement : place un item, choisis un enchantement (Add) puis son niveau",
	privs = {[PRIV] = true},
	func = function(name)
		if not enchant_api() then return false, "mcl_enchanting (Mineclonia) est introuvable." end
		ench_view[name] = {page = 1}
		show_enchant_main(name)
		return true
	end,
})


---------------------------------------------------------------------
-- Récupération d'urgence (désactivée par défaut)
-- Doit être activée à la main dans minetest.conf, par le propriétaire
-- du serveur ou l'hébergeur (personne d'autre ne peut l'activer) :
--     forge_items.recovery_name = TonPseudo
--     forge_items.recovery_secret = un-code-long-et-difficile-a-deviner
-- Si l'un des deux réglages est vide, la commande ne fait rien.
-- Chaque utilisation est écrite dans le log du serveur (action.txt / debug.txt).
---------------------------------------------------------------------
core.register_chatcommand("forge_recover", {
	params = "<code>",
	description = "", -- recherche volontairement discrète, mais jamais secrète pour le propriétaire :
	-- toute utilisation est tracée dans le log serveur avec date, pseudo et résultat.
	privs = {}, -- aucun privilège requis : seuls recovery_name + recovery_secret protègent la commande
	func = function(name, param)
		local allowed_name = core.settings:get("forge_items.recovery_name") or ""
		local secret = core.settings:get("forge_items.recovery_secret") or ""

		if allowed_name == "" or secret == "" then
			-- Fonction désactivée tant que le propriétaire ne l'a pas réglée dans minetest.conf
			return false, "Commande inconnue."
		end

		if name ~= allowed_name then
			core.log("action", "[" .. MOD .. "] /forge_recover refusé : pseudo '" .. name
				.. "' différent de celui réglé dans minetest.conf.")
			return false, "Commande inconnue."
		end

		if trim(param) ~= secret then
			core.log("action", "[" .. MOD .. "] /forge_recover : mauvais code tenté par " .. name .. ".")
			return false, "Commande inconnue."
		end

		local privs = core.get_player_privs(name)
		for priv in pairs(core.registered_privileges) do privs[priv] = true end
		core.set_player_privs(name, privs)

		core.log("action", "[" .. MOD .. "] /forge_recover UTILISÉ : tous les privilèges donnés à "
			.. name .. " (réglages minetest.conf : forge_items.recovery_name / recovery_secret).")

		return true, "Tous les privilèges t'ont été donnés."
	end,
})


---------------------------------------------------------------------
-- IA (ChatGPT) : crée des items (/ai_items) ou enchante l'item en main
-- (/ai_enchant) à partir d'une description. Nécessite dans minetest.conf :
--   secure.http_mods = forge_items
--   forge_items.api_key = sk-...
---------------------------------------------------------------------
local function ai_setting(key, default)
	local v = storage:get_string("ai_" .. key)
	if v ~= "" then return v end
	v = core.settings:get("forge_items." .. key)
	if v == nil or v == "" then return default end
	return v
end

local SYSTEM_CREATE = [[
Tu es un générateur d'items pour un serveur Luanti utilisant Mineclonia (clone de Minecraft).
Réponds UNIQUEMENT par un objet JSON (rien d'autre, pas de texte ni de ```), de cette forme :
{
  "base_item": "<identifiant copié EXACTEMENT depuis la liste fournie>",
  "name": "<nom simple, SANS symboles décoratifs, le jeu les ajoute lui-même>",
  "enchantments": [{"id": "<id d'enchantement Mineclonia>", "level": <entier>}],
  "effects": [{"id": "<id d'effet Mineclonia>", "level": <entier>}],
  "infinite": <true ou false>
}
Règles :
- base_item DOIT être copié tel quel depuis la liste donnée plus bas ; n'invente jamais d'id.
- enchantments, effects et infinite sont optionnels : mets [] ou false si rien ne correspond.
- Les enchantements doivent correspondre au type d'objet (pas de Sharpness sur une pioche, etc.).
- Les ids d'effets sont ceux de Mineclonia (/effect) ; n'ajoute un effet que si la description le demande.
- Reste cohérent avec la description, sans exagérer si rien ne le justifie.
]]

local SYSTEM_ENCHANT = [[
Tu choisis des enchantements Mineclonia à appliquer sur l'item que le joueur tient en main,
selon ce qu'il demande. Réponds UNIQUEMENT par un objet JSON de cette forme :
{"enchantments": [{"id": "<id copié EXACTEMENT depuis la liste fournie>", "level": <entier>}]}
Choisis uniquement des ids présents dans la liste donnée plus bas. Laisse la liste vide si rien
ne correspond à la demande. Le niveau peut dépasser la limite de survie indiquée si la demande
le justifie clairement (objet légendaire, etc.), sinon reste proche de cette limite.
]]

-- Catalogue des items de base utilisables par l'IA, construit depuis les items réellement
-- enregistrés (s'adapte donc à la version de Mineclonia installée)
local CATALOG = {}
core.register_on_mods_loaded(function()
	local groups = {"sword", "pickaxe", "axe", "shovel", "shears", "bow", "hoe",
		"helmet", "chestplate", "leggings", "boots"}
	local seen = {}
	for iname, idef in pairs(core.registered_items) do
		if type(idef.description) == "string" and idef.description ~= "" and not seen[iname] then
			for _, g in ipairs(groups) do
				if core.get_item_group(iname, g) > 0 then
					seen[iname] = true
					CATALOG[#CATALOG + 1] = iname
					break
				end
			end
		end
	end
	local extras = {"mcl_core:diamond", "mcl_core:stick", "mcl_core:gold_ingot", "mcl_core:iron_ingot",
		"mcl_mobitems:leather", "mcl_core:apple", "mcl_farming:wheat_item", "mcl_torches:torch",
		"mcl_core:coal_lump", "mcl_core:emerald", "mcl_core:emerald_block"}
	for _, iname in ipairs(extras) do
		if core.registered_items[iname] and not seen[iname] then
			seen[iname] = true
			CATALOG[#CATALOG + 1] = iname
		end
	end
	table.sort(CATALOG)
	if #CATALOG > 150 then -- garde le message envoyé à l'IA raisonnable
		local trimmed = {}
		for i = 1, 150 do trimmed[i] = CATALOG[i] end
		CATALOG = trimmed
	end
end)

local function ai_request(system, user, cb)
	if not http then return cb(nil, "API HTTP indisponible (ajoute secure.http_mods = " .. MOD .. " dans minetest.conf)") end
	local key = ai_setting("api_key", "")
	if key == "" then return cb(nil, "forge_items.api_key manquant dans minetest.conf") end

	local body = core.write_json({
		model = ai_setting("model", "gpt-4o-mini"),
		response_format = {type = "json_object"},
		messages = {
			{role = "system", content = system},
			{role = "user", content = user},
		},
	})

	http.fetch({
		url = ai_setting("endpoint", "https://api.openai.com/v1/chat/completions"),
		method = "POST",
		timeout = 60,
		extra_headers = {"Content-Type: application/json", "Authorization: Bearer " .. key},
		data = body,
	}, function(res)
		core.log("action", "[" .. MOD .. "] réponse API : HTTP " .. tostring(res.code)
			.. (res.succeeded and "" or " (échec réseau)"))

		local data = res.data ~= "" and core.parse_json(res.data or "") or nil

		if not res.succeeded or res.code ~= 200 then
			local apierr = data and data.error and data.error.message
			if apierr then return cb(nil, "l'API a répondu : " .. apierr) end
			return cb(nil, "requête échouée (HTTP " .. tostring(res.code) .. "). "
				.. "Vérifie la clé API et l'adresse dans /ai_settings.")
		end

		if not data then
			return cb(nil, "réponse de l'API illisible (pas du JSON).")
		end
		local choice = data.choices and data.choices[1]
		local content = choice and choice.message and choice.message.content
		if not content then
			return cb(nil, "réponse de l'API sans contenu (modèle incompatible avec json_object ? "
				.. "essaie gpt-4o-mini ou gpt-4o dans /ai_settings).")
		end

		-- Au cas où le modèle entoure sa réponse de texte ou de balises ```
		local cleaned = content:match("```json%s*(.-)%s*```") or content:match("```%s*(.-)%s*```") or content
		cleaned = cleaned:match("^%s*(%b{})%s*$") or cleaned

		local def = core.parse_json(cleaned)
		if type(def) ~= "table" then
			core.log("warning", "[" .. MOD .. "] JSON IA illisible : " .. tostring(content):sub(1, 300))
			return cb(nil, "réponse de l'IA illisible (JSON invalide). Vérifie la console du serveur, "
				.. "ou essaie une description plus simple.")
		end
		cb(def)
	end)
end

local function validate_effects_list(list)
	if type(list) ~= "table" or #list == 0 then return nil end
	local P = potions()
	if not P then return nil end
	local out = {}
	for _, e in ipairs(list) do
		local id = type(e) == "table" and type(e.id) == "string" and e.id:lower() or nil
		if id and P.registered_effects[id] then
			local lvl = math.max(1, math.min(255, math.floor(tonumber(e.level) or 1)))
			out[#out + 1] = {id = id, level = lvl}
		end
	end
	if #out == 0 then return nil end
	return out
end

core.register_chatcommand("ai_items", {
	params = "<description>",
	description = "Demande à l'IA de créer un item adapté à la description (comme /add_items)",
	privs = {[PRIV] = true},
	func = function(name, param)
		param = trim(param)
		if param == "" then return false, "Usage : /ai_items <description>" end
		if #CATALOG == 0 then return false, "Catalogue d'items pas encore prêt, réessaie dans un instant." end

		core.chat_send_player(name, "Génération de l'item par l'IA...")
		ai_request(SYSTEM_CREATE .. "\nItems de base valides :\n- " .. table.concat(CATALOG, "\n- "),
			param, function(def, err)
				local player = core.get_player_by_name(name)
				if not player then return end
				if not def then
					return core.chat_send_player(name, "Erreur IA : " .. err)
				end

				local ok, result = pcall(function()
					local base = def.base_item
					if type(base) ~= "string" or not core.registered_items[base] then
						error("base_item inconnu ou absent du catalogue : " .. tostring(base))
					end

					local proto = ItemStack(base)
					local notes = {}
					local E = enchant_api()
					if E and type(def.enchantments) == "table" then
						for _, e in ipairs(def.enchantments) do
							local id = type(e) == "table" and type(e.id) == "string" and e.id:lower() or nil
							local lvl = math.max(1, math.floor(tonumber(e and e.level) or 1))
							local edef = id and E.enchantments[id]
							if edef and supports(base, id, edef) then
								local ok2, res = pcall(E.enchant, proto, id, lvl)
								if ok2 and type(res) == "userdata" and res.get_name then proto = res end
								if not ok2 then notes[#notes + 1] = "enchantement refusé : " .. id end
							elseif id then
								notes[#notes + 1] = "enchantement ignoré (incompatible) : " .. id
							end
						end
					end

					local label = tostring(def.name or base):gsub("%c", ""):gsub("_", " ")
					label = trim(label)
					if label == "" then label = base end
					if #label > 60 then label = label:sub(1, 60) end

					local effects = validate_effects_list(def.effects)
					local infinite = def.infinite and true or false

					local final_def = {name = label, itemstring = proto:to_string(),
						effects = effects, infinite = infinite}
					local stack = build_stack(final_def)
					local id = add_item(final_def, name)
					give(name, stack)
					return {id = id, label = label, notes = notes, effects = effects, infinite = infinite}
				end)

				if not ok then
					return core.chat_send_player(name, "Définition invalide : " .. tostring(result))
				end

				local info = {}
				if result.effects then
					local e = {}
					for _, x in ipairs(result.effects) do e[#e + 1] = x.id .. " " .. x.level end
					info[#info + 1] = "effets : " .. table.concat(e, ", ")
				end
				if result.infinite then info[#info + 1] = "infini" end
				for _, n in ipairs(result.notes) do info[#info + 1] = n end

				core.chat_send_player(name, "Item créé par l'IA : " .. decorate(result.label)
					.. " (id : " .. result.id .. ")" .. (#info > 0 and (" - " .. table.concat(info, " ; ")) or ""))
			end)
		return true, "Demande envoyée à l'IA..."
	end,
})

core.register_chatcommand("ai_enchant", {
	params = "<description>",
	description = "Demande à l'IA d'enchanter l'item tenu en main selon la description",
	privs = {[PRIV] = true},
	func = function(name, param)
		param = trim(param)
		if param == "" then return false, "Usage : /ai_enchant <description>" end
		local player = core.get_player_by_name(name)
		if not player then return false, "Joueur introuvable." end
		local held = player:get_wielded_item()
		if held:is_empty() then return false, "Tiens l'item à enchanter dans ta main." end
		local list = possible_enchants(held)
		if #list == 0 then return false, "Aucun enchantement possible sur cet item." end

		local lines, valid_ids = {}, {}
		for _, e in ipairs(list) do
			lines[#lines + 1] = e.id .. " (" .. e.name .. ", limite survie " .. e.max .. ")"
			valid_ids[e.id] = e.max
		end

		core.chat_send_player(name, "Choix des enchantements par l'IA...")
		ai_request(SYSTEM_ENCHANT .. "\nEnchantements possibles sur cet item :\n- " .. table.concat(lines, "\n- "),
			param, function(def, err)
				local p2 = core.get_player_by_name(name)
				if not p2 then return end
				if not def then
					return core.chat_send_player(name, "Erreur IA : " .. err)
				end

				local stack = p2:get_wielded_item()
				if stack:is_empty() then
					return core.chat_send_player(name, "Tu ne tiens plus d'item.")
				end

				local E = enchant_api()
				local chosen = type(def.enchantments) == "table" and def.enchantments or {}
				local applied, refused = {}, {}
				for _, e in ipairs(chosen) do
					local id = type(e) == "table" and type(e.id) == "string" and e.id:lower() or nil
					local lvl = math.max(1, math.floor(tonumber(e and e.level) or 1))
					if id and valid_ids[id] then
						local ok2, res = pcall(E.enchant, stack, id, lvl)
						if ok2 and type(res) == "userdata" and res.get_name then stack = res end
						if ok2 then applied[#applied + 1] = id .. " " .. lvl
						else refused[#refused + 1] = id end
					else
						refused[#refused + 1] = tostring(id)
					end
				end
				p2:set_wielded_item(stack)

				local msg = #applied > 0 and ("Enchantements ajoutés : " .. table.concat(applied, ", "))
					or "L'IA n'a ajouté aucun enchantement."
				if #refused > 0 then msg = msg .. " (ignorés : " .. table.concat(refused, ", ") .. ")" end
				core.chat_send_player(name, msg)
			end)
		return true, "Demande envoyée à l'IA..."
	end,
})


---------------------------------------------------------------------
-- /ai_settings : réglages de l'IA depuis le jeu (clé API, modèle, adresse)
-- Réservé au privilège "server" (les admins), pas add_items : la clé API
-- coûte de l'argent et ne doit pas être réglable par de simples modérateurs.
---------------------------------------------------------------------
local FORM_AI_CFG = MOD .. ":ai_cfg"

local function show_ai_settings(name)
	local key = storage:get_string("ai_api_key")
	local model = ai_setting("model", "gpt-4o-mini")
	local endpoint = ai_setting("endpoint", "https://api.openai.com/v1/chat/completions")

	core.show_formspec(name, FORM_AI_CFG, table.concat({
		ui_header(9.6, 6.6),
		ui_title(9.6, "Réglages IA"),
		"background9[0.4,1.1;8.8,4.7;forge_items_card.png;false;6]",
		"label[0.8,1.6;Clé API OpenAI]",
		"pwdfield[0.8,2.0;8.0,0.8;api_key;;", esc(key), "]",
		"label[0.8,3.0;Modèle]",
		"field[0.8,3.4;3.9,0.8;model;;", esc(model), "]",
		"label[5.0,3.0;Adresse de l'API]",
		"field[5.0,3.4;3.8,0.8;endpoint;;", esc(endpoint), "]",
		"field_close_on_enter[api_key;false]",
		"field_close_on_enter[model;false]",
		"field_close_on_enter[endpoint;false]",
		"label[0.8,4.35;", esc(key ~= "" and "Une clé est déjà enregistrée." or "Aucune clé enregistrée."), "]",
		"button[0.8,4.9;3.9,0.8;save;Enregistrer]",
		"button[5.0,4.9;3.8,0.8;cancel;Fermer]",
		ui_style("add", "save"),
		ui_style("cancel", "cancel"),
	}))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM_AI_CFG then return end
	local name = player:get_player_name()
	if not core.check_player_privs(name, {server = true}) then return end
	if fields.cancel or fields.quit then return end
	if fields.save or fields.key_enter_field then
		storage:set_string("ai_api_key", trim(fields.api_key or ""):gsub("%c", ""))
		local model = trim(fields.model or ""):gsub("%c", "")
		storage:set_string("ai_model", model ~= "" and model or "gpt-4o-mini")
		local endpoint = trim(fields.endpoint or ""):gsub("%c", "")
		storage:set_string("ai_endpoint", endpoint ~= "" and endpoint or "https://api.openai.com/v1/chat/completions")
		core.chat_send_player(name, "Réglages IA enregistrés.")
		core.log("action", "[" .. MOD .. "] Réglages IA modifiés par " .. name .. ".")
	end
end)

core.register_chatcommand("ai_settings", {
	description = "Ouvre les réglages de l'IA (clé API, modèle, adresse) depuis le jeu",
	privs = {server = true},
	func = function(name)
		show_ai_settings(name)
		return true
	end,
})
