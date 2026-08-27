--[[
	BidSniper - what a craft costs to make, and what it is worth

	Three things have to come together for that sum, and this file is mostly
	about getting each of them for nothing.

	The recipes come from your own tradeskill window. There is no way to ask the
	client what a character can make without that window being open, so it is
	read once while it is open and kept through logging out. Open the profession,
	close it, and the list stays.

	The prices come from the scan you were running anyway. A sweep of the auction
	house reads every row on its way past, and checking each one against a set of
	reagent names costs a single hash lookup - the same trick the bid ledger uses
	to settle bids for free. Nothing here ever asks the server for anything.

	The honesty comes from saying which is which. A price read out of the scan
	you just ran is what the item costs right now; a price from Auctionator's
	database is whatever it was when Auctionator last looked, and a reagent that
	nobody is selling has no price at all. A sum built on the first is exact. A
	sum built on either of the others is an estimate and says so, and says which
	reagent made it one.

	--------------------------------------------------------------- two of them

	The same three questions are worth asking of more than one profession, so the
	machinery is asked once and pointed at a profession rather than written
	twice. A profession is a small table: which tradeskill window feeds it, which
	of the things that window makes are worth costing, which of its reagents come
	off a vendor, and where its recipe book and its planned quantities are kept.

	Two live here. Alchemy costs out flasks and elixirs, because those are the
	things an alchemist makes to sell. Leatherworking costs out everything its
	window makes, because a leatherworker's window is full of exactly the sort of
	thing this is for: leg armours, armour kits, bags, gear, and the intermediate
	leather that half of it is built from.

	Recipe books and planned quantities are kept apart, one set per profession.
	Prices are not. A price is a fact about an item and not about a trade, and
	Borean Leather costs what it costs whoever is asking - so one scan prices
	both books at once and neither has to be scanned for separately.
]]

local BS = BidSniper
if not BS then return end

local floor, format, sort = math.floor, string.format, table.sort

--=============================================================================
--  professions, and what you are looking at them for
--=============================================================================

--[[
	Two separate ideas, kept separate on purpose.

	A **profession** is a fact about a trade: which tradeskill window feeds it,
	which of the things that window makes are worth costing, which of its reagents
	come off a vendor, and where its recipe book lives. Nothing about a profession
	says why you care about it.

	A **mode** is why you care. "What would making this earn me" and "what is the
	cheapest way to buy a skill point" are different questions about the same
	recipe, and they want different columns, a different order, and a different
	idea of which rows are worth showing at all. The arithmetic underneath is the
	same either way - it is the reading of it that differs.

	A page is one of each, and the pairing is free. A profession lists the modes
	it is offered in, so leatherworking can be a training page today and a profit
	page as well tomorrow by adding one key. Adding a profession is one table;
	adding a mode is one table. Nothing in the page code knows the name of any
	profession, and nothing in a profession knows the name of any column.
]]

BS.Professions = {}		-- id -> profession
BS.ProfOrder   = {}		-- registration order
BS.Modes       = {}		-- id -> mode
BS.ModeOrder   = {}		-- the order they appear as tabs

local function AddProfession(p)
	BS.Professions[p.id]            = p
	BS.ProfOrder[#BS.ProfOrder + 1] = p
	return p
end

local function AddMode(m)
	BS.Modes[m.id]                  = m
	BS.ModeOrder[#BS.ModeOrder + 1] = m
	return m
end

--=============================================================================
--  the trades
--=============================================================================

--[[
	Alchemy: flasks and elixirs, and nothing else the window can make.

	The client's own subclass for the crafted item decides that, rather than a
	list of names that would go stale. A transmute makes a Trade Goods and a
	bandage is First Aid, and neither is a thing you stand at the auction house
	deciding whether to make.
]]
AddProfession{
	id         = "alchemy",
	label      = "Flasks",		-- the selector button
	title      = "Flasks and elixirs",
	window     = "alchemy",
	makes      = "flask and elixir",
	modes      = { profit = true },
	trade      = { ["Alchemy"] = true },
	subTypes   = { ["Flask"] = true, ["Elixir"] = true },
	recipesKey = "recipes",
	wantKey    = "craftWant",
	--[[
		Vials come off a vendor at a fixed few silver, so they are left out of
		the cost: a shopping trip is not an auction house decision and pretending
		it is only muddies what a craft is really worth. They are still counted,
		because you cannot make a flask without one and the whole point of the
		list is to leave the auction house knowing what else to go and buy.
	]]
	vendor = {
		["Crystal Vial"] = true,
		["Imbued Vial"]  = true,
		["Leaded Vial"]  = true,
		["Empty Vial"]   = true,
	},
	vendorOne  = "vial",
	vendorMany = "vials",
}

--[[
	Leatherworking: everything the window makes, and no subclass filter at all.

	Alchemy can be filtered because an alchemist's window is mostly things nobody
	trades. A leatherworker's is the opposite - leg armours, armour kits, bags,
	drums, leather and mail gear, and the intermediate leather half of the rest is
	built out of - and every one of those is something you might make. Filtering
	that by subclass would mean picking, in advance, which of them you were
	allowed to ask about.

	It matters most for levelling. What is cheapest to train on is very often an
	intermediate or a plain piece of armour nobody would ever buy, and a filter
	that kept only the saleable things would hide exactly the rows a leatherworker
	working up through the ranks wants to see.
]]
AddProfession{
	id         = "leather",
	label      = "Leather",
	title      = "Leatherworking",
	window     = "leatherworking",
	makes      = "leatherworking",
	modes      = { training = true },
	trade      = { ["Leatherworking"] = true },
	subTypes   = nil,		-- everything the window makes
	recipesKey = "lwRecipes",
	wantKey    = "lwWant",
	--[[
		The leatherworking supply vendor's shelf, by name.

		There is no API that says "a vendor sells this", so this is a list, and a
		list is a thing that can be wrong. It is wrong in the safe direction on
		purpose: anything not named here is treated as something you have to buy
		from other players, which at worst overstates what a craft costs. Getting
		it wrong the other way - calling an auction house item free - would put the
		wrong recipe at the top of the page, which is the one thing it exists to
		get right.

		So it is the six threads and the salt, which every leatherworker has bought
		a hundred of, and nothing that is merely cheap. The dyes are deliberately
		left off: they are vendor goods in most of the world, but they are also
		traded, and they turn up in tailoring far more than here.

		/snipe vendor <item> settles any argument with this list on your realm
		without editing the file.
	]]
	vendor = {
		["Coarse Thread"]       = true,
		["Fine Thread"]         = true,
		["Silken Thread"]       = true,
		["Heavy Silken Thread"] = true,
		["Rune Thread"]         = true,
		["Eternium Thread"]     = true,
		["Salt"]                = true,
	},
	vendorOne  = "vendor item",
	vendorMany = "vendor items",
}

--=============================================================================
--  difficulty: whether making it would still teach you anything
--=============================================================================

--[[
	It comes free with the recipe. GetTradeSkillInfo's second return is the very
	word the tradeskill window colours its rows by, and this file was already
	reading it - to tell a header from a recipe - and then throwing it away.

	The colours are Blizzard's own values, copied rather than read, because
	TradeSkillTypeColor lives in Blizzard_TradeSkillUI: a load-on-demand addon
	that does not exist until the first time you open a tradeskill window. If it
	has been loaded, the live table is preferred, so a client that recoloured
	these stays consistent with itself.

	`chance` is roughly how often a craft of that colour gives a skill point. The
	client does not publish the real curve, so it is an approximation, and the
	one every crafting addon uses. It is exactly good enough for the job it has,
	which is putting the cheapest way to level at the top of a list.

	The colour is a snapshot, and it goes stale in one direction only. Skill goes
	up, so a recipe recorded as orange can be yellow by now but never the reverse
	- so the error always runs towards offering you something that no longer
	levels you, and never towards hiding one that would. Every harvest rewrites
	it, and a harvest happens every time the window is opened.
]]
BS.Difficulty = {
	optimal = { rank = 4, chance = 1.00, r = 1.00, g = 0.50, b = 0.25, hex = "ff8040",
	            label = "orange", says = "almost always a skill point" },
	medium  = { rank = 3, chance = 0.75, r = 1.00, g = 1.00, b = 0.00, hex = "ffff00",
	            label = "yellow", says = "usually a skill point" },
	easy    = { rank = 2, chance = 0.25, r = 0.25, g = 0.75, b = 0.25, hex = "40bf40",
	            label = "green",  says = "sometimes a skill point" },
	trivial = { rank = 1, chance = 0.00, r = 0.50, g = 0.50, b = 0.50, hex = "808080",
	            label = "grey",   says = "never a skill point" },
}

-- returns r, g, b and the entry itself; nil for a recipe read before this was
-- recorded, which is not the same as one that cannot level you
function BS.DiffColour(kind)
	local d = BS.Difficulty[kind or ""]
	if not d then return nil end

	local live = TradeSkillTypeColor and TradeSkillTypeColor[kind]
	if live and live.r then return live.r, live.g, live.b, d end
	return d.r, d.g, d.b, d
end

-- the same colour as six hex digits, for colouring text with |cff
function BS.DiffHex(kind)
	local d = BS.Difficulty[kind or ""]
	if not d then return nil end

	local live = TradeSkillTypeColor and TradeSkillTypeColor[kind]
	if live and live.r then
		-- rounded rather than truncated, so a live table that happens to hold
		-- Blizzard's own values comes back as Blizzard's own hex
		return format("%02x%02x%02x", floor(live.r * 255 + 0.5),
			floor(live.g * 255 + 0.5), floor(live.b * 255 + 0.5))
	end
	return d.hex
end

--=============================================================================
--  the modes: the same sums, read for different reasons
--=============================================================================

--[[
	A mode owns five of the six columns and says how to fill them.

	The first column is always the recipe and the Want box is always in the same
	place, because those are the two things every reading of a recipe has in
	common. Everything between them belongs to the mode, geometry included, so a
	new mode is a table here and nothing at all in the page code.
]]

local function CanMakeCell(c)
	return (c.canMake or 0) > 0 and ("|cff00ff00" .. c.canMake .. "|r") or "|cff6666660|r"
end

--[[
	Nothing listed is the thing worth noticing, so it is the thing that gets a
	colour. A dash means the auction house has not told us yet, which is not the
	same as none and must not read like it.
]]
local function OnAuctionCell(c)
	if c.onAuction == nil then return "|cff666666-|r" end
	if c.onAuction == 0   then return "|cffff88000|r" end
	return "|cffffffff" .. c.onAuction .. "|r"
end

--[[
	How many finished ones you are already carrying.

	The page could say what you can make and what is listed, and had no way of
	saying what you already have - so "did that batch actually get made" was a
	question you answered by opening your bags and counting. Against Can make it
	is the whole picture in two numbers: what is done, and what is still in you.

	Bags only, and the bank goes in the tooltip beside it. That is the same rule
	the shopping list works to and for the same reason: a stack two rooms away
	is not one you are about to post, and a page that quietly counted it would
	be planning your walk for you.
]]
local function HaveCell(c)
	local bags = BS.ReagentHave(c)
	if not bags or bags <= 0 then return "|cff6666660|r" end
	return "|cffffffff" .. bags .. "|r"
end

--[[
	What the reagents come to, and whether that figure is firm.

	The estimate mark sits on the money, because the money is the thing being
	estimated - a recipe is not an estimate, its price is. It used to be carried
	by the colour of the recipe's name, which now says how hard the recipe is
	instead; one word cannot honestly say two things at once, and of the two, the
	one that belongs on the name is the one about the recipe.

	A tilde rather than a colour because BS.Money writes its own colour codes for
	gold, silver and copper, and an outer colour would be reset by the first of
	them and show on none of the digits.
]]
local function CostCell(c)
	if c.exact then return BS.Money(c.cost) end
	return "|cffff8800~|r" .. BS.Money(c.cost)
end

-- 0.75 rather than 0.75000, and 1 rather than 1.00
local function PointsText(c)
	if not c.points then return nil end
	local s = format("%.2f", c.points)
	s = s:gsub("0+$", "")
	s = s:gsub("%.$", "")
	return s
end

AddMode{
	id           = "profit",
	tab          = "profit",
	label        = "Profit",
	tabWidth     = 58,
	subtitle     = "what it costs to make, and what it earns",
	levelDefault = false,
	printOrder   = "dearest first",
	help = "Priced from the last scan, at no extra cost. A ~ before a price means "
	    .. "it is an estimate. Recipe names carry your tradeskill window's colour. "
	    .. "Click a row for its reagents; type how many you want to make and the "
	    .. "shopping list works out the rest.",
	--[[
		Three counts in the space that used to hold two, and they belong
		together: what you could make, what you are holding, what you have
		listed. Have sits next to Can make because that is the comparison - one
		says how far through a batch you are, the other says how much further
		you could go, and neither means much alone.

		Narrower rather than moved. The Want box is fixed at 334 for every mode
		and the money columns start at 384, so the room for counts is the 116
		pixels between them and nothing else; these are two and three digit
		numbers and they do not need more.
	]]
	heads = { { "Can make", 214, 46, "RIGHT" }, { "Have", 264, 30, "RIGHT" },
	          { "On AH", 298, 32, "RIGHT" },
	          { "Reagents", 384, 104, "RIGHT" }, { "Sells for", 494, 104, "RIGHT" },
	          { "Profit", 604, 112, "RIGHT" } },
	cells = function(c)
		local profit = "|cff666666?|r"
		if c.profit then
			profit = c.profit >= 0
				and ("|cff00ff00+" .. BS.MoneyPlain(c.profit) .. "|r")
				or  ("|cffff4444-" .. BS.MoneyPlain(-c.profit) .. "|r")
		end
		return CanMakeCell(c), HaveCell(c), OnAuctionCell(c), CostCell(c),
		       c.revenue and BS.Money(c.revenue) or "|cff666666-|r", profit
	end,
	sort = function(a, b)
		local ap = a.profit or -math.huge
		local bp = b.profit or -math.huge
		if ap == bp then return (a.name or "") < (b.name or "") end
		return ap > bp
	end,
	tipLines = function(c)
		local t = {}

		--[[
			The three counts first, and together, because they only mean
			anything against each other: eight in the bags, four listed and
			twelve more makeable is a different afternoon to any one of those
			numbers on its own.
		]]
		local bags, bank = BS.ReagentHave(c)
		t[#t + 1] = { "In your bags", tostring(bags or 0) }
		if (bank or 0) > 0 then
			t[#t + 1] = { "In the bank", tostring(bank), 0.6, 0.6, 0.6 }
		end

		t[#t + 1] = { "Costs to make", CostCell(c) }

		--[[
			Said as a rate rather than a total, because everything else on this
			page is now counted in crafts - Want, Can make, the reagents - and
			this is the one line that turns crafts into items. Fifteen against a
			flask that makes two is thirty flasks, and this is where you read
			that off.
		]]
		if c.yield > 1 then
			t[#t + 1] = { "Each craft makes", format("%g", c.yield) }
		end
		if c.sellUnit then t[#t + 1] = { "Sells for", BS.Money(c.revenue) } end
		if c.profit then
			t[#t + 1] = { "Profit", BS.Money(c.profit),
			              c.profit >= 0 and 0.2 or 1, c.profit >= 0 and 1 or 0.3, 0.2 }
			t[#t + 1] = { "After the 5% AH cut", BS.Money(c.afterCut), 0.6, 0.6, 0.6 }
		end
		return t
	end,
	printLine = function(c)
		if not c.profit then
			return format("costs %s  |cffff8800no profit figure: %s|r",
				BS.Money(c.cost), c.doubts[1] or "prices missing")
		end
		return format("makes %s  costs %s  |cff%s%s%s|r",
			BS.Money(c.revenue or 0), BS.Money(c.cost),
			c.profit >= 0 and "00ff00" or "ff4444",
			c.profit >= 0 and "+" or "-", BS.MoneyPlain(math.abs(c.profit)))
	end,
}

--[[
	Training: what a skill point costs, and nothing about selling anything.

	The headline is mats divided by skill, cheapest first, because that is the
	whole question - you are not making these to sell them, you are making them to
	get a number up, and the only thing that matters is which one gets it up for
	the least gold.

	What the finished item is worth is deliberately absent. It is a real number
	and it is a distraction here: a levelling craft is usually something nobody
	buys, and quietly netting it off the cost would flatter recipes that happen to
	be sellable over the ones that are actually cheapest to train on. If you want
	to know what it earns, that is what the profit page is for - and a profession
	can be on both.
]]
AddMode{
	id           = "training",
	tab          = "training",
	label        = "Training",
	tabWidth     = 68,
	subtitle     = "the cheapest way to buy a skill point",
	levelDefault = true,
	printOrder   = "cheapest to level on first",
	help = "What the mats cost against how much skill they buy. Sorted cheapest per "
	    .. "point, so the top row is the cheapest way to level right now. Names are "
	    .. "your tradeskill window's colours; a ~ before a price means it is an "
	    .. "estimate. Grey recipes are hidden - they cannot teach you anything.",
	--[[
		Four columns, not five. There was a Skill one saying "orange" or "yellow"
		in words, and it went because the recipe's own name is now painted that
		colour - a column repeating what the row already shows is a column spent
		on nothing.

		A mode may declare as many columns as it likes; the page builds its rows
		from this list and paints whatever is here.
	]]
	heads = { { "Can make", 214, 114, "RIGHT" },
	          { "Mats cost", 384, 104, "RIGHT" }, { "Points", 494, 104, "RIGHT" },
	          { "Per point", 604, 112, "RIGHT" } },
	cells = function(c)
		return CanMakeCell(c), CostCell(c),
		       PointsText(c) or "|cff666666-|r",
		       c.perPoint and ("|cffffd100" .. BS.MoneyPlain(c.perPoint) .. "|r")
		       or "|cff666666?|r"
	end,
	sort = function(a, b)
		local ap = a.perPoint or math.huge
		local bp = b.perPoint or math.huge
		if ap == bp then return (a.name or "") < (b.name or "") end
		return ap < bp
	end,
	tipLines = function(c)
		local t = { { "Mats for one craft", CostCell(c) } }

		local d = BS.Difficulty[c.difficulty or ""]
		if d and PointsText(c) then
			t[#t + 1] = { "Skill points per craft",
			              format("%s  (%s)", PointsText(c), d.says), d.r, d.g, d.b }
		end

		if c.perPoint then
			t[#t + 1] = { "Cost per skill point", BS.Money(c.perPoint), 1, 0.82, 0 }
		elseif d and d.chance == 0 then
			t[#t + 1] = { "Cost per skill point", "it cannot level you", 0.6, 0.6, 0.6 }
		else
			t[#t + 1] = { "Cost per skill point", "a reagent has no price", 1, 0.4, 0.4 }
		end

		if c.yield > 1 then t[#t + 1] = { "Makes", format("%g", c.yield) } end
		return t
	end,
	printLine = function(c)
		if not c.perPoint then
			return format("mats %s  |cffff8800no cost per point: %s|r", BS.Money(c.cost),
				(c.points == 0) and "it cannot level you"
				or (c.doubts[1] or "prices missing"))
		end
		return format("mats %s  %s a point  |cff888888(%s per craft)|r",
			BS.Money(c.cost), BS.Money(c.perPoint), PointsText(c))
	end,
}

--=============================================================================
--  finding your way between them
--=============================================================================

--[[
	Anything that takes a profession takes a profession, an id, or nothing.

	Nothing means the first one registered, which is what everything meant before
	there was a second - so an old call site that was never updated still does
	exactly what it always did rather than failing in some new way.
]]
function BS:Prof(p)
	if type(p) == "table" then
		if p.recipesKey then return p end		-- already a profession
		if p.prof then return self:Prof(p.prof) end		-- a page handed us itself
	end
	return BS.Professions[p or ""] or BS.ProfOrder[1]
end

function BS:Mode(m)
	if type(m) == "table" and m.cells then return m end
	return BS.Modes[m or ""] or BS.ModeOrder[1]
end

-- the professions offered in this mode, in registration order
function BS:ProfsForMode(m)
	m = self:Mode(m)
	local out = {}
	for _, p in ipairs(BS.ProfOrder) do
		if p.modes and p.modes[m.id] then out[#out + 1] = p end
	end
	return out
end

--[[
	Which profession a mode's page is currently showing.

	Remembered, so coming back to a tab puts you where you left it. A saved choice
	for a profession that is no longer offered in that mode falls back to the
	first rather than to nothing, so editing the tables can never strand a page on
	a profession it will not show.
]]
function BS:ModeProf(m)
	m = self:Mode(m)
	local list = self:ProfsForMode(m)
	if #list == 0 then return nil end

	local want = self.db and self.db.modeProf and self.db.modeProf[m.id]
	for _, p in ipairs(list) do
		if p.id == want then return p end
	end
	return list[1]
end

function BS:SetModeProf(m, p)
	if not self.db then return end
	m, p = self:Mode(m), self:Prof(p)
	self.db.modeProf = self.db.modeProf or {}
	self.db.modeProf[m.id] = p.id
	self:RefreshCraft()
end

-- kept under the old name for anything outside this file that learned it
BS.VendorReagents = BS.Professions.alchemy.vendor

--[[
	Whether a reagent comes off a vendor, with your say over ours.

	The built-in lists are a guess about a game, and /snipe vendor is your answer
	about your realm. A private server that moved Eternium Thread onto the
	auction house, or added a vendor for something we are charging you for, is a
	thing you can see and we cannot - so what you set wins outright, in both
	directions, rather than merely adding to the list.
]]
function BS:IsVendorReagent(p, name)
	local over = self.db and self.db.vendorExtra
	if over and over[name] ~= nil then
		return over[name] and true or false
	end
	return self:Prof(p).vendor[name] and true or false
end

function BS:SetVendorReagent(name, isVendor)
	if not self.db then return end
	self.db.vendorExtra = self.db.vendorExtra or {}

	--[[
		Agreeing with the built-in list removes the override rather than storing
		it. Otherwise the saved table would slowly fill with entries that change
		nothing, and a later correction to the built-in list would be quietly
		overruled by an old agreement with it.
	]]
	local builtin = false
	for _, prof in ipairs(BS.ProfOrder) do
		if prof.vendor[name] then builtin = true break end
	end

	if isVendor == builtin then
		self.db.vendorExtra[name] = nil
	else
		self.db.vendorExtra[name] = isVendor and true or false
	end

	self:InvalidateCost()
	self:RefreshCraft()
end

--[[
	Which profession the window is showing.

	For the typed commands, which have no page to ask. Anything typed while a
	crafting page is up is about whatever that page is showing; anywhere else the
	answer is the first mode and its first profession.
]]
function BS:ActiveMode()
	for _, m in ipairs(BS.ModeOrder) do
		if self.tab == m.tab then return m end
	end
	return BS.ModeOrder[1]
end

function BS:ActiveProf()
	return self:ModeProf(self:ActiveMode()) or BS.ProfOrder[1]
end

--[[
	/snipe vendor <item> - your correction to the built-in lists, and /snipe
	vendor on its own to see the ones you have made.

	It toggles, because the thing you want to say is always the opposite of what
	the addon currently believes - and being told which way it went afterwards is
	clearer than having to remember a keyword for each direction.

	A name nothing uses is still recorded, and says so. Reagents arrive with
	recipes, so an item you have not learned the recipe for yet is a perfectly
	reasonable thing to be setting up in advance.
]]
function BS:VendorCommand(name)
	name = name and string.gsub(name, "^%s*(.-)%s*$", "%1") or ""

	if name == "" then
		local any = false
		for item, isVendor in pairs((self.db and self.db.vendorExtra) or {}) do
			if not any then
				self:Print("Your corrections to the vendor lists:")
				any = true
			end
			self:Print(format("   %s - %s", item,
				isVendor and "|cff88bbfffrom a vendor, so never costed|r"
				or "|cffffd100bought on the auction house, so costed|r"))
		end
		if not any then
			self:Print("No corrections - the built-in lists stand as they are. "
				.. "|cffffffff/snipe vendor <item name>|r changes one, spelled exactly "
				.. "as the game spells it.")
		end
		return
	end

	-- is anything actually made of this, and is it currently treated as free
	local known, isVendor = false, false
	for _, p in ipairs(BS.ProfOrder) do
		if self:IsVendorReagent(p, name) then isVendor = true end
		for _, r in pairs(self:Recipes(p)) do
			for _, reagent in ipairs(r.reagents or {}) do
				if reagent.name == name then known = true end
			end
		end
	end

	self:SetVendorReagent(name, not isVendor)

	if isVendor then
		self:Print(format("|cffffd100%s|r is now costed like anything else you buy "
			.. "on the auction house.", name))
	else
		self:Print(format("|cff88bbff%s|r is now treated as a vendor item: still "
			.. "counted on the shopping list, left out of every cost.", name))
	end

	if not known then
		self:Print("|cff888888Nothing on file uses that name. It is remembered anyway, "
			.. "and will apply the moment a recipe asks for it - but check the "
			.. "spelling if you expected it to matter now.|r")
	end
end

--[[
	How many of this you are carrying, and separately how many are sitting in
	the bank.

	Only the bags count towards anything. What is in the bank may well be there
	on purpose - saved for something, or simply not to be spent - and a shopping
	list that quietly assumed you would go and fetch it would be planning your
	trip for you. So the sums use the bags, and the bank is reported beside them
	so that a stack you had forgotten about is still a stack you get told about.

	The bank figure is only as good as what the client has cached, which means
	what it saw the last time you opened your bank. Never opened it this
	session and it reads zero - absence of a number here is not evidence.
]]
function BS.ReagentHave(reagent)
	if type(GetItemCount) ~= "function" then return 0, 0 end

	local key = reagent.link or reagent.name
	local okBags, bags   = pcall(GetItemCount, key, false)
	local okBoth, both   = pcall(GetItemCount, key, true)

	bags = (okBags and type(bags) == "number") and bags or 0
	both = (okBoth and type(both) == "number") and both or bags

	return bags, math.max(0, both - bags)
end

-- Harvested prices this old are dropped rather than kept as a fallback. Long
-- enough that a week away still leaves you something to look at, short enough
-- that the saved table cannot grow for ever.
local PRICE_KEEP_FOR = 14 * 24 * 3600

--=============================================================================
--  the recipe book
--=============================================================================

function BS:Recipes(p)
	if not self.db then return {} end
	local key = self:Prof(p).recipesKey
	self.db[key] = self.db[key] or {}
	return self.db[key]
end

--[[
	Prices are shared by every profession, and the reason is that a price is a
	fact about an item rather than about a trade. Borean Leather costs what it
	costs whether a leatherworker or a passer-by is asking, and keeping two
	copies of that would mean a scan run from one page left the other stale for
	no reason anybody could see.
]]
function BS:CraftPrices()
	if not self.db then return {} end
	self.db.craftPrices = self.db.craftPrices or {}
	return self.db.craftPrices
end

--[[
	Which profession an open tradeskill window belongs to.

	The window's own name is the only thing the client offers, so that is what is
	matched. A window we do not recognise returns nothing, and the caller falls
	back to sorting the recipes by what they make - which is how alchemy worked
	before any of this existed, and still works if the name comes through in a
	language these tables do not have.
]]
local function ProfessionForWindow(line)
	if not line then return nil end
	for _, p in ipairs(BS.ProfOrder) do
		if p.trade[line] then return p end
	end
	return nil
end

-- which profession, if any, claims a crafted item by its subclass
local function ProfessionForSubType(subType)
	if not subType then return nil end
	for _, p in ipairs(BS.ProfOrder) do
		if p.subTypes and p.subTypes[subType] then return p end
	end
	return nil
end

--[[
	Read whatever the open tradeskill window is showing.

	Deliberately additive: it merges into the book rather than replacing it. The
	window's own search box and its "have materials" tick change what
	GetNumTradeSkills reports, and a filtered window must not be able to quietly
	delete two thirds of your recipes. The cost of that choice is that a recipe
	you unlearn lingers, which is a far smaller problem and one Forget fixes.

	Which book it merges into is decided by the window, not by whichever page you
	happened to press the button on. Opening leatherworking and pressing Read on
	the Flasks page reads leatherworking, because that is plainly what you meant
	and the alternative is a button that does nothing and does not say why.
]]
function BS:HarvestRecipes(hint, quiet)
	if type(GetNumTradeSkills) ~= "function" then return 0 end

	local line = GetTradeSkillLine and GetTradeSkillLine() or nil
	local n    = GetNumTradeSkills() or 0
	if n == 0 then
		if not quiet then
			local p = self:Prof(hint)
			self:Print(format("Open your %s window and press this again - the client "
				.. "will not say what you can make until it is open.", p.window))
		end
		return 0
	end

	local target = ProfessionForWindow(line)
	local found, unknown, touched = 0, 0, {}

	for i = 1, n do
		-- skillType is both "is this a header" and, for a recipe, how hard it
		-- still is: optimal, medium, easy or trivial - orange to grey.
		local skillName, skillType, _, _, _, numSkillUps = GetTradeSkillInfo(i)
		if skillName and skillType ~= "header" then
			local link = GetTradeSkillItemLink(i)
			-- The subclass comes from the client's item cache. A link the client
			-- cannot resolve yet is counted and skipped wherever it is needed,
			-- so opening the window again once it has loaded picks it up.
			local _, _, _, _, _, itemType, itemSubType = GetItemInfo(link or skillName)

			--[[
				Where this one goes.

				A recognised window with no filter takes everything it makes. A
				recognised window with a filter takes only what passes it. An
				unrecognised window falls back to asking each item which
				profession claims its subclass, which is exactly what this did
				before there was more than one.
			]]
			local into
			if target and not target.subTypes then
				into = target
			elseif target then
				if not itemType then
					unknown = unknown + 1
				elseif target.subTypes[itemSubType] then
					into = target
				end
			elseif not itemType then
				unknown = unknown + 1
			else
				into = ProfessionForSubType(itemSubType)
			end

			if into then
				local reagents = {}
				for j = 1, (GetTradeSkillNumReagents(i) or 0) do
					local rName, rTexture, rCount = GetTradeSkillReagentInfo(i, j)
					if rName then
						reagents[#reagents + 1] = {
							name    = rName,
							link    = GetTradeSkillReagentItemLink(i, j),
							texture = rTexture,
							need    = rCount or 1,
						}
					end
				end

				--[[
					A recipe with no reagents is not one this can cost. It is
					usually a window still filling in, and storing it would put a
					permanent row reading "costs nothing to make" at the top of a
					list sorted by what you save.
				]]
				if #reagents > 0 then
					local minMade, maxMade = 1, 1
					if type(GetTradeSkillNumMade) == "function" then
						minMade, maxMade = GetTradeSkillNumMade(i)
					end

					self:Recipes(into)[skillName] = {
						name      = skillName,
						link      = link,
						subType   = itemSubType,
						difficulty = skillType,
						skillUps   = numSkillUps,
						minMade   = minMade or 1,
						maxMade   = maxMade or minMade or 1,
						reagents  = reagents,
						source    = line,
						learnedAt = time(),
					}
					found = found + 1
					touched[into.id] = (touched[into.id] or 0) + 1
				end
			end
		end
	end

	if not quiet then
		if found > 0 then
			local parts = {}
			for _, p in ipairs(BS.ProfOrder) do
				local c = touched[p.id]
				if c then
					parts[#parts + 1] = format("|cffffffff%d|r %s recipe%s", c, p.makes,
						c == 1 and "" or "s")
				end
			end
			self:Print(format("Read %s from %s.%s", table.concat(parts, " and "),
				line or "your tradeskill",
				unknown > 0 and format("  (%d entr%s could not be identified yet - "
					.. "open it again once they have loaded)", unknown,
					unknown == 1 and "y" or "ies") or ""))
		else
			local names = {}
			for _, p in ipairs(BS.ProfOrder) do names[#names + 1] = p.window end
			self:Print(format("Nothing to cost in that window. This reads %s; open one "
				.. "of those and try again.", table.concat(names, " and ")))
		end
	end

	if found > 0 then
		for id in pairs(touched) do self:InvalidateCost(id) end
		self:RefreshCraft()
	end
	return found
end

function BS:ForgetRecipes(p)
	p = self:Prof(p)
	self.db[p.recipesKey] = {}
	self:InvalidateCost(p)
	self:Print(format("Forgot every %s recipe. Open %s to read them again.",
		p.makes, p.window))
	self:RefreshCraft(p)
end

--=============================================================================
--  prices, harvested from the scan you were running anyway
--=============================================================================

--[[
	The set of item names worth noticing while a scan runs: every reagent of
	every known recipe, and everything those recipes make, across every
	profession at once. Built once at the start of a scan so the check inside the
	row loop is a single hash lookup against a table that is already there.

	One set rather than one per profession, because the row loop should not have
	to care how many books there are - and because the same name turns up in two
	of them often enough that separate sets would mean checking twice for one
	answer.
]]
function BS:BuildCraftWatch()
	local names, n = {}, 0
	for _, p in ipairs(BS.ProfOrder) do
		for craftName, r in pairs(self:Recipes(p)) do
			if not names[craftName] then names[craftName] = true n = n + 1 end
			for _, reagent in ipairs(r.reagents or {}) do
				if not names[reagent.name] then names[reagent.name] = true n = n + 1 end
			end
		end
	end
	self.craftWatchNames = (n > 0) and names or nil
	self.craftSeen       = (n > 0) and {} or nil
	return n
end

--[[
	One auction row, on its way past.

	What matters is the cheapest way to buy one unit, so a stack of twenty is
	worth buyout/20 and competes with a single at its own price. Bids are no use
	here: you cannot plan a craft around an auction you might be outbid on, so
	only buyouts count.
]]
function BS:CraftSawAuction(name, count, buyout)
	local seen = self.craftSeen
	if not seen or not buyout or buyout <= 0 then return end

	local unit = buyout / (count or 1)
	local cur  = seen[name]
	if not cur then
		seen[name] = { unit = unit, qty = count or 1 }
	else
		if unit < cur.unit then cur.unit = unit end
		cur.qty = cur.qty + (count or 1)
	end
end

--[[
	A scan has finished: write what it saw into the price book.

	Only names the scan actually saw are touched. An item nobody is selling
	keeps its previous price rather than losing it, because "there were none up
	an hour ago" and "there are none up now" are the same answer and neither is
	worth throwing a usable figure away for.
]]
function BS:CraftScanFinished()
	local seen = self.craftSeen
	self.craftWatchNames, self.craftSeen = nil, nil
	if not seen then return end

	local prices, now, n = self:CraftPrices(), time(), 0
	for name, info in pairs(seen) do
		prices[name] = { unit = floor(info.unit), qty = info.qty, t = now }
		n = n + 1
	end

	-- anything not seen for a fortnight is not a price any more
	for name, entry in pairs(prices) do
		if type(entry) ~= "table" or not entry.t or (now - entry.t) > PRICE_KEEP_FOR then
			prices[name] = nil
		end
	end

	if n > 0 then
		--[[
			Stamped so a price can prove which sweep it came from. That is the
			whole basis of the exact/estimate split: a figure carrying this
			stamp was read off the auction house by the scan that just finished,
			and a figure carrying an older one was not, however recently.
		]]
		self.db.craftPricedAt = now
		self:InvalidateCost()		-- new prices, so every old sum is void
		self:RefreshCraft()
	end
	return n
end

--[[
	What one of these costs, and how much that figure can be trusted.

	Returns unit price, source, and the time it was taken. Source is "scan" for
	something the last sweep actually saw on the auction house, "auctionator"
	for a figure out of its database, and nil for an item with no price anywhere
	- which is not the same as free, and is what turns a sum into an estimate.
]]
function BS:UnitPrice(name, link)
	local entry   = self:CraftPrices()[name]
	local current = self.db and self.db.craftPricedAt

	--[[
		"Current" means this exact figure came out of the most recent sweep, not
		that it is recent-ish. A price from the scan before last is a price for
		a market that has since moved, and an hour is plenty of time for the
		reagent you are costing to have been bought out.
	]]
	if entry and entry.unit and entry.unit > 0 and current and entry.t == current then
		return entry.unit, "scan", entry.t, entry.qty
	end

	-- Auctionator is asked live rather than cached here: the whole point of
	-- running its scan is that the answer changes, and a stale copy of ours
	-- would go on reporting the old one.
	local unit = BS.MarketValue(link or name)
	if unit and unit > 0 then return unit, "auctionator", nil, nil end

	-- an old harvest is still better than nothing, it just cannot claim to be current
	if entry and entry.unit and entry.unit > 0 then
		return entry.unit, "stale", entry.t, entry.qty
	end
	return nil, nil, nil, nil
end

--=============================================================================
--  what you already have listed
--=============================================================================

--[[
	How many of each thing you have sitting on the auction house right now.

	This is the number that tells you whether to make more: eight flasks in your
	bags and none listed is a very different position from none in your bags and
	eight listed, and the recipe list cannot say which without asking.

	It comes off the owner list, which the client only has once it has been
	asked for. That request is made when the auction house opens, so by the time
	you get to this tab the answer is usually already in - and if it is not, the
	column simply says so rather than guessing at zero.
]]
function BS:RefreshOwnedAuctions()
	local n = GetNumAuctionItems("owner") or 0
	local owned = {}

	for i = 1, n do
		local name, _, count = GetAuctionItemInfo("owner", i)
		if name then
			-- stack sizes, not auction slots: five flasks in one auction is
			-- still five flasks that somebody can buy
			owned[name] = (owned[name] or 0) + (count or 1)
		end
	end

	self.onAuction   = owned
	self.onAuctionAt = time()

	self:RefreshCraft()
	return n
end

-- nil until the owner list has actually arrived, which is different from zero
function BS:OwnedCount(name)
	if not self.onAuction then return nil end
	return self.onAuction[name] or 0
end

--=============================================================================
--  the sum
--=============================================================================

--[[
	Cost one recipe out.

	`exact` means every single figure in the sum came from the most recent scan.
	Anything else is an estimate, and `doubts` says in plain words what made it
	one - a reagent nobody is selling, or one priced from Auctionator rather
	than from the house as it stands right now.

	Reagents are costed at what it would take to buy them, not at what is in
	your bags. What you already own is a sunk cost; the question this answers is
	whether turning materials into the finished thing is worth doing at today's
	prices, and that is the same question whether you buy them or already have
	them.

	It is also, read the other way round, the question the leatherworking page
	asks: `profit` is what the finished item sells for less what its mats cost,
	so a positive one means buying the mats is cheaper than buying the item.
	Same subtraction, two ways of caring about the answer.
]]
function BS:CostRecipe(p, r)
	p = self:Prof(p)

	local out = {
		name    = r.name,
		link    = r.link,
		subType = r.subType,
		prof    = p.id,
		difficulty = r.difficulty,
		skillUps   = r.skillUps,
		yield   = ((r.minMade or 1) + (r.maxMade or r.minMade or 1)) / 2,
		lines   = {},
		cost    = 0,
		exact   = true,
		doubts  = {},
		missing = 0,
	}

	-- how many complete sets of reagents are in your bags, which is how many of
	-- these you could make right now without buying or fetching anything
	local canMake = nil

	for _, reagent in ipairs(r.reagents or {}) do
		local unit, src, when, qty = self:UnitPrice(reagent.name, reagent.link)
		local vendor     = self:IsVendorReagent(p, reagent.name)
		local have, bank = BS.ReagentHave(reagent)

		local line = {
			name = reagent.name, link = reagent.link, texture = reagent.texture,
			need = reagent.need, unit = unit, src = src, when = when, qty = qty,
			vendor = vendor, have = have, bank = bank,
		}

		local sets = floor(have / math.max(reagent.need, 1))
		if canMake == nil or sets < canMake then canMake = sets end

		if vendor then
			-- counted, never costed
			line.total = 0
		elseif unit then
			line.total = unit * reagent.need
			out.cost   = out.cost + line.total
			if src ~= "scan" then
				out.exact = false
				out.doubts[#out.doubts + 1] = format("%s priced from %s", reagent.name,
					src == "auctionator" and "Auctionator, not from the last scan"
					or "an older scan")
			end
		else
			out.exact   = false
			out.missing = out.missing + 1
			out.doubts[#out.doubts + 1] = reagent.name .. " has no price anywhere"
		end

		out.lines[#out.lines + 1] = line
	end

	out.canMake = canMake or 0

	-- how many are already listed, so "make more" is a question you can answer
	out.onAuction = self:OwnedCount(r.name)

	local sellUnit, sellSrc, sellWhen = self:UnitPrice(r.name, r.link)
	out.sellUnit, out.sellSrc, out.sellWhen = sellUnit, sellSrc, sellWhen

	if sellUnit then
		out.revenue = sellUnit * out.yield
		if sellSrc ~= "scan" then
			out.exact = false
			out.doubts[#out.doubts + 1] = format("%s itself priced from %s", r.name,
				sellSrc == "auctionator" and "Auctionator" or "an older scan")
		end
	else
		out.exact = false
		out.doubts[#out.doubts + 1] = r.name .. " is not selling, so there is nothing to compare"
	end

	--[[
		Profit is left nil rather than guessed when a reagent has no price at
		all. A missing reagent priced as zero would read as the most profitable
		craft on the list, which is exactly backwards - it is the one we know
		least about.
	]]
	if out.revenue and out.missing == 0 then
		out.profit    = out.revenue - out.cost
		out.afterCut  = out.revenue * 0.95 - out.cost
		out.margin    = (out.cost > 0) and (out.profit / out.cost) or nil
	end

	--[[
		What one craft is worth in skill, and what a point of it costs.

		`chance` is the usual approximation for how often a craft of that colour
		gives a point: certain at orange, three times in four at yellow, one in
		four at green, never at grey. The client does not publish the real curve,
		so this is an estimate and is meant as one. It is here to rank recipes
		against each other, which it does correctly, rather than to promise how
		many Borean Leather any particular point will take.

		numSkillUps is the client's own figure and is 1 for nearly everything.

		Left nil when a reagent has no price at all, for the same reason profit is:
		a missing reagent counted as free would come out as the cheapest way in the
		game to level, when it is only the one we know least about.
	]]
	local d = BS.Difficulty[r.difficulty or ""]
	if d then
		out.chance = d.chance
		out.points = d.chance * (r.skillUps or 1)
		if out.points > 0 and out.missing == 0 and out.cost > 0 then
			out.perPoint = out.cost / out.points
		end
	end

	return out
end

-- every known recipe of one profession, costed. Sorted dearest profit first as
-- a stable default; a page re-sorts a copy into whatever order its mode wants.
function BS:CostAll(p)
	p = self:Prof(p)

	local list, wants = {}, self:Wants(p)
	for _, r in pairs(self:Recipes(p)) do
		local c = self:CostRecipe(p, r)
		c.want = wants[r.name] or 0
		list[#list + 1] = c
	end

	sort(list, function(a, b)
		local ap = a.profit or -math.huge
		local bp = b.profit or -math.huge
		if ap == bp then return (a.name or "") < (b.name or "") end
		return ap > bp
	end)

	self.craftCosted = self.craftCosted or {}
	self.craftCosted[p.id] = list
	return list
end

--[[
	The costing on hand, worked out if there is not one.

	Everything that feeds a costing throws it away when it moves - a scan, a
	harvest, a quantity, a vendor correction - so a kept list can never be older
	than the prices and bags behind it. Which means the cheap path is always safe
	to take, and a page can repaint on every notch of the scroll wheel without
	recosting a hundred recipes each time.
]]
function BS:Costed(p)
	p = self:Prof(p)
	local have = self.craftCosted and self.craftCosted[p.id]
	if have then return have end
	return self:CostAll(p)
end

--[[
	Whether a page is hiding what can no longer level you.

	Kept per page rather than per profession, because the same profession can be
	open in two modes at once and the answer is not the same in both: a training
	page has no business showing grey, and a profit page has no business hiding
	something that sells well merely because it stopped teaching you anything.

	Unset falls back to the mode's own default, so a training page arrives already
	filtered and a profit page arrives showing everything. Setting it stores true
	or false outright - never nil - so turning it off on a training page sticks
	rather than reverting to the default next time.
]]
local function LevelKey(m, p) return m.id .. ":" .. p.id end

function BS:LevelOnly(m, p)
	m, p = self:Mode(m), self:Prof(p)
	local v = (self.db and self.db.levelOnly or {})[LevelKey(m, p)]
	if v == nil then return m.levelDefault and true or false end
	return v and true or false
end

function BS:SetLevelOnly(m, p, on)
	if not self.db then return end
	m, p = self:Mode(m), self:Prof(p)
	self.db.levelOnly = self.db.levelOnly or {}
	self.db.levelOnly[LevelKey(m, p)] = on and true or false
	self.pageList = nil
	self:RefreshCraft()
end

--[[
	One page's list: its profession's costings, filtered and put in its own order.

	Kept apart from the costing itself because two pages can be looking at the
	same profession and want opposite orders - dearest profit first on one,
	cheapest skill point first on the other - and costing it twice to get that
	would be work done for nothing. The sums are shared; the arrangement is not.

	The filter is a view and nothing else. What is hidden is still costed, still
	holds whatever you typed against it in Want, and is still bought by a shopping
	run. Hiding a row is a statement about your eyes and not about your plan -
	quietly dropping a recipe you had asked for forty of, because it had stopped
	levelling you, would be a far worse thing to do than showing it.

	A recipe read before difficulty was recorded has none, and is never hidden.
	Not knowing whether something would level you is not the same as knowing that
	it would not, and only the second is worth acting on.
]]
function BS:PageList(m)
	m = self:Mode(m)
	local p = self:ModeProf(m)
	if not p then return {}, 0 end

	self.pageList = self.pageList or {}
	local cached = self.pageList[m.id]
	if cached and cached.prof == p.id then return cached.list, cached.hidden end

	local drop = self:LevelOnly(m, p)
	local list, hidden = {}, 0
	for _, c in ipairs(self:Costed(p)) do
		if drop and c.difficulty == "trivial" then
			hidden = hidden + 1
		else
			list[#list + 1] = c
		end
	end
	sort(list, m.sort)

	self.pageList[m.id] = { prof = p.id, list = list, hidden = hidden }
	return list, hidden
end

--[[
	One profession's sums, or everybody's.

	The page arrangements go with them every time. They are built out of the
	costings, so a costing that is no longer true cannot leave a page order that
	still is.
]]
function BS:InvalidateCost(p)
	self.pageList = nil
	if p == nil then
		self.craftCosted = nil
	elseif self.craftCosted then
		self.craftCosted[self:Prof(p).id] = nil
	end
end

--=============================================================================
--  "I want to make this many" and the shopping list that falls out of it
--=============================================================================

function BS:Wants(p)
	if not self.db then return {} end
	local key = self:Prof(p).wantKey
	self.db[key] = self.db[key] or {}
	return self.db[key]
end

function BS:SetWant(p, name, n)
	p = self:Prof(p)
	n = tonumber(n) or 0
	if n < 0 then n = 0 end

	local wants = self:Wants(p)
	local was   = wants[name]
	wants[name] = (n > 0) and floor(n) or nil
	if wants[name] == was then return end		-- nothing moved, nothing to repaint

	--[[
		What a recipe costs, earns, and how many you could make do not depend on
		how many you plan to make, so the costings are left alone and only the
		one number is patched. This runs on every keystroke; recosting the whole
		book each time would make typing a quantity feel like the addon had
		stalled.
	]]
	local costed = self.craftCosted and self.craftCosted[p.id]
	if costed then
		for _, c in ipairs(costed) do
			if c.name == name then c.want = wants[name] or 0 break end
		end
	end

	self:RefreshCraft(p)
end

function BS:ClearWants(p)
	p = self:Prof(p)
	self.db[p.wantKey] = {}
	self:InvalidateCost(p)
	self:Print(format("Cleared every planned %s quantity.", p.makes))
	self:RefreshCraft(p)
end

--[[
	What to go and buy to make everything you have asked for.

	Your bags are subtracted once, at the end, against the total. Doing it per
	recipe would spend the same stack of Lichbloom twice over the moment two
	things on your list share a reagent, and send you home short.

	The bank is not subtracted at all. It is reported next to anything you are
	short of, because forgetting a stack you already own is a real and annoying
	way to waste gold - but whether to go and get it is your call, not a
	deduction made on your behalf.

	Vendor reagents come back on their own list. They cost nothing here and are
	not part of any profit figure, but you still need to know how many to pick
	up - and that is a different trip from the auction house, which is exactly
	why they are kept apart.

	`wants` overrides what you typed into the Want column, and exists for one
	caller: a shopping run that has discovered it cannot buy enough of something
	and has cut its plan back to what the auction house can actually supply.

	It works on a copy rather than on your numbers, so what is on screen is
	still what you asked for. A run that trimmed the Want column as it went
	would leave you having to remember what you originally wanted.
]]
function BS:ShoppingList(p, wants)
	p = self:Prof(p)

	local need, order = {}, {}

	for name, want in pairs(wants or self:Wants(p)) do
		local r = self:Recipes(p)[name]
		if r and want > 0 then
			--[[
				Want is how many times to make it, not how many items to end up
				holding, and that is a change from how this used to read.

				It used to take Want as a number of finished items and divide by
				the yield, so 15 against a flask that makes two came out as
				eight crafts. Two things were wrong with that. The first is that
				it disagreed with the column next to it: Can make has always
				counted complete sets of reagents - crafts - so the page showed
				"can make 8" and "want 15" in two different units and invited
				exactly the comparison that cannot be made.

				The second is worse. The divisor was the *average* of what the
				recipe can produce, and for anything with a chance-based extra
				that average is not a promise. Buying reagents for it means
				buying for the lucky case and coming up short whenever the luck
				does not arrive - which is a real cost, paid in a second trip to
				the auction house.

				Crafts is also the number you actually control. You queue crafts
				in the tradeskill window; how many items fall out is the
				recipe's business.
			]]
			local crafts = want

			for _, reagent in ipairs(r.reagents or {}) do
				local e = need[reagent.name]
				if not e then
					e = {
						name   = reagent.name,
						link   = reagent.link,
						vendor = self:IsVendorReagent(p, reagent.name),
						total  = 0,
					}
					need[reagent.name] = e
					order[#order + 1]  = e
				end
				e.total = e.total + reagent.need * crafts
			end
		end
	end

	local buy, vendor, cost, exact = {}, {}, 0, true

	for _, e in ipairs(order) do
		e.have, e.bank = BS.ReagentHave(e)
		e.short = math.max(0, e.total - e.have)

		-- how much of the shortfall the bank could cover, if you wanted it to
		e.inBank = (e.short > 0) and math.min(e.bank, e.short) or 0

		if e.vendor then
			vendor[#vendor + 1] = e
		else
			local unit, src = self:UnitPrice(e.name, e.link)
			e.unit, e.src = unit, src
			if unit then
				e.spend = unit * e.short
				cost    = cost + e.spend
				if src ~= "scan" then exact = false end
			else
				exact = false
			end
			-- everything is listed, including what you already have enough of:
			-- "you need none of this" is an answer worth seeing
			buy[#buy + 1] = e
		end
	end

	local function bySpend(a, b)
		local as, bs = a.spend or -1, b.spend or -1
		if as == bs then return a.name < b.name end
		return as > bs
	end
	sort(buy, bySpend)
	sort(vendor, function(a, b) return a.name < b.name end)

	return buy, vendor, cost, exact
end

--[[
	What can actually be made, given what the reagents will run to.

	`supply` is reagent name -> how many of it you will end up holding, all in.
	A reagent missing from that table is unlimited: either you already had
	enough of it that nothing needed buying, or it comes off a vendor, and
	neither is a constraint on anything.

	Every recipe is limited by all of its reagents at once, which is the whole
	reason this exists as one function rather than as a cap applied per reagent.
	Doing them one at a time cannot be made to work: cutting a recipe because of
	Ghost Mushroom frees the Grave Moss it was holding, and a per-reagent cap
	has no way to give that back to the recipe it took it from - quantities only
	ever come down, so a recipe cut early stays cut even once the reason has
	gone away. Here nothing is provisional. Each recipe is asked for everything
	it needs in one go, takes what it can actually have, and what it does not
	take stays on the table for the next one.

	They are served most profitable first, which is the order the page is
	already sorted in, so the recipe that gets the scarce stack is the one at the
	top of the list you are looking at. Splitting a shortage evenly is the other
	defensible answer and it is worse: it makes half a batch of two things
	instead of a whole batch of the better one.

	Only whole crafts count. Two thirds of the reagents for a flask is not two
	thirds of a flask, and rounding up would put a shopping run straight back to
	buying for something that cannot be made.

	Returns the new quantities and, for anything that moved, what it was, what
	it became, and which reagents held it back.
]]
function BS:SolveWants(p, wants, supply, m)
	p = self:Prof(p)

	local newWants, changes = {}, {}
	for k, v in pairs(wants) do newWants[k] = v end

	local left = {}
	for k, v in pairs(supply or {}) do left[k] = v end

	--[[
		Best first, by whatever "best" means to the page that started the run.

		Without a mode this is the costing's own order, dearest profit first, which
		is what it has always been. With one it is that page's order - so a run
		started from the training page gives the scarce stack to the recipe that
		levels you most cheaply, rather than to the one that would sell best.
	]]
	local order = self:Costed(p)
	if m then
		m = self:Mode(m)
		order = {}
		for _, c in ipairs(self:Costed(p)) do order[#order + 1] = c end
		sort(order, m.sort)
	end

	for _, c in ipairs(order) do
		local want = newWants[c.name]
		local r    = self:Recipes(p)[c.name]

		if want and want > 0 and r then
			-- crafts, the same unit Want is in and the same unit Can make is in
			local crafts = want

			-- how far the tightest of its reagents lets this one go
			local allowed, blockers = crafts, {}
			for _, reagent in ipairs(r.reagents or {}) do
				local have, need = left[reagent.name], reagent.need or 0
				if have and need > 0 then
					local canDo = floor(have / need)
					if canDo < allowed then
						allowed, blockers = canDo, { reagent.name }
					elseif canDo == allowed and canDo < crafts then
						-- two reagents equally to blame is worth saying so
						blockers[#blockers + 1] = reagent.name
					end
				end
			end
			if allowed < 0 then allowed = 0 end

			-- what it takes comes off the table, and only what it takes: a
			-- recipe cut back to a dozen holds a dozen crafts' worth and no more
			for _, reagent in ipairs(r.reagents or {}) do
				if left[reagent.name] then
					left[reagent.name] = left[reagent.name] - allowed * (reagent.need or 0)
				end
			end

			if allowed < crafts then
				-- `allowed` is already crafts, and so is what it is cut down to
				changes[#changes + 1] =
					{ name = c.name, from = want, to = allowed, why = blockers }
				newWants[c.name] = (allowed > 0) and allowed or nil
			end
		end
	end

	return newWants, changes
end

-- printed version, for people who would rather not open a panel
function BS:PrintCrafts(p, m)
	p, m = self:Prof(p), self:Mode(m)

	local list = self:CostAll(p)
	if #list == 0 then
		self:Print(format("No %s recipes on file. Open your %s window.",
			p.makes, p.window))
		return
	end

	-- the page's own order, so what is printed first is what is on top there
	local shown = {}
	for _, c in ipairs(list) do shown[#shown + 1] = c end
	sort(shown, m.sort)

	self:Print(format("%d %s recipe%s, %s:", #shown, p.makes,
		#shown == 1 and "" or "s", m.printOrder))

	for i = 1, math.min(#shown, 15) do
		local c = shown[i]

		-- named rather than coloured: chat is read as text, and a bare coloured
		-- word beside an item link reads as part of the link
		local d    = BS.Difficulty[c.difficulty or ""]
		local mark = d and format("  |cff%s(%s)|r", d.hex, d.label) or ""

		self:Print(format("   %s%s  %s%s", c.link or c.name, mark, m.printLine(c),
			c.exact and "" or "  |cffff8800(estimate)|r"))
	end
end