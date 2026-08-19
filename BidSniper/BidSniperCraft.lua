--[[
	BidSniper - what your flasks and elixirs cost to make, and what they earn

	Three things have to come together for that sum, and this file is mostly
	about getting each of them for nothing.

	The recipes come from your own alchemy window. There is no way to ask the
	client what a character can make without that window being open, so it is
	read once while it is open and kept through logging out. Open alchemy, close
	it, and the list stays.

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
]]

local BS = BidSniper
if not BS then return end

local floor, format, sort = math.floor, string.format, table.sort

-- Consumables worth costing out. The client's own subclass for the crafted
-- item decides this, rather than a list of names that would go stale.
local CRAFT_SUBTYPES = { ["Flask"] = true, ["Elixir"] = true }

--[[
	Vials come off a vendor at a fixed few silver, so they are left out of the
	cost: a shopping trip is not an auction house decision and pretending it is
	only muddies what a craft is really worth. They are still counted, because
	you cannot make a flask without one and the whole point of the list is to
	leave the auction house knowing what else to go and buy.

	There is no API that says "a vendor sells this", so this is a list of names.
	It is the four in the game, and anything not on it is treated as something
	you have to buy from other players - which is the safe way round to be wrong.
]]
local VENDOR_REAGENTS = {
	["Crystal Vial"] = true,
	["Imbued Vial"]  = true,
	["Leaded Vial"]  = true,
	["Empty Vial"]   = true,
}

BS.VendorReagents = VENDOR_REAGENTS

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

function BS:Recipes()
	if not self.db then return {} end
	self.db.recipes = self.db.recipes or {}
	return self.db.recipes
end

function BS:CraftPrices()
	if not self.db then return {} end
	self.db.craftPrices = self.db.craftPrices or {}
	return self.db.craftPrices
end

--[[
	Read whatever the open tradeskill window is showing.

	Deliberately additive: it merges into the book rather than replacing it. The
	window's own search box and its "have materials" tick change what
	GetNumTradeSkills reports, and a filtered window must not be able to quietly
	delete two thirds of your recipes. The cost of that choice is that a recipe
	you unlearn lingers, which is a far smaller problem and one Forget fixes.
]]
function BS:HarvestRecipes(quiet)
	if type(GetNumTradeSkills) ~= "function" then return 0 end

	local line = GetTradeSkillLine and GetTradeSkillLine() or nil
	local n    = GetNumTradeSkills() or 0
	if n == 0 then
		if not quiet then
			self:Print("Open your alchemy window and press this again - the client "
				.. "will not say what you can make until it is open.")
		end
		return 0
	end

	local book, found, unknown = self:Recipes(), 0, 0

	for i = 1, n do
		local skillName, skillType = GetTradeSkillInfo(i)
		if skillName and skillType ~= "header" then
			local link = GetTradeSkillItemLink(i)
			-- The subclass is what tells a flask from a bandage, and it comes
			-- from the client's item cache. A link the client cannot resolve
			-- yet is counted and skipped: opening the window again once it has
			-- loaded picks it up.
			local _, _, _, _, _, itemType, itemSubType = GetItemInfo(link or skillName)

			if not itemType then
				unknown = unknown + 1
			elseif CRAFT_SUBTYPES[itemSubType] then
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

				if #reagents > 0 then
					local minMade, maxMade = 1, 1
					if type(GetTradeSkillNumMade) == "function" then
						minMade, maxMade = GetTradeSkillNumMade(i)
					end

					book[skillName] = {
						name      = skillName,
						link      = link,
						subType   = itemSubType,
						minMade   = minMade or 1,
						maxMade   = maxMade or minMade or 1,
						reagents  = reagents,
						source    = line,
						learnedAt = time(),
					}
					found = found + 1
				end
			end
		end
	end

	if not quiet then
		if found > 0 then
			self:Print(format("Read |cffffffff%d|r flask and elixir recipe%s from %s.%s",
				found, found == 1 and "" or "s", line or "your tradeskill",
				unknown > 0 and format("  (%d entr%s could not be identified yet - "
					.. "open it again once they have loaded)", unknown,
					unknown == 1 and "y" or "ies") or ""))
		else
			self:Print("No flask or elixir recipes in that window. This costs out "
				.. "flasks and elixirs; open alchemy and try again.")
		end
	end

	if found > 0 then
		self.craftCosted = nil
		self:RefreshCraft()
	end
	return found
end

function BS:ForgetRecipes()
	self.db.recipes  = {}
	self.craftCosted = nil
	self:Print("Forgot every recipe. Open alchemy to read them again.")
	self:RefreshCraft()
end

--=============================================================================
--  prices, harvested from the scan you were running anyway
--=============================================================================

--[[
	The set of item names worth noticing while a scan runs: every reagent of
	every known recipe, and every flask and elixir those recipes make. Built
	once at the start of a scan so the check inside the row loop is a single
	hash lookup against a table that is already there.
]]
function BS:BuildCraftWatch()
	local names, n = {}, 0
	for craftName, r in pairs(self:Recipes()) do
		if not names[craftName] then names[craftName] = true n = n + 1 end
		for _, reagent in ipairs(r.reagents or {}) do
			if not names[reagent.name] then names[reagent.name] = true n = n + 1 end
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
		self.craftCosted      = nil		-- new prices, so the old sums are void
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
	whether turning materials into a flask is worth doing at today's prices,
	and that is the same question whether you buy them or already have them.
]]
function BS:CostRecipe(r)
	local out = {
		name    = r.name,
		link    = r.link,
		subType = r.subType,
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
		local vendor     = VENDOR_REAGENTS[reagent.name] and true or false
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

	return out
end

--=============================================================================
--  "I want to make this many" and the shopping list that falls out of it
--=============================================================================

function BS:Wants()
	if not self.db then return {} end
	self.db.craftWant = self.db.craftWant or {}
	return self.db.craftWant
end

function BS:SetWant(name, n)
	n = tonumber(n) or 0
	if n < 0 then n = 0 end

	local wants = self:Wants()
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
	if self.craftCosted then
		for _, c in ipairs(self.craftCosted) do
			if c.name == name then c.want = wants[name] or 0 break end
		end
	end

	self:RefreshCraft()
end

function BS:ClearWants()
	self.db.craftWant = {}
	self.craftCosted  = nil
	self:Print("Cleared every planned quantity.")
	self:RefreshCraft()
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
]]
function BS:ShoppingList()
	local need, order = {}, {}

	for name, want in pairs(self:Wants()) do
		local r = self:Recipes()[name]
		if r and want > 0 then
			-- a recipe that makes two per craft needs half as many crafts
			local per    = ((r.minMade or 1) + (r.maxMade or r.minMade or 1)) / 2
			local crafts = math.ceil(want / math.max(per, 1))

			for _, reagent in ipairs(r.reagents or {}) do
				local e = need[reagent.name]
				if not e then
					e = {
						name   = reagent.name,
						link   = reagent.link,
						vendor = VENDOR_REAGENTS[reagent.name] and true or false,
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

-- every known recipe, costed and sorted dearest profit first
function BS:CostAll()
	local list, wants = {}, self:Wants()
	for _, r in pairs(self:Recipes()) do
		local c = self:CostRecipe(r)
		c.want = wants[r.name] or 0
		list[#list + 1] = c
	end

	sort(list, function(a, b)
		local ap = a.profit or -math.huge
		local bp = b.profit or -math.huge
		if ap == bp then return (a.name or "") < (b.name or "") end
		return ap > bp
	end)

	self.craftCosted = list
	return list
end

-- printed version, for people who would rather not open a panel
function BS:PrintCrafts()
	local list = self:CostAll()
	if #list == 0 then
		self:Print("No recipes on file. Open your alchemy window, then press Craft.")
		return
	end

	self:Print(format("%d recipe%s, dearest first:", #list, #list == 1 and "" or "s"))
	for i = 1, math.min(#list, 15) do
		local c = list[i]
		if c.profit then
			self:Print(format("   %s  makes %s  costs %s  |cff%s%s%s|r%s",
				c.link or c.name,
				BS.Money(c.revenue or 0), BS.Money(c.cost),
				c.profit >= 0 and "00ff00" or "ff4444",
				c.profit >= 0 and "+" or "-", BS.MoneyPlain(math.abs(c.profit)),
				c.exact and "" or "  |cffff8800(estimate)|r"))
		else
			self:Print(format("   %s  costs %s  |cffff8800no profit figure: %s|r",
				c.link or c.name, BS.Money(c.cost), c.doubts[1] or "prices missing"))
		end
	end
end
