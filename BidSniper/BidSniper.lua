--[[--------------------------------------------------------------------------
	BidSniper - core scan engine

	Finds auctions where the current bid is far below the buyout, e.g.
	1s bid / 15g buyout.  Written for WoW 3.3.5a (WotLK / Warmane).
----------------------------------------------------------------------------]]

BidSniper = {}
local BS = BidSniper

local ITEMS_PER_PAGE   = 50		-- NUM_AUCTION_ITEMS_PER_PAGE, hardcoded so we
					-- don't depend on Blizzard_AuctionUI being loaded
local MAX_RESULTS_HARD = 2000		-- safety cap on stored matches
local MAX_PAGES        = 2000		-- safety cap on paged scans
local QUERY_TIMEOUT    = 15		-- seconds before a query is considered lost

BS.defaults = {
	minRatio    = 10,		-- buyout / bid must be at least this
	maxBid      = 500000,		-- copper; 0 = no limit  (default 50g)
	minBuyout   = 10000,		-- copper; ignore junk    (default 1g)
	minQuality  = 0,		-- 0 = poor and up
	minProfit   = 0,		-- copper; Select all skips rows worth less than this
	hideOwn     = true,		-- hide my own auctions / auctions I lead
	onlyNoBids  = false,		-- only auctions nobody has bid on yet
	endingSoon  = false,		-- only time left Short or Medium
	autoShow    = true,		-- open the window with the auction house
	autoCheckBids = true,		-- reconcile the bid ledger on arriving at the AH
	scanMethod  = "auto",		-- auto | paged | getall
	categories  = {},		-- set of auction class indices; empty = all of them
	subcats     = {},		-- class index -> set of subclass indices
	catExpanded = {},		-- which classes are opened out in the panel
	wishlist    = {},		-- item names to check on a wishlist scan
	recipes     = {},		-- flask/elixir recipes read from your tradeskill window
	craftPrices = {},		-- item name -> { unit, qty, t } harvested by a scan
	craftWant   = {},		-- recipe name -> how many you plan to make
	piggyback   = true,		-- read another addon's full scan as if it were ours
	priceCache  = {},		-- item name -> { v = unit price, t = when }
	knownChars  = {},		-- every character of yours that has logged in
	bidLog      = {},		-- every bid placed, and what became of it
	sortKey     = "ratio",
	sortDesc    = true,
	point       = nil,		-- window position
}

BS.results  = {}
BS.scanning = false
BS.atAH     = false

--=============================================================================
--  helpers
--=============================================================================

local floor, format, sort = math.floor, string.format, table.sort

function BS:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99BidSniper|r: " .. tostring(msg))
end

--[[
	Is the bid ledger actually loaded?

	WoW reads an addon's file list from the .toc once, when the client starts.
	/reload re-runs the files already on that list but never notices a new one,
	so a BidSniperLedger.lua added mid-session is simply not there however many
	times you reload - the client has to be restarted.

	Everything that touches the ledger asks this first, so that case costs you
	one clear line instead of a nil-call from every direction.
]]
function BS:HasLedger()
	return type(self.Ledger) == "function"
end

function BS:NoLedger()
	self:Print("|cffff4444The bid ledger did not load.|r BidSniperLedger.lua is listed "
		.. "in the .toc, but WoW only reads that list when the client starts - "
		.. "|cffffd700fully exit and restart the game|r. A /reload will not do it.")
end

-- 1234567 -> "1,234,567"
function BS.Comma(n)
	local s = tostring(floor(n))
	local k
	repeat
		s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

-- compact coloured money string, e.g. "15g 23s" / "1s 50c" / "34c"
function BS.Money(c)
	c = floor(tonumber(c) or 0)
	local sign = ""
	if c < 0 then sign, c = "-", -c end
	local g = floor(c / 10000)
	local s = floor((c % 10000) / 100)
	local cc = c % 100
	if g > 0 then
		return format("%s|cffffd700%s|rg |cffc7c7cf%d|rs", sign, BS.Comma(g), s)
	elseif s > 0 then
		return format("%s|cffc7c7cf%d|rs |cffeda55f%d|rc", sign, s, cc)
	end
	return format("%s|cffeda55f%d|rc", sign, cc)
end

-- plain, exactly re-parseable money text for edit boxes: "15g", "1g23s45c"
function BS.MoneyPlain(c)
	c = floor(tonumber(c) or 0)
	if c == 0 then return "0" end
	local sign = ""
	if c < 0 then sign, c = "-", -c end
	local g  = floor(c / 10000)
	local s  = floor((c % 10000) / 100)
	local cc = c % 100
	local out = sign
	if g > 0  then out = out .. BS.Comma(g) .. "g" end
	if s > 0  then out = out .. s .. "s" end
	if cc > 0 then out = out .. cc .. "c" end
	return out
end

-- "15g", "1s50c", "250" -> copper.  Plain numbers are read as gold.
function BS.ParseMoney(text)
	if not text then return nil end
	text = string.lower(string.gsub(text, "[%s,]", ""))
	if text == "" then return 0 end

	if string.find(text, "[gsc]") then
		local copper = 0
		local matched = false
		for amount, unit in string.gmatch(text, "(%d+%.?%d*)([gsc])") do
			amount = tonumber(amount) or 0
			if unit == "g" then copper = copper + amount * 10000
			elseif unit == "s" then copper = copper + amount * 100
			else copper = copper + amount end
			matched = true
		end
		if not matched then return nil end
		return floor(copper)
	end

	local gold = tonumber(text)
	if not gold then return nil end
	return floor(gold * 10000)
end

BS.timeLeftText = { "|cffff5555<30m|r", "|cffffcc00<2h|r", "<12h", ">12h" }

-- Longest an auction with that time-left bracket can still be around for.
-- Once a result is older than its bracket the auction has certainly ended,
-- whether it sold, was bought out, or was cancelled.
local MAX_LIFE = { 30 * 60, 2 * 3600, 12 * 3600, 48 * 3600 }

-- the bid ledger bounds its own entries the same way
BS.MAX_LIFE = MAX_LIFE

function BS.Expired(r)
	if not r.seen then return false end		-- scanned before we recorded ages
	return (time() - r.seen) > (MAX_LIFE[r.timeLeft or 4] or MAX_LIFE[4])
end

-- How stale a row is, as a fraction of its remaining life. Used to warn about
-- rows that are probably gone without claiming they certainly are.
function BS.Doubtful(r)
	if not r.seen then return false end
	return (time() - r.seen) > (MAX_LIFE[r.timeLeft or 4] or MAX_LIFE[4]) * 0.5
end

-- Auctionator's price database, if the user has it loaded
function BS.MarketValue(link)
	if not link or type(Atr_GetAuctionBuyout) ~= "function" then return nil end
	local ok, value = pcall(Atr_GetAuctionBuyout, link)
	if ok and type(value) == "number" and value > 0 then return value end
	return nil
end

--[[
	Prices are cached by item name in saved variables. Two reasons: the Profit
	column fills in the moment a saved scan loads instead of asking Auctionator
	for every row again, and an item whose price we learned last week still
	reads sensibly if Auctionator's own data is not loaded yet.

	Entries carry a timestamp and are thrown away after a day, so the cache
	cannot quietly serve prices from a different market.
]]
local PRICE_TTL = 24 * 3600
local NO_PRICE_TTL = 10 * 60	-- "no price known" expires fast: Auctionator's
				-- own database may fill in at any moment

local function CacheTTL(entry)
	return (entry.v and entry.v > 0) and PRICE_TTL or NO_PRICE_TTL
end

function BS:PrunePriceCache()
	local cache = self.db.priceCache
	if not cache then self.db.priceCache = {} return end

	local now = time()
	for name, entry in pairs(cache) do
		if type(entry) ~= "table" or not entry.t or (now - entry.t) > CacheTTL(entry) then
			cache[name] = nil
		end
	end
end

-- forget every cached price and recompute; for after an Auctionator scan
function BS:ClearPriceCache()
	self.db.priceCache = {}
	for _, r in ipairs(self.results) do r.market, r.profit = nil, nil end
	self:Print("Cleared cached prices - the Profit column will rebuild.")
	self:UpdateUI()
end

-- unit price for an item, from the cache when it is fresh enough
function BS:CachedUnitPrice(r)
	local key = r.name
	if not key then return nil end

	local cache = self.db.priceCache
	if not cache then cache = {} self.db.priceCache = cache end

	local entry = cache[key]
	local now   = time()
	if entry and entry.t and (now - entry.t) <= CacheTTL(entry) then
		return (entry.v > 0) and entry.v or nil
	end

	local unit = BS.MarketValue(r.link or key)
	cache[key] = { v = unit or 0, t = now }
	return unit
end

--[[
	What the row is worth and what you stand to make on it.

	Both count the whole row. A row is one deal and stands for every identical
	auction at its price, so eight bags worth 60g over the bid each are a 480g
	row - and sorting by Profit is how you decide what to go for, which only
	works if the number is the whole opportunity rather than one eighth of it.

	`unitMarket` and `unitProfit` keep the per-auction figures for the tooltip,
	which is where the arithmetic gets shown.

	Counted from what is *left*: bidding four of the eight leaves four still to
	take, and the row's remaining opportunity is what the column is for. Both
	stay nil when there is no price - an unknown item must not read as a huge
	loss, and it must not read as a huge win either.
]]
function BS:FillValue(r)
	local left = self:CopiesLeft(r)

	-- the multiplier moves as copies are found and bid on, so a filled row is
	-- only still valid for the number it was filled for
	if r.market ~= nil and r.valueFor == left then return end
	r.valueFor = left

	local unit = self:CachedUnitPrice(r)
	if unit then
		r.unitMarket = unit * r.count
		r.unitProfit = r.unitMarket - r.bid
		r.market     = r.unitMarket * left
		r.profit     = r.unitProfit * left
	else
		r.unitMarket, r.unitProfit = 0, nil
		r.market = 0
		r.profit = nil
	end
end

function BS:FillAllValues()
	for _, r in ipairs(self.results) do self:FillValue(r) end
end

--=============================================================================
--  wishlist
--=============================================================================

-- Accepts a typed name or a pasted/shift-clicked item link, from which the
-- name inside the brackets is taken.
function BS.CleanItemName(text)
	if not text then return nil end
	local name = string.match(text, "|h%[(.-)%]|h") or text
	name = string.gsub(name, "^%s*(.-)%s*$", "%1")
	if name == "" then return nil end
	return name
end

function BS:WishlistAdd(text)
	local name = BS.CleanItemName(text)
	if not name then
		self:Print("Type an item name, or shift-click an item to paste its link.")
		return false
	end

	local lower = string.lower(name)
	for _, existing in ipairs(self.db.wishlist) do
		if string.lower(existing) == lower then
			self:Print("\"" .. name .. "\" is already on your wishlist.")
			return false
		end
	end

	table.insert(self.db.wishlist, name)
	sort(self.db.wishlist, function(a, b) return string.lower(a) < string.lower(b) end)
	self:Print("Added \"" .. name .. "\" to your wishlist.")
	self:RefreshWishlist()
	return true
end

function BS:WishlistRemove(index)
	local name = self.db.wishlist[index]
	if not name then return end
	table.remove(self.db.wishlist, index)
	self:Print("Removed \"" .. name .. "\" from your wishlist.")
	self:RefreshWishlist()
end

--=============================================================================
--  scanning
--=============================================================================

local ev = CreateFrame("Frame", "BidSniperEventFrame")

-- keep the saved copy pointing at the live table
function BS:SetResults(t)
	self.results = t
	self.lastTickIndex = nil		-- old row numbers mean nothing now

	-- the index a scan uses to spot a deal it already has a row for, rebuilt
	-- here so a resumed scan groups its new rows with the ones already listed
	self.resultKeys = {}
	for _, r in ipairs(t) do
		if r.groupKey then self.resultKeys[r.groupKey] = r end
	end

	if BidSniperDB then BidSniperDB.lastResults = t end
end

--[[
	How many of this deal are still worth a bid: what the last count found, less
	what we have bid on since.

	A scan's count is only ever a floor - it is the number that gets stepped
	over - so a row carrying one is always worth at least one attempt, and the
	lookup at bid time settles it. A count taken from a fresh search of that one
	item is a real answer, and when it says none are left that is believed.
]]
function BS:CopiesLeft(r)
	local left = (r.copies or 1) - (r.bidsDone or 0)
	if r.counted then return math.max(0, left) end
	return math.max(1, left)
end

-- Ask the server to sort the browse list by current bid, cheapest first.
-- SortAuctionItems toggles, so we may have to call it twice (same trick TSM uses).
function BS:ApplyBidSort()
	if type(SortAuctionItems) ~= "function" then return false end
	if not pcall(SortAuctionItems, "list", "bid") then return false end

	if type(IsAuctionSortReversed) == "function" then
		if IsAuctionSortReversed("list", "bid") then
			if not pcall(SortAuctionItems, "list", "bid") then return false end
		end
		return not IsAuctionSortReversed("list", "bid")
	end
	return true
end

-- The auction house's own category list, fetched once it is available.
function BS:CategoryNames()
	if not self.categoryNames then
		local ok, t = pcall(function() return { GetAuctionItemClasses() } end)
		if ok and t and #t > 0 then self.categoryNames = t end
	end
	return self.categoryNames
end

function BS:CategoryLabel(index)
	if not index or index == 0 then return "All categories" end
	local names = self:CategoryNames()
	return (names and names[index]) or ("Category " .. index)
end

-- Subclass names for a class, asked for once and kept. GetAuctionItemSubClasses
-- is only answered while the auction house is open, so a failure is not cached
-- as "none" - false means "there genuinely are none".
function BS:SubCategoryNames(classIndex)
	self.subNames = self.subNames or {}
	if self.subNames[classIndex] == nil then
		local ok, t = pcall(function() return { GetAuctionItemSubClasses(classIndex) } end)
		if ok and t and #t > 0 then
			self.subNames[classIndex] = t
		elseif ok then
			self.subNames[classIndex] = false
		end
	end
	local t = self.subNames[classIndex]
	return (t and t ~= false) and t or nil
end

function BS:SubCategoryLabel(classIndex, subIndex)
	local subs = self:SubCategoryNames(classIndex)
	return (subs and subs[subIndex]) or ("Subcategory " .. subIndex)
end

-- the chosen classes, lowest index first
function BS:SelectedCategories()
	local chosen = {}
	for index, on in pairs(self.db.categories or {}) do
		if on then chosen[#chosen + 1] = index end
	end
	sort(chosen)
	return chosen
end

function BS:SelectedSubCategories(classIndex)
	local chosen = {}
	local set = self.db.subcats and self.db.subcats[classIndex]
	if set then
		for index, on in pairs(set) do
			if on then chosen[#chosen + 1] = index end
		end
	end
	sort(chosen)
	return chosen
end

-- every class that contributes to a scan, whether whole or by subclass
function BS:ActiveClasses()
	local seen, list = {}, {}
	for _, index in ipairs(self:SelectedCategories()) do
		if not seen[index] then seen[index] = true list[#list + 1] = index end
	end
	for index in pairs(self.db.subcats or {}) do
		if #self:SelectedSubCategories(index) > 0 and not seen[index] then
			seen[index] = true
			list[#list + 1] = index
		end
	end
	sort(list)
	return list
end

function BS:CategorySummary()
	local classes = self:ActiveClasses()
	if #classes == 0 then return "All categories" end

	local parts, subTotal = {}, 0
	for _, index in ipairs(classes) do
		local subs = self:SelectedSubCategories(index)
		if #subs > 0 then
			subTotal = subTotal + #subs
			parts[#parts + 1] = format("%s (%d)", self:CategoryLabel(index), #subs)
		else
			parts[#parts + 1] = self:CategoryLabel(index)
		end
	end

	if #parts == 1 then return parts[1] end
	if #parts == 2 then return parts[1] .. ", " .. parts[2] end
	return format("%d categories%s", #parts,
		subTotal > 0 and (", " .. subTotal .. " subcategories") or "")
end

-- A scan is a queue of queries. Normally one ("everything", or one category),
-- but a wishlist scan is one query per item on the list.
function BS:BuildQueries(mode)
	local list = {}

	if mode == "wishlist" then
		for _, name in ipairs(self.db.wishlist) do
			if name and name ~= "" then
				list[#list + 1] = { name = name, label = name }
			end
		end
	else
		-- One query per chosen class, or one per subclass where any subclass
		-- of that class is ticked. Nothing ticked means one sweep of the lot.
		local classes = self:ActiveClasses()
		if #classes == 0 then
			list[1] = { name = "", label = "All categories" }
		else
			for _, index in ipairs(classes) do
				local subs = self:SelectedSubCategories(index)
				if #subs > 0 then
					for _, subIndex in ipairs(subs) do
						list[#list + 1] = {
							name          = "",
							classIndex    = index,
							subclassIndex = subIndex,
							label = self:CategoryLabel(index) .. " - "
							        .. self:SubCategoryLabel(index, subIndex),
						}
					end
				else
					list[#list + 1] = {
						name       = "",
						classIndex = index,
						label      = self:CategoryLabel(index),
					}
				end
			end
		end
	end

	return list
end

--[[
	GetAll hands back the entire auction house and ignores the query's filters,
	which is why choosing categories used to force the slow paged scan. It does
	not have to: we can take the fast dump and sort the categories out
	ourselves, because every auction's item carries its own class.

	This builds the lookup once per scan - class name -> true for a whole
	class, or a set of subclass names - so the check per auction is one table
	read. Returns nil when nothing is selected, meaning "keep everything".
]]
function BS:BuildCategoryMatcher()
	local classes = self:ActiveClasses()
	if #classes == 0 then return nil end

	local matcher = {}
	for _, index in ipairs(classes) do
		local subs = self:SelectedSubCategories(index)
		if #subs == 0 then
			matcher[self:CategoryLabel(index)] = true
		else
			local set = {}
			for _, subIndex in ipairs(subs) do
				set[self:SubCategoryLabel(index, subIndex)] = true
			end
			matcher[self:CategoryLabel(index)] = set
		end
	end
	return matcher
end

--[[
	Item class and subclass, cached by name: a full sweep sees the same items
	over and over, and GetItemInfo is far too slow to call per auction.

	Takes the row index rather than the link, so the link is built only when the
	cache misses. It used to be built by the caller for every row, which meant a
	GetAll paid for forty thousand item links to answer a question the cache had
	already answered for all but a few hundred of them.
]]
function BS:ItemClass(name, index)
	local cache = self.classCache
	if not cache then cache = {} self.classCache = cache end

	local hit = cache[name]
	if hit ~= nil then
		if hit == false then return nil end
		return hit[1], hit[2]
	end

	local link = index and GetAuctionItemLink("list", index)
	local _, _, _, _, _, itemType, itemSubType = GetItemInfo(link or name)
	if itemType then
		cache[name] = { itemType, itemSubType }
		return itemType, itemSubType
	end

	cache[name] = false		-- not in the client's item cache this scan
	return nil
end

local FILTER_KEYS = { "minRatio", "maxBid", "minBuyout", "minQuality",
                      "hideOwn", "onlyNoBids", "endingSoon" }

-- categories are a set, so compare them as a sorted string rather than by
-- table identity, which would always look different
local function CategorySignature(db)
	local parts = {}
	for index, on in pairs(db.categories or {}) do
		if on then parts[#parts + 1] = "c" .. index end
	end
	for index, set in pairs(db.subcats or {}) do
		for subIndex, on in pairs(set) do
			if on then parts[#parts + 1] = "s" .. index .. "." .. subIndex end
		end
	end
	sort(parts)
	return table.concat(parts, ",")
end

-- Remember where an interrupted scan got to, so it can pick up rather than
-- start the whole auction house again. Only paged scans have a position worth
-- keeping: a GetAll is one request, there is no halfway through it.
function BS:SaveResume()
	local partway = (self.page and self.page > 0) or ((self.queryIndex or 1) > 1)
	if self.useGetAll or not partway then
		self.db.resume = nil
		return
	end

	local filters = { categorySig = CategorySignature(self.db) }
	for _, k in ipairs(FILTER_KEYS) do filters[k] = self.db[k] end

	self.db.resume = {
		page       = self.page,
		queryIndex = self.queryIndex or 1,
		queryLabel = (self.queries and self.queries[self.queryIndex or 1]
		              and self.queries[self.queryIndex or 1].label) or nil,
		mode       = self.scanMode,
		scanned    = self.scannedCount or 0,
		total      = self.totalAuctions or 0,
		matches    = #self.results,
		time       = time(),
		filters    = filters,
	}
end

function BS:ResumeInfo()
	local res = self.db and self.db.resume
	if not res then return nil end
	local pages = res.total > 0 and math.ceil(res.total / ITEMS_PER_PAGE) or 0
	return res, res.page + 1, pages
end

local function FiltersChanged(saved, db)
	if not saved then return false end
	if saved.categorySig and saved.categorySig ~= CategorySignature(db) then return true end
	for _, k in ipairs(FILTER_KEYS) do
		if saved[k] ~= db[k] then return true end
	end
	return false
end

function BS:StartScan(resume, mode)
	if self.scanning then return end
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end

	local canQuery, canQueryAll = CanSendAuctionQuery()

	local res = resume and self.db.resume or nil
	mode = res and res.mode or mode or "normal"
	self.scanMode = mode

	-- every row this scan reads gets checked against the bid ledger on its way
	-- past, which costs nothing and is the quickest way to settle a bid
	if self:HasLedger() then self:BuildLedgerWatch() end

	-- and against the reagents your recipes need, on the same free terms
	if self.BuildCraftWatch then self:BuildCraftWatch() end

	-- Decide the method before building the queries: a GetAll is a single
	-- request whatever the filters say, and the categories get applied to the
	-- results instead.
	local method = self.db.scanMethod
	local getAllUsable = not res and mode == "normal"
	self.useGetAll = getAllUsable
	                 and ((method == "getall") or (method == "auto" and canQueryAll))
	if self.useGetAll and not canQueryAll then self.useGetAll = false end

	-- Never leave this silent. A scan quietly choosing the slow path looks
	-- like the addon is broken, so say which one it is and why.
	if self.useGetAll then
		self:Print("|cff00ff00Fast scan|r (GetAll) - the whole auction house in one request.")
	elseif method == "thorough" then
		self:Print("|cff00ff00Thorough scan|r - every page, unsorted, no early stop. "
			.. "Slow, but it will not step over auctions.")
	else
		local why
		if res then
			why = "resuming an interrupted scan"
		elseif mode == "wishlist" then
			why = "a wishlist scan searches item by item"
		elseif method == "paged" then
			why = "scan method is set to paged - use |cffffffff/snipe auto|r for the fast one"
		elseif not canQueryAll then
			why = "GetAll is on cooldown, up to 15 minutes between full sweeps"
		else
			why = "GetAll is unavailable"
		end
		self:Print("|cffff8800Paged scan|r - " .. why
			.. ". This can step over auctions; |cffffffff/snipe thorough|r reads every one.")
	end

	if self.useGetAll then
		self.queries  = { { name = "", label = "everything" } }
		self.catMatch = self:BuildCategoryMatcher()
	else
		self.queries  = self:BuildQueries(mode)
		self.catMatch = nil		-- the server filters a paged scan for us
	end
	self.queryIndex   = 1
	self.classCache   = {}
	self.unclassified = 0

	if #self.queries == 0 then
		self:Print("Your wishlist is empty - add some items to it first.")
		return
	end

	if res then
		self.queryIndex = math.min(res.queryIndex or 1, #self.queries)
		self.page       = res.page

		-- the wishlist may have been edited since; if this slot no longer
		-- holds what it did, start that item from its first page
		local q = self.queries[self.queryIndex]
		if res.queryLabel and q and q.label ~= res.queryLabel then
			self:Print("The list being scanned changed since that scan stopped, "
				.. "so \"" .. q.label .. "\" restarts from the beginning.")
			self.page = 0
		end

		if FiltersChanged(res.filters, self.db) then
			self:Print("Note: your filters changed since that scan stopped, so the "
				.. "older results were matched against different settings.")
		end
		self.scannedCount = res.scanned or 0
		self:Print(format("Resuming at page %d, keeping %d result%s already found.",
			res.page + 1, #self.results, #self.results == 1 and "" or "s"))
	else
		self:SetResults({})
		self.page         = 0
		self.scannedCount = 0
	end
	self.db.resume      = nil
	self.totalAuctions  = 0
	self.totalPages     = nil
	self.lastPageSig    = nil
	self.dupRetries     = 0
	self.truncated      = false
	self.stoppedEarly   = false
	self.retries        = 0
	self.throttle       = 0
	self.scanning       = true
	self.queryPending   = true
	self.awaitingResults= false
	self.processing     = false
	self.scanStart      = GetTime()

	--[[
		Whether to have the server sort the list before we page through it.

		Sorting cheapest-bid-first is what makes a paged scan quick: the
		auctions you care about arrive first, and once bids pass your max bid
		nothing later is worth reading.

		It also makes a paged scan lossy, and in a very specific way. Paging
		walks a live server-side list by index, so anything posted, bought or
		bid on mid-scan shifts every later row and a page boundary swallows
		whatever it stepped over. Sorting by bid makes that far worse, because
		auctions sharing a bid are tied: several identical listings from one
		seller sit adjacent with no stable order between one page request and
		the next, so a boundary landing inside that run drops part of it. Five
		identical orbs going in and one coming out is exactly this.

		"thorough" gives that up - no sort, no early stop, every page read - in
		exchange for seeing everything. GetAll sidesteps the whole problem by
		not paging at all, and is still the best answer where it is available.
	]]
	self.sorted = false
	if self.useGetAll or self.db.scanMethod == "thorough" then
		SortAuctionClearSort("list")
	else
		self.sorted = self:ApplyBidSort()
		if not self.sorted then SortAuctionClearSort("list") end
	end

	self:UpdateUI()
	self:SetStatus(self.useGetAll and "Requesting full auction list..."
		or self:ScanStatusText())
end

function BS:StopScan(reason)
	if not self.scanning then return end
	self.scanning     = false
	self.queryPending = false
	self.awaitingResults = false
	self.processing   = false

	-- a scan that stopped part way proves nothing about what it never reached,
	-- so it keeps what it found and closes nothing
	if self:HasLedger() then self:LedgerScanFinished(false) end

	-- prices are different: a row it did read is a row it really saw, and half
	-- a sweep of reagent prices still beats none
	if self.CraftScanFinished then self:CraftScanFinished() end

	self:SaveResume()
	local res, nextPage, pages = self:ResumeInfo()

	if res then
		self:SetStatus(format("%s  |cffffd100Stopped at page %d%s - Resume, or Scan AH to start over.|r",
			reason or "Scan stopped.", nextPage,
			pages > 0 and (" of " .. pages) or ""))
	else
		self:SetStatus(reason or "Scan cancelled.")
	end
	self:UpdateUI()
end

function BS:FinishScan()
	local shared = self.piggybacking

	self.scanning     = false
	self.queryPending = false
	self.awaitingResults = false
	self.processing   = false
	self.piggybacking = nil

	self:SortResults()

	self.db.lastScanTime = time()
	self.db.resume       = nil		-- finished: nothing left to resume

	--[[
		Only a scan that read every auction can prove one is gone. GetAll always
		does; a paged scan does too, but only with no categories narrowing it
		and no early stop at your max bid. A wishlist or resumed scan never
		does. Anything less did not look everywhere, so it settles what it found
		and stays quiet about what it did not.
	]]
	if self:HasLedger() then
		self:LedgerScanFinished(self.scanMode == "normal" and not self.stoppedEarly
			and (self.useGetAll or #self:ActiveClasses() == 0))
	end

	-- reagent prices this sweep picked up on its way through
	local priced = self.CraftScanFinished and self:CraftScanFinished() or 0
	if priced and priced > 0 then
		self:Print(format("Priced |cffffffff%d|r crafting item%s from that scan "
			.. "(no extra queries) - the Craft tab is up to date.",
			priced, priced == 1 and "" or "s"))
	end

	-- identical auctions share a row, so the row count and the number of
	-- auctions behind it are different figures and both are worth saying
	local copies = 0
	for _, r in ipairs(self.results) do copies = copies + (r.copies or 1) end

	local secs = GetTime() - (self.scanStart or GetTime())
	self:SetStatus(format("%s%d match%s%s in %s auctions  (%.0fs)%s%s",
		shared and "|cff00ff00[shared scan]|r  " or "",
		#self.results,
		#self.results == 1 and "" or "es",
		copies > #self.results and format(" (%d auctions)", copies) or "",
		BS.Comma(self.scannedCount),
		secs,
		self.stoppedEarly and "  |cff00ff00[stopped at your max bid]|r" or "",
		self.truncated and "  |cffff5555[capped]|r" or ""))
	self:UpdateUI()

	if self.catMatch and (self.unclassified or 0) > 0 then
		self:Print(format("%s auction%s could not be sorted into a category "
			.. "(the item was not in your client's cache) and were kept rather "
			.. "than dropped.", BS.Comma(self.unclassified),
			self.unclassified == 1 and "" or "s"))
	end

	if #self.results == 0 then
		self:Print("No auctions matched your filters. Try lowering the ratio or raising the max bid.")
	end
end

-- reads one auction row and stores it if it passes the filters
function BS:Evaluate(index)
	local name, texture, count, quality, canUse, level, minBid, minIncrement,
	      buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", index)

	if not name then return end

	count        = count or 1
	bidAmount    = bidAmount or 0
	minIncrement = minIncrement or 0
	minBid       = minBid or 0
	buyoutPrice  = buyoutPrice or 0

	--[[
		Settle bid-ledger entries from rows the scan was reading anyway. This
		sits ahead of every filter and ahead of the no-buyout guard on purpose:
		an auction you bid on is worth recognising whether or not it still
		passes your ratio, your max bid or your categories, and a bid you placed
		by hand on an auction with no buyout is still a bid. The name check
		first keeps this to one string lookup for the overwhelming majority of
		rows.
	]]
	if self.ledgerWatchNames and self.ledgerWatchNames[name] then
		self:LedgerSawAuction(
			BS.BidKey(GetAuctionItemLink("list", index), name, count, minBid, buyoutPrice),
			minBid, bidAmount, minIncrement, highBidder)
	end

	--[[
		And the reagent prices the crafting tab runs on, from the same row, on
		the same terms: one hash lookup against a set built before the scan
		started, and no work at all for a name that is not in it. Ahead of the
		filters because reagents are cheap bulk goods - min buyout and min ratio
		would throw away every one of them.
	]]
	if self.craftWatchNames and self.craftWatchNames[name] then
		self:CraftSawAuction(name, count, buyoutPrice)
	end

	-- no buyout, no ratio: nothing here can judge whether it is a bargain
	if buyoutPrice <= 0 then return end

	-- what you would actually have to pay to be the high bidder right now
	local bid = (bidAmount > 0) and (bidAmount + minIncrement) or minBid
	if bid <= 0 or bid >= buyoutPrice then return end

	--[[
		Cheapest test first, dearest last. Every filter below is arithmetic on
		numbers already in hand, and between them they throw away the great bulk
		of the auction house - so they run before the two tests that cost a call
		into the client: the time-left bracket, and the category lookup that has
		to build an item link and ask what the item is.

		Ratio leads because it is both free and the most selective thing here.
	]]
	local cfg = self.db

	local ratio = buyoutPrice / bid
	if ratio < cfg.minRatio then return end

	if cfg.onlyNoBids and bidAmount > 0 then return end
	if cfg.hideOwn then
		if highBidder then return end
		-- every character of yours that has logged in, not just this one:
		-- bidding on your own alt's auction is the same mistake
		if owner and cfg.knownChars and cfg.knownChars[owner] then return end
	end
	if quality and quality < cfg.minQuality then return end
	if buyoutPrice < cfg.minBuyout then return end
	if cfg.maxBid > 0 and bid > cfg.maxBid then return end

	local timeLeft = GetAuctionItemTimeLeft("list", index) or 4
	if cfg.endingSoon and timeLeft > 2 then return end

	-- category filtering for a GetAll, which the server hands over unfiltered
	if self.catMatch then
		local itemType, itemSubType = self:ItemClass(name, index)
		if itemType then
			local rule = self.catMatch[itemType]
			if not rule then return end
			if rule ~= true and not rule[itemSubType] then return end
		else
			-- item not in the client cache, so we cannot say what it is;
			-- keeping it beats silently dropping a real find
			self.unclassified = (self.unclassified or 0) + 1
		end
	end

	--[[
		Several identical auctions at once is the ordinary case, not the odd one:
		a seller listing eight of the same bag makes eight rows this API cannot
		tell apart. 3.3.5a exposes no auction id on the browse list, so two rows
		carrying the same item, stack size, price, seller and time bracket are
		the same thing as far as anything here can see.

		Listing them separately misled in both directions. Eight rows looked like
		eight finds when it was one deal at one price, and bidding a row placed a
		bid on whichever copy the server handed back first - so pressing the same
		row twice bid on two different auctions, which reads as a bug and is the
		single most confusing thing this addon used to do.

		One row per deal, carrying how many are up, is what is actually there.
	]]
	-- the one item link this row pays for, and only because it is a keeper
	local link = GetAuctionItemLink("list", index)
	local key  = format("%s:%d:%d:%d:%d:%s", tostring(link or name), count, bid,
	                    buyoutPrice, timeLeft, tostring(owner or "?"))

	local group = self.resultKeys and self.resultKeys[key]
	if group then
		group.copies = (group.copies or 1) + 1
		group.seen   = time()
		return
	end

	if #self.results >= MAX_RESULTS_HARD then
		self.truncated = true
		return
	end

	local r = {
		link     = link,
		name     = name,
		texture  = texture,
		count    = count,
		quality  = quality or 1,
		level    = level,
		bid      = bid,
		buyout   = buyoutPrice,
		ratio    = ratio,
		timeLeft = timeLeft,
		owner    = owner,
		hasBid   = bidAmount > 0,
		seen     = time(),
		copies   = 1,
		groupKey = key,
	}
	self.results[#self.results + 1] = r
	self.resultKeys = self.resultKeys or {}
	self.resultKeys[key] = r
end

--[[
	Someone else's full scan, read as if it were ours.

	GetAll is one request for the entire auction house and the client allows it
	roughly once every fifteen minutes - and that cooldown is shared by every
	addon on it. So running Auctionator's full scan and then BidSniper's meant
	waiting a quarter of an hour between two sweeps of exactly the same data.

	It does not have to be that way. The dump lands in the auction list that all
	addons read, so when one arrives that we did not ask for, we can walk it too.
	Press Auctionator's full scan and this fills in beside it: same request, same
	data, both sets of answers, one cooldown.

	The tell is the size. A page query answers with fifty rows at most; anything
	larger than a page is a dump, and nothing else produces one.
]]
function BS:MaybePiggyback()
	if not self.db.piggyback or not self.atAH then return end
	if self.scanning or self.processing or self.batch
	   or self.bidSearch or self.ledgerSweep then return end

	local numBatch, total = GetNumAuctionItems("list")
	if not numBatch or numBatch <= ITEMS_PER_PAGE then return end

	-- the same dump arriving twice is one scan, not two
	if self.piggybackCount == numBatch
	   and (GetTime() - (self.piggybackAt or 0)) < 60 then return end

	self.piggybackAt    = GetTime()
	self.piggybackCount = numBatch

	self:Print(format("|cff00ff00Reading another addon's full scan|r - %s auctions, "
		.. "no second request and no second cooldown.", BS.Comma(numBatch)))

	-- everything a GetAll of our own would have set up, minus the request
	self.scanMode     = "normal"
	self.useGetAll    = true
	self.piggybacking = true
	self.catMatch     = self:BuildCategoryMatcher()
	self.classCache   = {}
	self.unclassified = 0
	self.queries      = { { name = "", label = "everything" } }
	self.queryIndex   = 1
	self.page         = 0
	self.totalPages   = nil
	self.truncated    = false
	self.stoppedEarly = false
	self.scannedCount = 0
	self.scanStart    = GetTime()
	self.db.resume    = nil

	if self:HasLedger() then self:BuildLedgerWatch() end
	if self.BuildCraftWatch then self:BuildCraftWatch() end

	self:SetResults({})

	self.batchCount = numBatch
	self.totalAuctions = total or numBatch
	self.readIndex  = 1
	self.processing = true		-- OnUpdate takes it from here, a slice at a time
	self:SetStatus(format("Reading a shared full scan: %s auctions...",
		BS.Comma(numBatch)))
	self:UpdateUI()
end

-- Cheap fingerprint of the loaded page. Auctions being posted and bought
-- while we page through can make the server hand back a page we have already
-- read; re-asking is better than counting it twice.
function BS:PageSignature()
	local n = GetNumAuctionItems("list") or 0
	if n == 0 then return "empty" end

	local parts = { n }
	for _, i in ipairs({ 1, math.ceil(n / 2), n }) do
		local name, _, count, _, _, _, minBid, _, buyout, bidAmount =
			GetAuctionItemInfo("list", i)
		parts[#parts + 1] = table.concat({
			tostring(name), tostring(count), tostring(minBid),
			tostring(buyout), tostring(bidAmount),
		}, ":")
	end
	return table.concat(parts, "|")
end

function BS:ScanStatusText()
	local q = self.queries and self.queries[self.queryIndex]
	local where
	if not q then
		where = format("page %d", (self.page or 0) + 1)
	elseif #self.queries > 1 then
		where = format("%s (%d/%d), page %d",
			q.label, self.queryIndex, #self.queries, self.page + 1)
	elseif self.totalPages and self.totalPages > 0 then
		where = format("page %d/%d", self.page + 1, self.totalPages)
	else
		where = format("page %d", self.page + 1)
	end
	return format("Scanning %s  -  %d match%s", where, #self.results,
		#self.results == 1 and "" or "es")
end

-- read the current batch a slice at a time so the client doesn't freeze
function BS:ProcessChunk()
	--[[
		A smaller bite while sharing someone else's scan. Auctionator is walking
		the same forty thousand rows in the same frames, and two addons each
		taking a thousand a frame is how a full scan turns into a slideshow.
	]]
	local chunk = self.piggybacking and 300
	              or (self.useGetAll and 1000 or ITEMS_PER_PAGE)
	local last  = math.min(self.readIndex + chunk - 1, self.batchCount)

	for i = self.readIndex, last do
		self:Evaluate(i)
	end
	self.readIndex = last + 1

	if self.readIndex > self.batchCount then
		self.processing   = false
		self.scannedCount = self.scannedCount + self.batchCount

		if self.useGetAll then
			self:FinishScan()
			return
		end

		local queryDone = false

		-- Sorted cheapest-bid-first: the last row on the page is the dearest we
		-- have seen, so once it clears the max bid every later page does too.
		if self.sorted and self.db.maxBid > 0 and self.batchCount > 0 then
			local _, _, _, _, _, _, minBid, _, _, bidAmount =
				GetAuctionItemInfo("list", self.batchCount)
			local sortBid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
			if sortBid > self.db.maxBid then
				self.stoppedEarly = true
				queryDone = true
			end
		end

		if not queryDone then
			self.totalPages = math.ceil(self.totalAuctions / ITEMS_PER_PAGE)
			self.page = self.page + 1
			if self.batchCount == 0 or self.page >= self.totalPages
			   or self.page >= MAX_PAGES then
				queryDone = true
			end
		end

		-- finished this query: move on to the next one in the queue
		if queryDone then
			self.queryIndex  = self.queryIndex + 1
			self.page        = 0
			self.totalPages  = nil		-- belongs to the query just finished
			self.lastPageSig = nil
			self.dupRetries  = 0
			if self.queryIndex > #self.queries then
				self:FinishScan()
				return
			end
		end

		self.queryPending = true
		self:SetStatus(self:ScanStatusText())
	elseif self.useGetAll then
		self:SetStatus(format("Processing %s/%s auctions...",
			BS.Comma(self.readIndex - 1), BS.Comma(self.batchCount)))
	end
end

ev:SetScript("OnUpdate", function(self, elapsed)
	-- a tick-box drag ends wherever the button is let go, not just over a row
	if BS.dragging and not IsMouseButtonDown("LeftButton") then
		BS.dragging = nil
	end

	-- the inbox has stopped changing: work out what the mail says about bids
	-- that ended while we were away
	if BS.mailCheckAt and GetTime() >= BS.mailCheckAt then
		BS.mailCheckAt = nil
		BS:ResolveLedgerFromMail(false)
	end

	--[[
		Asking the auction house whether a vanished bid is still up. This runs
		off the same throttle as everything else, and only ever when no scan,
		bid lookup or batch is using the auction list.
	]]
	if BS.ledgerQueryPending then
		BS.ledgerThrottle = BS.ledgerThrottle + elapsed
		if BS.ledgerThrottle > QUERY_TIMEOUT * 2 then
			BS:StopLedgerSweep("Bid check gave up: the server would not take the lookup.")
			return
		end
		if BS.ledgerThrottle >= 0.15 and CanSendAuctionQuery() then
			BS.ledgerThrottle       = 0
			BS.ledgerQueryPending   = false
			BS:LedgerSweepQuery()
		end
		return
	elseif BS.ledgerAwaiting then
		if GetTime() - (BS.ledgerQueryTime or 0) > QUERY_TIMEOUT then
			BS:StopLedgerSweep("Bid check timed out.")
		end
		return
	end

	-- looking up a single auction so we can bid on it
	if BS.bidQueryPending then
		BS.bidThrottle = BS.bidThrottle + elapsed
		-- never sit waiting for a send slot forever
		if BS.bidThrottle > QUERY_TIMEOUT * 2 then
			local inBatch = BS.batch ~= nil
			BS:CancelBidSearch("The server would not take the lookup - skipped.")
			if inBatch then BS:BatchStep("gone") end
			return
		end
		-- give a bid a moment to land before firing the next query at the
		-- server, so the two cannot race over which auction list is current
		if BS.bidThrottle >= 0.15
		   and GetTime() >= (BS.bidQueryEarliest or 0)
		   and CanSendAuctionQuery() then
			BS.bidThrottle       = 0
			BS.bidQueryPending   = false
			BS.bidAwaiting       = true
			BS.bidQueryTime      = GetTime()
			-- loadedQueryName is set when the results actually arrive, not
			-- here: a query that never answers must not leave us believing
			-- the list holds this item.
			QueryAuctionItems(BS.bidSearch.result.name, nil, nil, nil, nil, nil,
				BS.bidSearch.page, nil, nil)
		end
		return
	elseif BS.bidAwaiting then
		if GetTime() - (BS.bidQueryTime or 0) > QUERY_TIMEOUT then
			local inBatch = BS.batch ~= nil
			BS:CancelBidSearch("Lookup timed out.")
			-- a batch carries on rather than stalling on one bad item
			if inBatch then BS:BatchStep("gone") end
		end
		return
	end

	if BS.processing then
		BS:ProcessChunk()
		return
	end
	if not BS.scanning then return end

	if BS.queryPending then
		BS.throttle = BS.throttle + elapsed
		if BS.throttle < 0.15 then return end

		local canQuery, canQueryAll = CanSendAuctionQuery()
		if not canQuery then return end

		if BS.useGetAll and not canQueryAll then
			BS.useGetAll = false
			BS:Print("GetAll is on cooldown, falling back to a page-by-page scan.")
		end

		BS.throttle        = 0
		BS.queryPending    = false
		BS.awaitingResults = true
		BS.queryTime       = GetTime()

		-- a scan replaces the auction list, so no bid lookup can rely on it
		BS.loadedQueryName = nil

		if BS.useGetAll then
			QueryAuctionItems("", nil, nil, 0, 0, 0, 0, 0, 0, true)
		else
			local q = BS.queries[BS.queryIndex] or { name = "" }
			QueryAuctionItems(q.name or "", nil, nil, nil,
				q.classIndex, q.subclassIndex, BS.page, nil, nil)
		end

	elseif BS.awaitingResults then
		if GetTime() - (BS.queryTime or 0) > QUERY_TIMEOUT then
			if BS.useGetAll then
				-- plenty of private servers simply ignore GetAll: start over paged
				BS.useGetAll       = false
				BS.page            = 0
				BS.queryIndex      = 1
				BS.totalPages      = nil
				BS.scannedCount    = 0
				-- paging can filter server-side, so hand the categories back
				BS.queries         = BS:BuildQueries(BS.scanMode)
				BS.catMatch        = nil
				BS.awaitingResults = false
				BS.queryPending    = true
				BS:SetResults({})
				BS.sorted = BS:ApplyBidSort()
				if not BS.sorted then SortAuctionClearSort("list") end
				BS:Print("No answer to the GetAll request - switching to a page-by-page scan.")
				BS:SetStatus("Scanning page 1...")
			else
				BS.retries = BS.retries + 1
				if BS.retries > 3 then
					BS:StopScan("Scan aborted: the server stopped answering.")
				else
					BS.awaitingResults = false
					BS.queryPending    = true
				end
			end
		end
	end
end)

--=============================================================================
--  bidding
--=============================================================================

StaticPopupDialogs["BIDSNIPER_CONFIRM_BID"] = {
	text = "Place a bid of %s on\n%s ?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self)
		BidSniper:VerifyAndBid(self.data)
	end,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

StaticPopupDialogs["BIDSNIPER_CONFIRM_BATCH"] = {
	text = "Bid on %s auctions for up to %s total?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self)
		BidSniper:RunBatch(self.data)
	end,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

local BID_SEARCH_MAX_PAGES = 20

-- step 1: re-query the auction house for this item so we get a live index.
-- auto = place the bid as soon as we find it, no confirmation box.
function BS:BidOn(result, auto)
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end
	if self.scanning then
		self:Print("Wait for the scan to finish first.")
		return
	end
	if self.bidSearch then return end
	if self.batch and not auto then
		self:Print("A batch is running - stop it first.")
		return
	end

	-- The auction house already has this item's results loaded from the last
	-- lookup, so the next few bids on the same item need no server round trip
	-- at all. That is what makes clicking through a batch quick.
	if self.loadedQueryName == result.name then
		self.bidSearch = { result = result, page = self.loadedQueryPage or 0, auto = auto }
		self:LocatePendingBid()
		return
	end

	-- cheapest bid first, so the auction we scanned lands on the first page -
	-- and so a lookup for one that is gone can give up instead of reading the
	-- whole item out to the dearest listing on the house
	self.bidSorted = self:ApplyBidSort()

	self.bidSearch       = { result = result, page = 0, auto = auto }
	self.bidQueryPending = true
	self.bidThrottle     = 0
	self:SetStatus("Looking up " .. (result.link or result.name) .. "...")
end

function BS:CancelBidSearch(reason)
	self.bidSearch       = nil
	self.bidQueryPending = false
	self.bidAwaiting     = false
	if reason then self:SetStatus(reason) end
end

-- Does auction `index` look like the one we scanned?
-- Deliberately does NOT compare the bid (that is what moves) and does NOT
-- compare the seller: GetAuctionItemInfo hands back a nil owner often enough
-- that matching on it loses auctions that are still perfectly biddable.
local function SameAuction(index, r)
	local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", index)
	if name ~= r.name or count ~= r.count or buyout ~= r.buyout then return false end
	if r.link then
		local link = GetAuctionItemLink("list", index)
		if link and link ~= r.link then return false end
	end
	return true
end

--[[
	Write down how many of this deal are really up.

	A scan undercounts runs of identical auctions - a paged scan walks a live
	server-side list by index, and auctions sharing a bid are tied with no stable
	order between one page request and the next, so a page boundary landing
	inside a run steps over part of it. Eight bags going in and four coming out
	is exactly that, and nothing on our side of the connection fixes it.

	The lookup a bid does anyway fixes it for free. Searching one item name does
	not page through the whole house, so the run comes back together, and the
	page is already loaded and already being walked to find the auction to bid
	on. Counting the rest of it costs nothing.

	`seen` is what is still biddable at the row's price, so bids already placed
	are missing from it - hence adding them back. Never counting down from a
	page we have not read is what keeps a half-read lookup from wrongly closing
	a row; nothing left at all is the one case that shrinks it.
]]
function BS:NoteCopies(r, seen)
	local before = r.copies or 1
	local now    = (seen > 0) and math.max(before, (r.bidsDone or 0) + seen)
	                          or (r.bidsDone or 0)

	-- only a batch has a total that was approved before the extras turned up,
	-- so only a batch has anything to report about them
	if now > before and self.batch then
		self.batchExtra = (self.batchExtra or 0) + (now - before)
	end

	r.copies  = now
	r.counted = true
end

-- step 2: results came back - find our auction again
function BS:LocatePendingBid()
	local search = self.bidSearch
	if not search then return end

	local r = search.result

	local numBatch, total = GetNumAuctionItems("list")
	total = total or 0

	-- several identical auctions can be up at once; take the cheapest bid
	local best, bestBid
	local used = self.usedIndices or {}
	for i = 1, numBatch do
		-- our own earlier bid on this page has not been reflected back yet,
		-- so never offer the same row twice from one set of results
		if not used[i] and SameAuction(i, r) then
			local _, _, _, _, _, _, minBid, minIncrement, buyout, bidAmount, highBidder =
				GetAuctionItemInfo("list", i)
			local bid = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid
			-- an auction we are already winning is never one to bid on again:
			-- with several copies up, that is the one way a row could have bid
			-- us up against ourselves
			if not highBidder and bid and bid > 0 and bid < buyout then
				-- free, in the loop that was walking the page regardless
				if bid <= r.bid then search.seen = (search.seen or 0) + 1 end
				if not bestBid or bid < bestBid then best, bestBid = i, bid end
			end
		end
	end

	if best then
		local auto = search.auto
		self:NoteCopies(r, search.seen or 0)
		self:CancelBidSearch()
		self:OfferBid(best, bestBid, r, auto)
		return
	end

	--[[
		Common item names span several pages, so keep looking - but not for ever,
		and not past the point where the answer is already known.

		The list is sorted cheapest current bid first. Our auction's bid is below
		its own buyout, always: an auction dearer to bid on than to buy is not one
		this addon would offer, and LocatePendingBid drops it above. So the moment
		the dearest row on a page costs more to bid on than our auction's whole
		buyout, no later page can be holding it.

		That is the difference between "gone" answering at once and paging out
		through every Abyss Crystal on the house at 800g to decide that a 70g one
		is not there.
	]]
	local pastIt = false
	if self.bidSorted and numBatch > 0 and (r.buyout or 0) > 0 then
		local _, _, _, _, _, _, minBid, _, _, bidAmount =
			GetAuctionItemInfo("list", numBatch)
		local pageBid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
		pastIt = pageBid > r.buyout
	end

	local nextPage = search.page + 1
	if not pastIt and nextPage * ITEMS_PER_PAGE < total
	   and nextPage < BID_SEARCH_MAX_PAGES then
		search.page          = nextPage
		self.bidQueryPending = true
		self:SetStatus(format("Looking up %s (page %d)...", r.name, nextPage + 1))
		return
	end

	-- nothing of this deal is biddable any more, so what we bid on is all there
	-- was: the row settles at that and stops offering more
	self:NoteCopies(r, 0)

	local inBatch = self.batch ~= nil
	self:CancelBidSearch("Auction no longer available.")
	if not inBatch then
		self:Print("That auction is gone - rescan to refresh.")
	end
	self:BatchStep("gone")
end

-- step 3: confirm (or, in auto mode, go straight to the bid)
function BS:OfferBid(index, bid, r, auto)
	local link = GetAuctionItemLink("list", index)
	local name = GetAuctionItemInfo("list", index)

	if GetMoney() < bid then
		self:Print("You cannot afford that bid (" .. BS.Money(bid) .. ").")
		self:SetStatus("Not enough gold for that bid.")
		if self.batch then self:EndBatch("Batch stopped: out of gold.") end
		return
	end

	local data = {
		index = index, bid = bid, link = link, name = name,
		count = r.count, buyout = r.buyout, result = r,
	}

	if auto then
		-- never quietly pay more than the price the row was showing
		if bid > r.bid then
			self:Print("Skipped " .. (link or r.name) .. ": bid rose from "
				.. BS.Money(r.bid) .. " to " .. BS.Money(bid) .. ".")
			self:BatchStep("outbid")
			return
		end
		self:ArmBid(data)
		return
	end

	if bid > r.bid then
		self:Print("Heads up: someone has bid since the scan - it now costs "
			.. BS.Money(bid) .. " instead of " .. BS.Money(r.bid) .. ".")
	end

	local dialog = StaticPopup_Show("BIDSNIPER_CONFIRM_BID", BS.Money(bid), link or r.name)
	if dialog then
		dialog.data = data
		self:SetStatus("Confirm the bid to place it.")
	end
end

--[[
	PlaceAuctionBid is a protected function: the client only lets it through
	while it is handling a mouse click or a key press. Called from a timer or
	an event handler it is silently blocked and the client prints "Interface
	action failed because of an AddOn" - which is exactly why every batched bid
	looked sent and never arrived.

	So a bid is prepared here (query, locate, price check) and then parked as
	"armed". The actual PlaceAuctionBid only ever happens in FireArmedBid,
	which is wired straight to a button's OnClick. One click, one bid: there is
	no way around that, and anything claiming otherwise is not placing bids.
]]
function BS:ArmBid(data)
	self.armed = data
	self:SetStatus(format("Ready: %s for %s  -  press BID",
		data.link or data.name, BS.Money(data.bid)))
	self:UpdateUI()
end

function BS:ClearArmed()
	self.armed = nil
	self:UpdateUI()
end

-- Pass on the auction currently on the button and move to the next one.
-- Also cancels a lookup that is still running, so a slow or stuck one cannot
-- hold up the rest of the queue.
function BS:SkipArmed()
	if self.armed then
		local r = self.armed.result
		self.armed = nil
		if r then
			r.selected = false
			self:Print("Skipped " .. (r.link or r.name) .. ".")
		end
	elseif self.bidSearch then
		local r = self.bidSearch.result
		self:CancelBidSearch()
		if r then
			r.selected = false
			self:Print("Skipped " .. (r.link or r.name) .. " (lookup cancelled).")
		end
	elseif not self.batch then
		return
	end

	self:UpdateUI()

	if self.batch then
		self:BatchStep("skipped")
	else
		self:SetStatus("Skipped.")
	end
end

-- MUST be reached from a real click. Do not call from OnUpdate or an event.
function BS:FireArmedBid()
	local data = self.armed
	if not data then return end
	self.armed = nil

	local placed = self:VerifyAndBid(data)
	if self.batch then
		self:BatchStep(placed and "done" or "failed")
	else
		self:UpdateUI()
	end
end

-- Is the auction sitting at `index` right now the one this bid was armed for?
local function RowIs(listType, index, data)
	if not index then return false end
	local name, _, count, _, _, _, _, _, buyout, _, highBidder =
		GetAuctionItemInfo(listType, index)
	if name ~= data.name or count ~= data.count or buyout ~= data.buyout then
		return false
	end
	-- an auction we are already winning is never one to re-bid
	if listType == "bidder" and highBidder then return false end
	if not data.link then return true end
	local link = GetAuctionItemLink(listType, index)
	return (not link) or link == data.link
end

--[[
	Find the auction this bid was armed for, wherever it has got to.

	Every bid the server accepts refreshes the bidder list, and that refresh
	renumbers it: auctions we have just taken the lead on drop out of the
	outbid set and everything below them shifts up. An index taken when the bid
	was armed is therefore stale about half the time - which is exactly how
	often a re-bid used to be cancelled "for safety", leaving every other
	auction in the queue unbid.

	What makes a bid safe is that it lands on the auction we meant at no more
	than the price we quoted. Position is not part of that, so when the row has
	moved, look the auction up again rather than refusing. Indices already bid
	on stay off limits, so a shift can never put us on the same auction twice.
]]
function BS:RelocateBid(data)
	local listType = data.listType or "list"
	local used = (listType == "bidder") and (self.rebidUsed or {})
	                                    or (self.usedIndices or {})
	local n = GetNumAuctionItems(listType) or 0
	for i = 1, n do
		if not used[i] and RowIs(listType, i, data) then return i end
	end
	return nil
end

-- step 4: re-check the row right before spending, in case the list moved
function BS:VerifyAndBid(data)
	if not data or not self.atAH then return false end

	local listType = data.listType or "list"

	-- prefer where it was; find it again only if it is no longer there
	local index = data.index
	if not RowIs(listType, index, data) then
		index = self:RelocateBid(data)
		if not index then
			self:Print("That auction is no longer on the list - bid cancelled. "
				.. "It has been won, bought out or cancelled.")
			self:SetStatus("Bid cancelled: the auction is gone.")
			return false
		end
	end

	local name, _, count, _, _, _, minBid, minIncrement, buyout, bidAmount =
		GetAuctionItemInfo(listType, index)
	local link = GetAuctionItemLink(listType, index)
	local bid  = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid

	if not bid or bid <= 0 or (buyout > 0 and bid >= buyout) then
		self:Print("That auction can no longer be bid on sensibly - skipped.")
		self:SetStatus("Bid cancelled: nothing sensible left to bid.")
		return false
	end

	--[[
		The price is the guard that actually matters. The same or cheaper is
		fine and needs no comment; dearer means somebody bid since this was
		lined up, and quietly paying more than the figure on the button is
		never something to do on your behalf.
	]]
	if bid > data.bid then
		self:Print(format("Skipped %s: the bid rose from %s to %s since it was lined up.",
			link or name, BS.Money(data.bid), BS.Money(bid)))
		self:SetStatus("Bid cancelled: the price went up.")
		return false
	end

	if GetMoney() < bid then
		self:Print("You cannot afford that bid.")
		return false
	end

	-- PlaceAuctionBid returns nothing and the server rejects silently, so note
	-- what we tried; UI_ERROR_MESSAGE just after this tells us if it refused.
	self.lastBidTime       = GetTime()
	self.lastBidResult     = data.result
	self.lastBidAmount     = bid
	self.lastBidLink       = link or name

	--[[
		Written down before the call, from the row we just re-read rather than
		from the scan, so the ledger holds what we actually bid on. minBid is
		the seller's starting price and never moves, which is what lets this
		entry still be recognised after somebody outbids us.
	]]
	if self:HasLedger() then
		self.lastBidEntry = self:LedgerRecord({
			link    = link,
			name    = name,
			texture = data.result and data.result.texture or nil,
			count   = count,
			quality = data.result and data.result.quality or nil,
			owner   = data.result and data.result.owner or nil,
			minBid  = minBid,
			buyout  = buyout,
			myBid   = bid,
			timeLeft = data.result and data.result.timeLeft or nil,
		})
	end
	self.bidQueryEarliest  = GetTime() + 1
	self.usedIndices       = self.usedIndices or {}
	self.usedIndices[index] = true
	if listType == "bidder" then
		self.rebidUsed = self.rebidUsed or {}
		self.rebidUsed[index] = true
	end

	PlaceAuctionBid(listType, index, bid)

	-- Sent is not placed. The row is only marked once the server confirms via
	-- AUCTION_BIDDER_LIST_UPDATE; until then it is pending, and a refusal or a
	-- silence clears it again.
	if data.result then
		data.result.bidPending = true
		-- a row stands for every identical auction at that price, so what marks
		-- it finished is having bid on all of them, not on one
		data.result.bidsDone   = (data.result.bidsDone or 0) + 1
		-- and a deal with copies still to go stays ticked, so taking the rest is
		-- one more press of Bid selected rather than finding and re-ticking it
		data.result.selected =
			((data.result.copies or 1) - data.result.bidsDone) > 0
		self.bidSpent = (self.bidSpent or 0) + bid
	end
	self:Print("Sent bid " .. BS.Money(bid) .. " on " .. (link or name) .. ".")
	self:SetStatus("Bid sent for " .. (link or name) .. ".")
	self:UpdateUI()
	return true
end

-- the server refused the bid we just sent: undo our optimistic bookkeeping
function BS:BidRefused(reason)
	local r = self.lastBidResult
	if r then
		r.bidPlaced  = nil
		r.bidPending = nil
		r.bidsDone   = math.max(0, (r.bidsDone or 1) - 1)
		self.bidSpent = math.max(0, (self.bidSpent or 0) - (self.lastBidAmount or 0))
	end
	-- a bid the server threw away must not linger as an entry that later reads
	-- as an auction which mysteriously vanished
	if self:HasLedger() then self:LedgerDrop(self.lastBidEntry) end
	self.lastBidEntry = nil
	self.lastBidTime = nil
	self:Print("|cffff4444Server refused that bid:|r " .. tostring(reason))
	self:SetStatus("Bid refused: " .. tostring(reason))
	self:UpdateUI()
	if self.batch then self:EndBatch("Batch stopped: the server refused a bid.") end
end

--[[
	Read one row of the Browse list and print it, bidding on nothing.

	This exists to check the assumption the whole bid ledger rests on: that
	minBid is the seller's starting price and stays put, while bidAmount is
	what moves when somebody outbids you. Peek a row, have someone outbid it,
	peek it again - bidAmount should have climbed and minBid should not have
	budged, leaving the key unchanged.
]]
function BS:PeekAuction(index)
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end

	local n = GetNumAuctionItems("list") or 0
	index = tonumber(index)
	if not index or index < 1 or index > n then
		self:Print(format("Usage: /snipe peek <1-%d>. Search something in the Browse "
			.. "tab first; this reads whatever is on screen there.", n))
		return
	end

	local name, _, count, _, _, _, minBid, minInc, buyout, bidAmount, highBidder, owner =
		GetAuctionItemInfo("list", index)
	local link = GetAuctionItemLink("list", index)

	self:Print("item: " .. tostring(link or name))
	self:Print(format("|cffffd700minBid=%s|r (fixed)   bidAmount=%s (moves)   "
		.. "minIncrement=%s   buyout=%s",
		tostring(minBid), tostring(bidAmount), tostring(minInc), tostring(buyout)))
	self:Print(format("owner=%s  highBidder=%s  count=%s",
		tostring(owner), tostring(highBidder), tostring(count)))
	if self:HasLedger() then
		self:Print("ledger key: |cff33ff99"
			.. BS.BidKey(link, name, count, minBid, buyout) .. "|r")
	end
end

--[[
	Run the scan's own filter chain against one row of the Browse list and say,
	test by test, what became of it.

	"There are two of these on the auction house and only one was listed" is
	usually one row standing for both - identical auctions are grouped, and the
	row says how many are up. When they really are listed apart, it is nearly
	always a filter doing its job on the one that got bid up. Ratio is
	the buyout over what the auction would cost *you*, right now - so a single
	bid by somebody else drops that auction's ratio while its identical twin
	sits untouched at the top of the list. Hide mine does the same to whichever
	one you are currently winning.

	Both are working as intended, and both are invisible. This makes them say
	so out loud instead.
]]
function BS:WhyFiltered(index)
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end

	local n = GetNumAuctionItems("list") or 0
	index = tonumber(index)
	if not index or index < 1 or index > n then
		self:Print(format("Usage: /snipe why <1-%d>. Search something in the Browse "
			.. "tab first; this reads whatever is on screen there.", n))
		return
	end

	local name, _, count, quality, _, _, minBid, minIncrement,
	      buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", index)
	local link = GetAuctionItemLink("list", index)

	count, bidAmount = count or 1, bidAmount or 0
	minIncrement, minBid = minIncrement or 0, minBid or 0

	self:Print("item: " .. tostring(link or name))

	if not name or not buyoutPrice or buyoutPrice <= 0 then
		self:Print("|cffff4444dropped:|r no buyout, so there is no ratio to judge it by.")
		return
	end

	local cfg = self.db
	local bid = (bidAmount > 0) and (bidAmount + minIncrement) or minBid
	local reasons = 0

	local function verdict(ok, text)
		if ok then
			self:Print("   |cff00ff00pass|r  " .. text)
		else
			reasons = reasons + 1
			self:Print("   |cffff4444DROP|r  " .. text)
		end
	end

	self:Print(format("costs %s to bid now%s, buyout %s",
		BS.Money(bid),
		bidAmount > 0 and format(" (someone bid %s)", BS.Money(bidAmount)) or " (nobody has bid)",
		BS.Money(buyoutPrice)))

	verdict(bid > 0 and bid < buyoutPrice, "bid is below the buyout")

	if cfg.onlyNoBids then
		verdict(bidAmount == 0, "Only unbid: nobody has bid on it yet")
	end
	if cfg.hideOwn then
		verdict(not highBidder, "Hide mine: you are not already the high bidder")
		verdict(not (owner and cfg.knownChars and cfg.knownChars[owner]),
			format("Hide mine: seller (%s) is not one of your characters", tostring(owner)))
	end
	verdict(not quality or quality >= cfg.minQuality,
		format("Min quality: %s vs %s", tostring(quality), tostring(cfg.minQuality)))
	verdict(buyoutPrice >= cfg.minBuyout,
		format("Min buyout: %s vs %s", BS.Money(buyoutPrice), BS.Money(cfg.minBuyout)))
	verdict(not (cfg.maxBid > 0 and bid > cfg.maxBid),
		format("Max bid: %s vs %s", BS.Money(bid), BS.Money(cfg.maxBid)))

	local timeLeft = GetAuctionItemTimeLeft("list", index) or 4
	if cfg.endingSoon then
		verdict(timeLeft <= 2, "Ending < 2h: time left bracket " .. tostring(timeLeft))
	end

	local ratio = buyoutPrice / bid
	verdict(ratio >= cfg.minRatio,
		format("Min ratio: %.1fx vs %sx", ratio, tostring(cfg.minRatio)))

	if reasons == 0 then
		self:Print("|cff00ff00A scan would keep this one.|r If you cannot see it on the "
			.. "list, look for a row with the same price carrying a |cffffd100(n up)|r "
			.. "count: identical auctions share one row. Otherwise the scan never read "
			.. "it - a paged scan stops at your max bid, and categories narrow it "
			.. "further. Bidding on the row corrects its count either way - the "
			.. "lookup a bid does anyway sees every copy.")
	else
		self:Print(format("|cffff8800Dropped by %d filter%s above.|r",
			reasons, reasons == 1 and "" or "s"))
	end
end

-- Bid on one auction of whatever the auction house currently has loaded,
-- printing every input and the raw call result. No scan, no re-query, no
-- lookup - just the API call, so a failure here is the API and not us.
function BS:TryBid(index, useSelect)
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end

	local n = GetNumAuctionItems("list") or 0
	index = tonumber(index)
	if not index or index < 1 or index > n then
		self:Print(format("Usage: /snipe try <1-%d>. Search something in the Browse tab "
			.. "first; this uses whatever is on screen there.", n))
		return
	end

	local name, _, count, _, _, _, minBid, minInc, buyout, bidAmount, highBidder, owner =
		GetAuctionItemInfo("list", index)
	local link = GetAuctionItemLink("list", index)
	local bid  = (bidAmount and bidAmount > 0) and (bidAmount + minInc) or minBid

	self:Print("--- test bid on index " .. index .. " of " .. n .. " ---")
	self:Print("item: " .. tostring(link or name))
	self:Print(format("minBid=%s  minIncrement=%s  bidAmount=%s  buyout=%s",
		tostring(minBid), tostring(minInc), tostring(bidAmount), tostring(buyout)))
	self:Print(format("owner=%s  highBidder=%s  count=%s",
		tostring(owner), tostring(highBidder), tostring(count)))
	self:Print("your money: " .. BS.Money(GetMoney()) .. "   sending bid: " .. BS.Money(bid or 0))

	if not bid or bid <= 0 then
		self:Print("|cffff4444No usable bid amount - stopping.|r")
		return
	end

	if useSelect then
		if type(SetSelectedAuctionItem) == "function" then
			local ok, err = pcall(SetSelectedAuctionItem, "list", index)
			self:Print("SetSelectedAuctionItem ok=" .. tostring(ok) .. " err=" .. tostring(err))
		else
			self:Print("SetSelectedAuctionItem does not exist on this client.")
		end
	end

	self.lastBidTime   = GetTime()
	self.lastBidResult = nil
	self.lastBidAmount = bid
	self.lastBidLink   = link or name

	local ok, err = pcall(PlaceAuctionBid, "list", index, bid)
	self:Print("PlaceAuctionBid ok=" .. tostring(ok) .. "  err=" .. tostring(err))
	self:Print("Watch for an accept/refuse line, then run /snipe bids.")
end

function BS:PrintMyBids()
	local n = GetNumAuctionItems("bidder") or 0
	self:SetStatus("")
	self:Print(format("You are on %d auction%s:", n, n == 1 and "" or "s"))
	for i = 1, n do
		local name, _, count, _, _, _, _, _, _, bidAmount, highBidder =
			GetAuctionItemInfo("bidder", i)
		self:Print(format("   %s x%d  -  %s  %s",
			tostring(name), count or 1, BS.Money(bidAmount or 0),
			highBidder and "|cff00ff00winning|r" or "|cffff8800outbid|r"))
	end
	if n == 0 then
		self:Print("   (nothing - no bids of yours reached the server)")
	end
end

-- what the server says you have actually bid on
function BS:ShowMyBids()
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end
	self:WithBidderList("wantBidList", self.PrintMyBids)
end

-- Rebuild the "already bid" marks from the server's own bidder list rather
-- than from what this addon believed happened. Anything we optimistically
-- marked that never actually reached the server gets released.
function BS:SyncBids()
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end
	self:WithBidderList("wantBidSync", self.ApplyBidSync)
end

function BS:ApplyBidSync()
	local mine = {}
	local n = GetNumAuctionItems("bidder") or 0
	for i = 1, n do
		local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("bidder", i)
		if name then
			mine[tostring(name) .. "|" .. tostring(count or 1) .. "|" .. tostring(buyout or 0)] = true
		end
	end

	local kept, released = 0, 0
	for _, r in ipairs(self.results) do
		local key = tostring(r.name) .. "|" .. tostring(r.count) .. "|" .. tostring(r.buyout)
		r.bidPending = nil
		if mine[key] then
			if not r.bidPlaced then r.bidPlaced = true end
			kept = kept + 1
		elseif r.bidPlaced then
			r.bidPlaced = nil
			r.bidsDone  = 0		-- nothing of this deal was actually bid on
			released = released + 1
		end
	end

	self:Print(format("Checked %d of your live bids against the list: %d row%s marked, "
		.. "|cff00ff00%d released|r that were never actually bid on.",
		n, kept, kept == 1 and "" or "s", released))
	self:UpdateUI()
end

-- blunt version: drop every mark, no server check
function BS:ClearMarks()
	local n = 0
	for _, r in ipairs(self.results) do
		if r.bidPlaced or r.bidPending then n = n + 1 end
		r.bidPlaced, r.bidPending, r.bidsDone = nil, nil, 0
	end
	self:Print(format("Cleared %d 'already bid' mark%s.", n, n == 1 and "" or "s"))
	self:UpdateUI()
end

--=============================================================================
--  batch bidding
--=============================================================================

-- ticked rows (whatever their state), and how many Select all would tick
--[[
	May a bulk action tick this row?

	Bulk means Select all, a shift-click range, or dragging across the boxes -
	anything that ticks rows you have not looked at one by one. Those obey Min
	profit; a single deliberate click does not, because a filter must never put
	a row you can see and want out of reach.

	An unknown profit does not clear the bar. Everywhere else in this addon an
	unpriced item gets the benefit of the doubt and is kept, on the grounds
	that it is the case you most need to see - but this is the moment gold
	actually gets spent, and "we have no idea what this is worth" is not a
	reason to bulk-tick it.
]]
-- "already bid on" only closes a row once every copy of the deal has had a bid;
-- one bid out of eight leaves seven worth ticking. A count that came back empty
-- closes it too - somebody else took them while we were looking.
function BS:Finished(r)
	if r.counted and self:CopiesLeft(r) <= 0 then return true end
	return r.bidPlaced and (r.bidsDone or 0) >= (r.copies or 1)
end

function BS:BulkSelectable(r)
	if self:Finished(r) or BS.Expired(r) then return false end

	local least = self.db.minProfit or 0
	if least > 0 then
		-- cheap after the first pass, and skipped entirely at the default of 0
		self:FillValue(r)
		if not r.profit or r.profit < least then return false end
	end
	return true
end

-- rows, tickable rows, gold, and the auctions those rows actually stand for
function BS:CountSelected()
	local selected, selectable, total, auctions = 0, 0, 0, 0
	for _, r in ipairs(self.results) do
		if self:BulkSelectable(r) then selectable = selectable + 1 end
		if r.selected then
			local n = self:CopiesLeft(r)
			selected = selected + 1
			auctions = auctions + n
			total = total + r.bid * n
		end
	end
	return selected, selectable, total, auctions
end

-- Ticking obeys the same rule as Select all: never bulk-tick something already
-- bid on or certainly ended, but always allow unticking anything.
function BS:ApplySelect(r, state, bulk)
	if not r then return end
	if state then
		if bulk then
			if not self:BulkSelectable(r) then return end
		elseif self:Finished(r) or BS.Expired(r) then
			return
		end
		r.selected = true
	else
		r.selected = false
	end
end

-- shift-clicking a tick box fills in everything between it and the last one
function BS:SelectRange(from, to, state)
	if from > to then from, to = to, from end
	local changed = 0
	for i = from, to do
		local r = self.results[i]
		if r then
			local before = r.selected
			self:ApplySelect(r, state, true)
			if before ~= r.selected then changed = changed + 1 end
		end
	end
	self:UpdateUI()
	return changed
end

-- one button for both directions: tick everything, or clear everything.
-- Select all skips rows already bid on, but you can still tick those by hand -
-- a mark this addon got wrong must never lock a row away from you.
function BS:ToggleSelectAll()
	local selected, selectable = self:CountSelected()
	local want = (selected < selectable)
	local skipped = 0
	for _, r in ipairs(self.results) do
		if want then
			if self:BulkSelectable(r) then
				r.selected = true
			elseif not self:Finished(r) and not BS.Expired(r) then
				-- passed over only because of Min profit, so say so
				skipped = skipped + 1
			end
		else
			r.selected = false
		end
	end
	self:UpdateUI()

	if want and skipped > 0 then
		self:Print(format("Left %d row%s unticked: below your minimum profit of %s. "
			.. "Tick any of them by hand if you want it anyway.",
			skipped, skipped == 1 and "" or "s", BS.Money(self.db.minProfit)))
	end
end

--=============================================================================
--  re-bidding auctions you have been outbid on
--=============================================================================

StaticPopupDialogs["BIDSNIPER_CONFIRM_REBID"] = {
	text = "Re-bid on %s auctions you have been outbid on, for up to %s total?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self)
		BidSniper:RunBatch(self.data)
	end,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

-- The Bids tab leaves its data in the client. If it is already there, use it
-- and skip the round trip entirely.
function BS:BidderListReady()
	return (GetNumAuctionItems("bidder") or 0) > 0
end

-- run `what` against the bidder list, fetching it only if we have to
function BS:WithBidderList(flag, what)
	if self:BidderListReady() then
		what(self)
		return
	end
	self[flag] = true
	self:SetStatus("Fetching your bids...")
	GetBidderAuctionItems()
end

function BS:RebidOutbid()
	if self.batch then
		self:Print("Finish or stop the current batch first.")
		return
	end
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end
	self:WithBidderList("wantRebid", self.BuildRebidQueue)
end

-- The bidder list is already loaded, so these need no per-item lookup at all.
function BS:BuildRebidQueue()
	local list, total, tooDear, noBuyout = {}, 0, 0, 0
	local n = GetNumAuctionItems("bidder") or 0

	for i = 1, n do
		local name, texture, count, quality, _, level, minBid, minIncrement,
		      buyout, bidAmount, highBidder = GetAuctionItemInfo("bidder", i)

		if name and not highBidder then		-- not highBidder = outbid
			local bid = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid
			if bid and bid > 0 then
				if buyout > 0 and bid >= buyout then
					noBuyout = noBuyout + 1		-- cheaper to just buy it
				elseif self.db.maxBid > 0 and bid > self.db.maxBid then
					tooDear = tooDear + 1
				else
					list[#list + 1] = {
						source  = "bidder",
						link    = GetAuctionItemLink("bidder", i),
						name    = name,
						texture = texture,
						count   = count or 1,
						quality = quality or 1,
						level   = level,
						bid     = bid,
						buyout  = buyout,
					}
					total = total + bid
				end
			end
		end
	end

	self:SetStatus("")

	if tooDear > 0 then
		self:Print(format("%d outbid auction%s now cost more than your max bid of %s - left alone.",
			tooDear, tooDear == 1 and "" or "s", BS.Money(self.db.maxBid)))
	end
	if noBuyout > 0 then
		self:Print(format("%d outbid auction%s would now cost more than the buyout - left alone.",
			noBuyout, noBuyout == 1 and "" or "s"))
	end

	if #list == 0 then
		self:Print("Nothing to re-bid on: you are winning everything you can afford to chase.")
		self:SetStatus("No outbid auctions worth re-bidding.")
		return
	end

	local dialog = StaticPopup_Show("BIDSNIPER_CONFIRM_REBID", BS.Comma(#list), BS.Money(total))
	if dialog then dialog.data = { list = list, total = total } end
end

-- Find this auction in the bidder list as it stands now, rather than trusting
-- an index from before the last bid. Entries we are already winning are
-- skipped, so a re-bid that succeeded cannot be offered twice.
function BS:FindBidderIndex(r)
	local n = GetNumAuctionItems("bidder") or 0
	local used = self.rebidUsed or {}
	for i = 1, n do
		local name, _, count, _, _, _, _, _, buyout, _, highBidder =
			GetAuctionItemInfo("bidder", i)
		-- our own re-bid this session may not be reflected back yet, so an
		-- index we already bid on is off limits until the list refreshes
		if not used[i] and not highBidder
		   and name == r.name and count == r.count and buyout == r.buyout then
			if not r.link then return i end
			local link = GetAuctionItemLink("bidder", i)
			if not link or link == r.link then return i end
		end
	end
	return nil
end

function BS:PrepareBidderBid(r)
	local index = self:FindBidderIndex(r)
	if not index then
		self:BatchStep("gone")
		return
	end

	local name, _, count, _, _, _, minBid, minIncrement, buyout, bidAmount =
		GetAuctionItemInfo("bidder", index)
	local bid = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid

	if not bid or bid <= 0 then
		self:BatchStep("gone")
		return
	end
	if bid > r.bid then
		self:Print("Skipped " .. (r.link or r.name) .. ": outbid again, now "
			.. BS.Money(bid) .. ".")
		self:BatchStep("outbid")
		return
	end
	if GetMoney() < bid then
		self:EndBatch("Batch stopped: out of gold.")
		return
	end

	self:ArmBid({
		listType = "bidder",
		index    = index,
		bid      = bid,
		link     = GetAuctionItemLink("bidder", index),
		name     = name,
		count    = count,
		buyout   = buyout,
		result   = r,
	})
end

function BS:StartBatchBid()
	if self.batch then
		self:EndBatch("Batch stopped.")
		return
	end
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end
	if self.scanning or self.bidSearch then
		self:Print("Wait for the current scan or lookup to finish.")
		return
	end

	--[[
		One queue entry per auction, not per row: a row stands for every
		identical auction at its price, and ticking it means all of them.

		The number used is the best one held right now - the scan's count until
		a lookup has corrected it, and lookups do that for free as the batch
		runs. So a first pass may find more copies than it was approved for; it
		bids what you approved, says how many more turned up, and leaves the row
		carrying the true count so a second press takes the rest at a price you
		approve again. Nothing is ever bid beyond the box you said yes to.
	]]
	local queue, total, deals = {}, 0, 0
	for _, r in ipairs(self.results) do
		if r.selected then
			deals = deals + 1
			for _ = 1, self:CopiesLeft(r) do
				queue[#queue + 1] = r
				total = total + r.bid
			end
		end
	end

	if deals == 0 then
		self:Print("Nothing selected - tick the boxes on the rows you want, or press Select all.")
		return
	end
	if #queue == 0 then
		self:SetStatus("None of those are still up.")
		self:Print("None of the ticked deals are still biddable at the price they showed.")
		return
	end

	if GetMoney() < total then
		self:Print("Careful: the whole list costs " .. BS.Money(total)
			.. " and you have " .. BS.Money(GetMoney()) .. ". It will stop when you run out.")
	end

	local dialog = StaticPopup_Show("BIDSNIPER_CONFIRM_BATCH", BS.Comma(#queue), BS.Money(total))
	if dialog then dialog.data = { list = queue, total = total } end
end

function BS:RunBatch(data)
	if not data or not data.list then return end

	-- group by item so runs of the same item reuse one loaded page of results
	-- (re-bids come straight from the bidder list, so order does not matter)
	if not data.list[1] or data.list[1].source ~= "bidder" then
		sort(data.list, function(a, b)
			if a.name == b.name then return a.bid < b.bid end
			return a.name < b.name
		end)
	end

	self.batch      = data.list
	self.batchIndex = 1
	self.batchDone  = 0
	self.batchSkipped = 0
	self.batchBudget  = data.total
	self.bidSpent   = 0
	self.batchExtra = 0		-- copies the lookups turn up that the scan missed
	self:UpdateUI()
	self:BatchNext()
end

function BS:BatchNext()
	if not self.batch then return end

	if not self.atAH then
		self:EndBatch("Batch stopped: auction house closed.")
		return
	end

	-- A ticked row is honoured even if marked: if you really are already the
	-- high bidder the price guard in OfferBid catches it and skips, so this
	-- cannot bid you up against yourself.
	local r = self.batch[self.batchIndex]

	if not r then
		self:EndBatch(format("Batch finished: %d bid, %d skipped, %s spent.",
			self.batchDone, self.batchSkipped, BS.Money(self.bidSpent or 0)))
		return
	end
	self.batchIndex = self.batchIndex + 1

	if (self.bidSpent or 0) + r.bid > self.batchBudget then
		self:EndBatch("Batch stopped: that would go over the total you approved.")
		return
	end
	if GetMoney() < r.bid then
		self:EndBatch("Batch stopped: out of gold.")
		return
	end

	self:SetStatus(format("Batch %d/%d: %s", self.batchIndex - 1, #self.batch,
		r.link or r.name))

	if r.source == "bidder" then
		self:PrepareBidderBid(r)
	else
		self:BidOn(r, true)
	end
end

-- called after each queue entry resolves, however it resolved
function BS:BatchStep(outcome)
	if not self.batch then return end
	if outcome == "done" then
		self.batchDone = self.batchDone + 1
	elseif outcome ~= "skip" then
		self.batchSkipped = self.batchSkipped + 1
	end
	self:BatchNext()
end

function BS:EndBatch(reason)
	local extra = self.batchExtra or 0

	self.batch = nil
	self.armed = nil
	self.batchExtra = 0
	self.rebidUsed = {}
	self:CancelBidSearch()
	if reason then
		self:SetStatus(reason)
		self:Print(reason)
	end

	--[[
		Copies the lookups turned up that the scan had stepped over. They were
		not in the total you approved, so they were not bid on - but the rows now
		carry the true count, and pressing Bid selected again asks for them at a
		figure you approve on its own.
	]]
	if extra > 0 then
		self:Print(format("|cffffd100%d more identical auction%s up|r than the scan "
			.. "found - too late to add to a total you had already approved. The rows "
			.. "now say how many; press |cffffffffBid selected|r again to take them.",
			extra, extra == 1 and " was" or "s were"))
	end

	self:UpdateUI()
end

--=============================================================================
--  sorting
--=============================================================================

local NO_VALUE = -1e12		-- sorts unpriced items to the bottom of a profit sort

local sortFields = {
	name   = function(a, b) return a.name, b.name end,
	bid    = function(a, b) return a.bid, b.bid end,
	buyout = function(a, b) return a.buyout, b.buyout end,
	ratio  = function(a, b) return a.ratio, b.ratio end,
	time   = function(a, b) return a.timeLeft, b.timeLeft end,
	owner  = function(a, b) return a.owner or "", b.owner or "" end,
	market = function(a, b) return a.market or 0, b.market or 0 end,
	-- items with no known price sink to the bottom either way round
	profit = function(a, b) return a.profit or NO_VALUE, b.profit or NO_VALUE end,
}

function BS:SortResults()
	local key  = sortFields[self.db.sortKey] and self.db.sortKey or "ratio"
	local get  = sortFields[key]
	local desc = self.db.sortDesc

	if key == "market" or key == "profit" then self:FillAllValues() end

	sort(self.results, function(a, b)
		local av, bv = get(a, b)
		if av == bv then return a.name < b.name end
		if desc then return av > bv end
		return av < bv
	end)
end

function BS:SetSort(key)
	if self.db.sortKey == key then
		self.db.sortDesc = not self.db.sortDesc
	else
		self.db.sortKey  = key
		self.db.sortDesc = (key ~= "name" and key ~= "owner")
	end
	self:SortResults()
	self:UpdateUI()
end

--=============================================================================
--  events
--=============================================================================

ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
ev:RegisterEvent("AUCTION_BIDDER_LIST_UPDATE")
ev:RegisterEvent("UI_ERROR_MESSAGE")
ev:RegisterEvent("MAIL_INBOX_UPDATE")
ev:RegisterEvent("TRADE_SKILL_SHOW")
ev:RegisterEvent("TRADE_SKILL_UPDATE")

ev:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= "BidSniper" then return end

		BidSniperDB = BidSniperDB or {}
		for k, v in pairs(BS.defaults) do
			if BidSniperDB[k] == nil then
				-- copy table defaults: sharing the table would let saved data
				-- write back into the defaults themselves
				if type(v) == "table" then
					local copy = {}
					for k2, v2 in pairs(v) do copy[k2] = v2 end
					BidSniperDB[k] = copy
				else
					BidSniperDB[k] = v
				end
			end
		end
		-- tables a saved file from an older version will not have
		BidSniperDB.wishlist   = BidSniperDB.wishlist   or {}
		BidSniperDB.priceCache = BidSniperDB.priceCache or {}
		BidSniperDB.knownChars = BidSniperDB.knownChars or {}
		BidSniperDB.bidLog     = BidSniperDB.bidLog     or {}
		BidSniperDB.categories  = BidSniperDB.categories  or {}
		BidSniperDB.subcats     = BidSniperDB.subcats     or {}
		BidSniperDB.catExpanded = BidSniperDB.catExpanded or {}

		-- category used to be a single index; carry an old setting over
		if type(BidSniperDB.category) == "number" then
			if BidSniperDB.category > 0 then
				BidSniperDB.categories[BidSniperDB.category] = true
			end
			BidSniperDB.category = nil
		end
		BS.db = BidSniperDB

		-- results are saved, so a /reload or a relog does not cost you a scan
		BidSniperDB.lastResults = BidSniperDB.lastResults or {}
		BS.results = BidSniperDB.lastResults

		-- prices saved with an old scan may be out of date by now
		for _, r in ipairs(BS.results) do
			r.market, r.profit = nil, nil
		end

		-- drop auctions that cannot possibly still be running
		local dropped = 0
		for i = #BS.results, 1, -1 do
			if BS.Expired(BS.results[i]) then
				table.remove(BS.results, i)
				dropped = dropped + 1
			end
		end
		if dropped > 0 then
			BS:Print(format("Dropped %d saved auction%s that have since ended.",
				dropped, dropped == 1 and "" or "s"))
		end

		-- index what survived, so a resumed scan adds to those rows rather than
		-- starting a second row for a deal already on the list
		BS:SetResults(BS.results)

		BS:PrunePriceCache()

		BS:BuildUI()
		if #BS.results > 0 then
			BS:SortResults()
			BS:UpdateUI()

			local res, nextPage, pages = BS:ResumeInfo()
			if res then
				BS:SetStatus(format("%d result%s so far - scan stopped at page %d%s, "
					.. "press Resume scan.", #BS.results, #BS.results == 1 and "" or "s",
					nextPage, pages > 0 and (" of " .. pages) or ""))
			else
				BS:SetStatus(format("%d result%s from your last scan.",
					#BS.results, #BS.results == 1 and "" or "s"))
			end
		end

	elseif event == "PLAYER_LOGIN" then
		local me = UnitName("player")
		if me and BS.db then BS.db.knownChars[me] = true end
		-- say it once, at login, rather than letting it surface as an error
		-- the first time a bid is placed
		if not BS:HasLedger() then BS:NoLedger() end

	elseif event == "AUCTION_HOUSE_SHOW" then
		BS.atAH = true
		if BS.db.autoShow and BS.frame then BS.frame:Show() end
		-- the first thing worth knowing on arriving is what happened to the
		-- bids you left running
		if BS.db.autoCheckBids and BS:HasLedger() and #BS:LedgerOpen() > 0 then
			BS:CheckBids(true)
		end

	elseif event == "AUCTION_HOUSE_CLOSED" then
		BS.atAH = false
		if BS.scanning then BS:StopScan("Scan stopped: auction house closed.") end
		if BS.batch then BS:EndBatch("Batch stopped: auction house closed.") end
		BS:CancelBidSearch()
		if BS:HasLedger() then BS:StopLedgerSweep() end
		BS.wantLedger      = false
		-- an armed bid points at a list that no longer exists
		BS.armed           = nil
		BS.loadedQueryName = nil
		BS.usedIndices     = {}
		BS.rebidUsed       = {}
		if BS.frame then BS.frame:Hide() end

	elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
		--[[
			Opening a tradeskill is the only moment the client will say what a
			character can make, so it is taken quietly every time rather than
			asked for. TRADE_SKILL_UPDATE fires again as the list finishes
			filling in, and harvesting merges, so reading it twice costs a few
			table writes and catches the rows that were not there on the first.

			Quiet on purpose: you opened alchemy to make something, not to hear
			from an auction addon.
		]]
		if BS.HarvestRecipes and (GetTime() - (BS.lastHarvest or 0)) > 5 then
			-- throttled because TRADE_SKILL_UPDATE also fires on every craft and
			-- every filter change, and a harvest walks the whole list. What you
			-- can make does not change while you are making it.
			BS.lastHarvest = GetTime()
			BS:HarvestRecipes(true)
		end

	elseif event == "UI_ERROR_MESSAGE" then
		-- anything the UI complains about within a moment of a bid is the
		-- server's answer to that bid
		if BS.lastBidTime and (GetTime() - BS.lastBidTime) < 3 then
			BS:BidRefused(arg1)
		end

	elseif event == "MAIL_INBOX_UPDATE" then
		-- this fires repeatedly while the inbox fills in, so settle up once the
		-- flood stops rather than on every one of them
		if BS.db and BS:HasLedger() and #BS:LedgerOpen() > 0 then
			BS.mailCheckAt = GetTime() + 0.5
		end

	elseif event == "AUCTION_BIDDER_LIST_UPDATE" then
		if BS.lastBidTime and (GetTime() - BS.lastBidTime) < 3 then
			BS:Print("|cff00ff00Server accepted the bid.|r")
			BS.lastBidTime = nil
			if BS:HasLedger() then BS:LedgerConfirm(BS.lastBidEntry) end
			BS.lastBidEntry = nil
			local r = BS.lastBidResult
			if r then
				r.bidPending = nil
				r.bidPlaced  = true
				BS:UpdateUI()
			end
		end

		-- fresh list: indices are renumbered and anything we won back now
		-- reports us as high bidder, so the skip list has done its job
		BS.rebidUsed = {}

		if BS.wantRebid then
			BS.wantRebid = false
			BS:BuildRebidQueue()
		end

		if BS.wantBidSync then
			BS.wantBidSync = false
			BS:ApplyBidSync()
		end

		if BS.wantBidList then
			BS.wantBidList = false
			BS:PrintMyBids()
		end

		if BS.wantLedger then
			local quiet = BS.ledgerQuiet
			BS.wantLedger, BS.ledgerQuiet = false, nil
			BS:ReconcileLedger(quiet)
		end

	elseif event == "AUCTION_ITEM_LIST_UPDATE" then
		if BS.ledgerSweep and BS.ledgerAwaiting then
			BS:LedgerSweepResults()
			return
		end
		if BS.bidSearch and BS.bidAwaiting then
			BS.bidAwaiting = false
			-- results are really here now, so the list genuinely holds this
			-- item and nothing on the page has been bid on yet
			BS.loadedQueryName = BS.bidSearch.result.name
			BS.loadedQueryPage = BS.bidSearch.page
			BS.usedIndices     = {}
			BS:LocatePendingBid()
			return
		end
		if not BS.scanning or not BS.awaitingResults then
			BS:MaybePiggyback()
			return
		end

		local numBatch, total = GetNumAuctionItems("list")
		total = total or 0

		--[[
			A GetAll answer is read on the very first update, exactly as
			Auctionator does it. An earlier version waited for numBatch to
			reach total on the theory that the dump streams in; on this server
			that never becomes true, so every GetAll timed out and quietly fell
			back to paging - a ten second scan turning into half an hour.
			Only a genuinely empty list is worth waiting for.
		]]
		if BS.useGetAll and numBatch == 0 and total > 0 then return end

		-- the same page served twice: ask again rather than double-count it
		if not BS.useGetAll then
			local sig = BS:PageSignature()
			if BS.lastPageSig and sig == BS.lastPageSig then
				BS.dupRetries = (BS.dupRetries or 0) + 1
				if BS.dupRetries <= 3 then
					BS.awaitingResults = false
					BS.queryPending    = true
					return
				end
			end
			BS.dupRetries  = 0
			BS.lastPageSig = sig
		end

		BS.awaitingResults = false
		BS.retries         = 0
		BS.batchCount      = numBatch
		BS.totalAuctions   = total
		BS.readIndex       = 1
		BS.processing      = true
	end
end)

--=============================================================================
--  diagnostics
--=============================================================================

-- Answers "why did it walk the pages instead of pulling the lot in one go?"
function BS:DumpScanInfo()
	self:Print("scan method setting: |cffffffff" .. tostring(self.db.scanMethod) .. "|r")
	self:Print(format("saved results: |cffffffff%d|r%s", #self.results,
		self.db.lastScanTime
			and ("   last scan: " .. date("%d %b %H:%M", self.db.lastScanTime))
			or ""))

	local res, nextPage, pages = self:ResumeInfo()
	if res then
		self:Print(format("resume point: |cffffffffpage %d%s|r, %s auctions read, saved %s",
			nextPage, pages > 0 and (" of " .. pages) or "",
			BS.Comma(res.scanned or 0), date("%d %b %H:%M", res.time or 0)))
	else
		self:Print("resume point: none - the last scan finished or was never started")
	end

	if not self.atAH then
		self:Print("Open an auction house and run this again to test GetAll.")
		return
	end

	local canQuery, canQueryAll = CanSendAuctionQuery()
	self:Print(format("CanSendAuctionQuery -> query=|cffffffff%s|r  getAll=|cffffffff%s|r",
		tostring(canQuery), tostring(canQueryAll)))

	-- say plainly whether the next scan will be the fast one, and if not, why
	local blockers = {}
	local chosen = self:ActiveClasses()
	if #chosen > 0 then
		blockers[#blockers + 1] = format("%d categor%s selected (GetAll cannot filter)",
			#chosen, #chosen == 1 and "y is" or "ies are")
	end
	if self.db.resume then
		blockers[#blockers + 1] = "a resume point exists (right-click Scan for a fresh one)"
	end
	if self.db.scanMethod == "paged" then
		blockers[#blockers + 1] = "scan method is forced to paged"
	end
	if self.db.scanMethod == "thorough" then
		blockers[#blockers + 1] = "scan method is thorough, which never uses GetAll"
	end
	if not canQueryAll then
		blockers[#blockers + 1] = "the client will not allow GetAll yet (15 minute cooldown)"
	end

	if #blockers == 0 then
		self:Print("|cff00ff00Next scan will use GetAll|r - the whole house in one request.")
	else
		self:Print("|cffff8800Next scan will page through instead, because:|r")
		for _, why in ipairs(blockers) do self:Print("   - " .. why) end
		if self.db.scanMethod ~= "thorough" then
			self:Print("A sorted paged scan can step over auctions where several share "
				.. "a bid. |cffffffff/snipe thorough|r reads every page instead.")
		end
	end
end

--=============================================================================
--  slash command
--=============================================================================

SLASH_BIDSNIPER1 = "/bidsniper"
SLASH_BIDSNIPER2 = "/snipe"
SlashCmdList["BIDSNIPER"] = function(msg)
	msg = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

	local cmd, rest = string.match(msg, "^(%S+)%s*(.*)$")

	if cmd == "try" then
		BS:TryBid(rest, false)
		return
	elseif cmd == "trysel" then
		BS:TryBid(rest, true)
		return
	elseif cmd == "peek" then
		BS:PeekAuction(rest)
		return
	elseif cmd == "why" then
		BS:WhyFiltered(rest)
		return
	end

	if msg == "scan" or msg == "newscan" then
		if BS.frame then BS.frame:Show() end
		BS:StartScan(false)
	elseif msg == "resume" then
		if BS.frame then BS.frame:Show() end
		BS:StartScan(true)
	elseif msg == "paged" then
		BS.db.scanMethod = "paged"
		BS:Print("Scan method: page by page (slow but always works).")
	elseif msg == "getall" then
		BS.db.scanMethod = "getall"
		BS:Print("Scan method: GetAll (fast, needs server support, 15 min cooldown).")
	elseif msg == "thorough" then
		BS.db.scanMethod = "thorough"
		BS:Print("Scan method: thorough (every page, unsorted, nothing stepped over).")
		BS:Print("Slower than the others, and the one to use when auctions go missing.")
	elseif msg == "auto" then
		BS.db.scanMethod = "auto"
		BS:Print("Scan method: auto (GetAll when available, otherwise paged).")
	elseif msg == "piggyback" then
		BS.db.piggyback = not BS.db.piggyback
		if BS.db.piggyback then
			BS:Print("Shared scans |cff00ff00on|r - another addon's full scan is read as "
				.. "if it were ours, so Auctionator's sweep fills this in too.")
		else
			BS:Print("Shared scans |cffff8800off|r - only scans you start here are read.")
		end
	elseif msg == "craft" then
		BS:ShowCraft()
	elseif msg == "recipes" then
		BS:HarvestRecipes(false)
	elseif msg == "crafts" then
		BS:PrintCrafts()
	elseif msg == "bids" then
		BS:ShowMyBids()
	elseif msg == "mybids" or msg == "checkbids" or msg == "listbids"
	       or msg == "mail" or msg == "findbids" then
		if not BS:HasLedger() then
			BS:NoLedger()
		elseif msg == "mybids" then
			BS:ShowLedger()
		elseif msg == "checkbids" then
			BS:CheckBids(false)
		elseif msg == "listbids" then
			BS:PrintLedger()
		elseif msg == "findbids" then
			BS:StartLedgerSweep(false)
		else
			BS:ResolveLedgerFromMail(false)
		end
	elseif msg == "syncbids" then
		BS:SyncBids()
	elseif msg == "clearmarks" then
		BS:ClearMarks()
	elseif msg == "prices" then
		BS:ClearPriceCache()
	elseif msg == "debug" then
		BS:DumpScanInfo()
	elseif msg == "layout" then
		BS:DumpLayout()
	elseif msg == "reset" then
		BidSniperDB = nil
		ReloadUI()
	elseif msg == "help" then
		BS:Print("/snipe - toggle the window")
		BS:Print("/snipe scan - start a complete new scan")
		BS:Print("/snipe resume - carry on from where a scan was interrupted")
		BS:Print("/snipe auto | paged | getall | thorough - choose the scan method")
		BS:Print("/snipe thorough - slowest, but never steps over an auction")
		BS:Print("/snipe piggyback - read another addon's full scan as if it were ours")
		BS:Print("/snipe craft - what your flasks and elixirs cost to make, and earn")
		BS:Print("/snipe recipes - read your open alchemy window into the recipe list")
		BS:Print("/snipe crafts - print the costings to chat")
		BS:Print("/snipe mybids - open the record of every bid you have placed")
		BS:Print("/snipe checkbids - fast check: your Bids tab and your mail")
		BS:Print("/snipe findbids - slow check: search the auction house itself")
		BS:Print("/snipe listbids - print that record to chat")
		BS:Print("/snipe mail - settle ended bids from the mail (at a mailbox)")
		BS:Print("/snipe bids - ask the server what you have actually bid on")
		BS:Print("/snipe syncbids - fix the 'already bid' marks from the server's list")
		BS:Print("/snipe clearmarks - drop every 'already bid' mark")
		BS:Print("/snipe prices - forget cached prices and rebuild the Profit column")
		BS:Print("/snipe why <n> - say which filter dropped row n of the Browse list")
		BS:Print("/snipe peek <n> - read row n of the Browse list, bidding on nothing")
		BS:Print("/snipe try <n> - test-bid row n of the Browse list, showing everything")
		BS:Print("/snipe trysel <n> - same, but select the row first")
		BS:Print("/snipe debug - scan method, saved results, GetAll availability")
		BS:Print("/snipe layout - print where the filter boxes actually are")
		BS:Print("/snipe reset - restore defaults and reload")
	else
		if BS.frame then
			if BS.frame:IsShown() then BS.frame:Hide() else BS.frame:Show() end
		end
	end
end
