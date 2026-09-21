--[[--------------------------------------------------------------------------
	BidSniper - buying the shopping list, without typing any of it in

	The Craft page already works out what to go and buy. This drives the Buy
	page through that list for you - filling in each search, working out the
	cheapest set of auctions that covers what you are short of, and arming the
	purchase. You press BUY. It moves on by itself.

	Nothing here is new machinery. Every part of it - the search, the covering
	knapsack, the page-by-page purchase that never spends past what was approved
	- is the Buy page doing exactly what it does when you drive it by hand. All
	this adds is the hand.

	It goes round the list twice, and that is the one thing worth knowing before
	reading any of it. The first pass buys nothing: it searches every reagent
	and writes down how many of each could actually be had at a price worth
	paying. Only then does it work out how many of each recipe that allows, and
	only then does it start spending.

	The reason is that a shopping list is not a list of independent purchases.
	It is a set of recipes, and a recipe you are one reagent short of is a
	recipe you cannot make at all. Buying in list order means the shortage is
	found whenever it happens to come up - which is usually after the expensive
	reagents have already been bought, in quantities for flasks that can now
	never exist. Looking first costs a search per reagent. Not looking costs
	gold.

	Two things it will not do, and both are deliberate.

	It cannot press the button for you. PlaceAuctionBid is protected: the client
	honours it while it is handling a real click and at no other time. So a run
	is one press per page of results, the same as buying one item by hand is,
	and the button says what that press costs before you press it.

	And it will not spend more than you approved, and you approve an exact
	figure. The first pass buys nothing and ends in a quote: every reagent at
	the price somebody is really asking, for the quantity really up, with the
	recipes already cut to what can be made. Anything more than your +% over its
	usual price is shown separately and only bought if you tick it. You see the
	total, and every shortage, before a copper moves.

	After that the total is a ceiling that is never crossed. Each reagent is
	held to the price the quote gave it; if one has gone up by the time it is
	bought, it may rise by your +% only out of money another reagent came in
	under, never out of what is set aside for the rest of the list.
]]

local BS = BidSniper
if not BS then return end

local floor, format, min, max = math.floor, string.format, math.min, math.max

--=============================================================================
--  settings
--=============================================================================

--[[
	Kept out of BS.defaults for the same reason the Buy and Sell pages keep
	theirs out: that table is copied into the saved variables one level deep, so
	a default holding a table of its own would end up shared with the defaults
	rather than copied from them.
]]
function BS:ShopSettings()
	self.db.shop = self.db.shop or {}
	local s = self.db.shop
	if s.over == nil then s.over = 20 end		-- percent over the list price allowed
	return s
end

function BS:ShopOver()
	return self:ShopSettings().over or 20
end

function BS:SetShopOver(n)
	n = tonumber(n)
	if not n then
		self:Print("Give it a percentage - 0 means only the usual price or less counts as fair.")
		return
	end

	--[[
		Above two hundred it is not a safety margin any more, it is a blank
		cheque, and the one thing this file is for is not writing those. Below
		zero it would refuse every purchase including one at the exact price it
		had just quoted you.
	]]
	n = max(0, min(200, floor(n)))
	self:ShopSettings().over = n
	self:Print(format("Reagents now count as fair up to |cffffd100%d%%|r over their usual "
		.. "price; anything dearer needs a tick in the quote.", n))
	self:RefreshCraft()
end

--=============================================================================
--  the queue
--=============================================================================

--[[
	Turn the shopping list into a list of things to go and buy.

	Only what you are short of after your bags, which is what the list shows and
	therefore what you approved. The bank is not deducted here for the same
	reason it is not deducted there - it may be sitting there on purpose - but
	how much of the shortfall it could have covered is carried along, so the
	confirmation can mention it before any gold moves.

	Vendor reagents never appear. The shopping list hands them back on a list of
	their own because they come off a vendor, and there is nothing here to buy.

	A reagent with no price anywhere is queued but never bought. This is not an
	oversight: the entire protection this file offers is "no more than the list
	said", and for something the list could not price there is no such figure to
	stay under. Buying it would mean paying whatever is being asked, which is
	precisely what you would not do by hand.

	It is still looked up, though, and that is the point of carrying it. What is
	for sale decides how many flasks the rest of the plan should buy for, and a
	reagent nobody can price is exactly as capable of being the one you cannot
	get as any other. Skipping the search would mean buying forty flasks' worth
	of everything else in ignorance.
]]
function BS:ShopQueue(list, p)
	-- the caller may already have the shopping list in its hand - a craft page
	-- has one every time it paints - and working it out twice for the same frame
	-- is the sort of thing that makes a scroll wheel feel sticky
	local buy = list or self:ShoppingList(p)
	local queue, est, unpriced, banked = {}, 0, {}, 0

	for _, e in ipairs(buy) do
		if (e.short or 0) > 0 then
			local priced = (e.unit and e.unit > 0) and true or false
			local item = {
				name    = e.name,
				link    = e.link,
				need    = e.short,
				unit    = priced and e.unit or nil,
				src     = e.src,
				inBank  = e.inBank or 0,
				est     = priced and (e.unit * e.short) or 0,
				noPrice = not priced,
			}

			if priced then
				est = est + item.est
			else
				unpriced[#unpriced + 1] = e.name
			end

			banked = banked + item.inBank
			queue[#queue + 1] = item
		end
	end

	return queue, est, unpriced, banked
end

--[[
	The one way this can spend your gold twice for the same reagent, and it is
	worth a paragraph because nothing on screen would give it away.

	A buyout on 3.3.5a does not go into your bags. It goes into the post, and
	sits there until you walk to a mailbox and take it out. The shopping list
	counts bags - deliberately, and for good reasons of its own - so a reagent
	you bought ten minutes ago and have not collected still reads as missing,
	and a second run would cheerfully go and buy it again.

	Within one run that cannot happen: the list holds one entry per reagent, so
	each is visited exactly once however many recipes wanted it. Between runs it
	very much can, which is why the last run is remembered and anything it
	bought that is still showing as missing gets named before you approve
	another one.

	Named rather than deducted. What is in the post is not knowable from here -
	you may have collected it, sold it, or sent it to another character - so
	this says what it saw and leaves the arithmetic to the person who knows.
]]
function BS:ShopWarnUncollected(queue)
	local last = self.shopLast
	if not last then return end

	local again = {}
	for _, item in ipairs(queue) do
		for _, was in ipairs(last.queue) do
			if was.name == item.name and (was.got or 0) > 0 then
				again[#again + 1] = format("%s (%s bought)", item.name, BS.Comma(was.got))
			end
		end
	end
	if #again == 0 then return end

	self:Print(format("|cffff8800The last run already bought %s.|r Auction purchases "
		.. "arrive by post, and this list counts your bags - so anything still sitting "
		.. "in the mailbox reads as missing here and would be bought again. Collect "
		.. "the mail first if that is where it is.", table.concat(again, ", ")))
end

--=============================================================================
--  starting one
--=============================================================================

--[[
	`p` is the profession whose page pressed the button. A run is always about one
	recipe book: the list it buys from, the solve that cuts it back when the
	auction house comes up short, and the report at the end are all questions about
	those recipes and no others.
]]
function BS:ShopStart(p, m)
	p, m = self:Prof(p), self:Mode(m)
	if not self:HasBuy() then self:NoBuy() return end
	if self.shopRun then
		self:Print("A shopping run is already going. Stop it from the Buy tab first.")
		return
	end
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end

	-- one query channel, shared with the scan, the bid lookup and the bid check
	local why = self:BuyBusy()
	if why then
		self:Print("Cannot go shopping while " .. why .. ".")
		return
	end
	if self.buySearch or self.buyRun then
		self:Print("Finish what the Buy tab is doing first.")
		return
	end

	local queue, est, unpriced, banked = self:ShopQueue(nil, p)

	if #queue == 0 then
		self:Print("Nothing to buy - your bags already cover everything you have "
			.. "planned. Put a number in Want against something first.")
		return
	end

	--[[
		Said up front rather than in the quote. Each of these is worth knowing
		and none of them is a reason to stop: a stack in the bank stays your
		call, and parcels still in the post are the one thing that can have a
		run buy something twice.
	]]
	self:ShopWarnUncollected(queue)
	if banked > 0 then
		self:Print(format("|cff777777%d of what you are short of is sitting in your "
			.. "bank. The list never deducts it, and neither does this.|r", banked))
	end

	--[[
		Straight into pricing, with no question first.

		There used to be a dialog here asking you to approve a total, and the
		total was a guess: the last scan's price for each reagent, times what
		you were short. The real answer - what is actually for sale, at what,
		and whether there is enough of it - only arrived afterwards, one
		reagent at a time, and the first you heard of a shortage or a price
		that had tripled was the report at the end.

		So the question moves to where the answer is. Pricing buys nothing, so
		it needs no permission; the approval comes once every reagent has been
		looked at, against the exact figure it will cost.
	]]
	self:ShopBegin({ queue = queue, est = est, unpriced = unpriced,
	                 prof = p.id, mode = m.id })
end

function BS:ShopBegin(plan)
	if not plan or not plan.queue or #plan.queue == 0 then return end
	if self.shopRun then return end
	if not self.atAH then
		self:Print("The auction house closed while that was on screen.")
		return
	end

	--[[
		The Buy page keeps its own idea of how many you want, and a run writes
		into it once per reagent. That is a setting you can see and it had a
		value before we started, so it is put back at the end - a shopping trip
		should not leave "How many" reading 47 because that was the last thing
		it looked for.
	]]
	--[[
		`wants` is the run's own copy of the Want column, and the reason it is a
		copy is that the run is allowed to change it. A reagent the auction
		house cannot supply cuts back the recipes that need it, and everything
		bought after that follows the cut-back numbers - otherwise the run
		spends the rest of its budget on the other reagents for flasks that can
		never be made.

		Your numbers on screen are left exactly as you typed them. The run
		trimming them would leave you having to remember what you had asked for.
	]]
	local wants, origWants = {}, {}
	for k, v in pairs(self:Wants(plan.prof)) do wants[k] = v origWants[k] = v end

	--[[
		The crafts, as a list you can edit in the quote.

		In the Profit tab's own order, so the quote reads the way the page you
		pressed the button on reads. `sel` is how many of each to make and `off`
		is what you have unticked - both belong to this run alone. Your Want
		column is where they start and it is never written back to.
	]]
	local crafts, sel = {}, {}
	local recipes = self:Recipes(plan.prof)
	for _, c in ipairs(self:Costed(plan.prof)) do
		local want = origWants[c.name]
		if want and want > 0 and recipes[c.name] then
			crafts[#crafts + 1] = { name = c.name, link = c.link, want = want }
			sel[c.name] = want
		end
	end

	self.shopRun = {
		-- Which page sent it, carried for the whole run. Every list, solve and
		-- report below is about one profession's recipes, and the tab you are
		-- looking at can change while a run is going.
		prof     = plan.prof,
		-- and which reading of it, so a shortage cuts back the recipes in the
		-- order the page you started from would have cut them
		mode     = plan.mode,
		queue    = plan.queue,
		at       = 0,
		phase    = "survey",		-- look at all of it before buying any of it
		est      = plan.est,
		-- set when you approve the quote, and never spent past after that
		budget   = 0,
		unpriced = plan.unpriced or {},
		over     = self:ShopOver(),
		spent    = 0,
		got      = 0,
		bought   = 0,
		wants    = wants,
		-- what you asked for, kept untouched: the solve works from this every
		-- time, so a recipe can be cut and later restored when something else
		-- turns out to have freed the reagent it was waiting on
		origWants = origWants,
		crafts    = crafts,
		sel       = sel,
		off       = {},
		sellPrice = {},		-- craft -> what one of it sells for, and where that came from
		pat       = 0,
		capped   = {},		-- recipe -> { from, to, why }, in the order they were cut
		started  = time(),
	}

	-- the page it is about to drive, so you can watch it work
	if self.frame then self.frame:Show() end
	self:SetTab("buy")

	local nCrafts = #crafts
	self:Print(format("Pricing %d reagent%s, and what %d craft%s sell%s for. "
		.. "|cffffffffNothing is bought|r until you have seen the exact total and approved it.",
		#plan.queue, #plan.queue == 1 and "" or "s",
		nCrafts, nCrafts == 1 and "" or "s", nCrafts == 1 and "s" or ""))

	self:ShopNext()
end

--=============================================================================
--  walking it: look at everything, then work out the plan, then buy it
--=============================================================================

--[[
	Why a run has two passes over the same list.

	The first version of this bought as it went, dearest reagent first, and cut
	the plan back whenever something came up short. That is the wrong way round,
	and it is wrong in the way that costs money: the shortage is usually not in
	the dearest thing. Forty flasks' worth of Frost Lotus goes into the bags at
	the top of the list, and the Ghost Mushroom that caps the whole batch at
	twelve is discovered four reagents later, by which time the gold is spent on
	twenty-eight flasks that will never exist.

	The order the list happens to be in cannot be allowed to decide that. So
	nothing is bought until everything has been looked at:

	  1. **Survey.** Every reagent is searched and nothing is bought. All that
	     comes out of it is one number each - how many you could actually get,
	     at a price worth paying.
	  2. **Solve.** Those numbers, together, decide how many of each recipe are
	     really makeable, and that decides what the shopping list should have
	     said in the first place.
	  3. **Buy.** The list is bought to the corrected numbers.

	The solve has to consider them together rather than one at a time, because
	cutting a recipe frees up the reagents it shared with others - cap the
	elixir on Ghost Mushroom and the Grave Moss it also wanted is suddenly
	enough for something else. So it goes round until nothing moves.

	The survey costs one search per reagent and buys nothing, which is the whole
	point: a search is free and a purchase is not.
]]

-- Why a reagent did not get bought. The first reason wins: it is the one that
-- actually stopped it, and anything after that is a consequence of it.
local function Note(item, why)
	if item and not item.why then item.why = why end
end

--[[
	Why a purchase ended, in words that follow a reagent's name.

	The Buy page states its reasons as sentences for its own status line -
	"3 auctions could not be found - gone, or bought by somebody else." - and
	those are the right words, just in the wrong case for the middle of a line.
	"Bought everything the plan asked for" is not a reason anything came up
	short, so it is not offered as one.
]]
local function StopReasonText(run)
	local r = run and run.stopReason
	if type(r) ~= "string" or r == "" then return nil end
	if string.find(r, "^Bought everything") then return nil end
	r = string.gsub(r, "%.%s*$", "")
	return string.lower(string.sub(r, 1, 1)) .. string.sub(r, 2)
end

--[[
	What the quote said it would cost to get at least `q` of a reagent, and how
	many that actually delivers.

	The survey keeps the planner's whole price table for each reagent rather than
	one figure, because the quantity you end up buying is not known until the
	plan is solved - and knapsack prices do not scale: forty out of a sixty-stack
	costs the whole stack, and half of forty is not half the gold. The table
	answers any quantity exactly. Its entries rise in both columns, so the first
	one that reaches `q` is the cheapest way to get there.

	nil means the quote never saw that many for sale.
]]
-- a profit, coloured the way the Profit tab colours one
local function MoneySigned(c)
	c = c or 0
	if c >= 0 then return "|cff40ff40+" .. BS.MoneyPlain(c) .. "|r" end
	return "|cffff4444-" .. BS.MoneyPlain(-c) .. "|r"
end

local function QuotedCost(item, q)
	if not q or q <= 0 then return 0, 0 end
	local opts = item and item.options
	if not opts then return nil end
	for _, o in ipairs(opts) do
		if o.n >= q then return o.cost, o.n end
	end
	return nil
end

--=============================================================================
--  the survey
--=============================================================================

--[[
	How many of this you could actually get, at a price worth paying.

	Not simply what is for sale. A reagent with two hundred up, of which the
	first thirty are sensibly priced and the rest are somebody's fantasy, can
	supply thirty - and thirty is the number the recipes have to be worked out
	from, because thirty is what will be bought.

	So this walks the quantities the planner has already costed and takes the
	largest one that still comes in under the quote plus your margin. They are
	worked out over the whole range up to what is for sale, so the answer is
	exact rather than a guess, and it is the same table the purchase itself will
	use later.
]]
function BS:ShopAfford(item, need)
	local d, plan = self.buyDP, self.buyPlan
	if not plan or (plan.qty or 0) <= 0 then return 0, nil end

	local tol = 1 + (self.shopRun.over / 100)

	-- the whole of what was asked for, at a price worth paying: the common case
	-- and the only one that needs no searching about
	if plan.cost <= item.unit * math.min(plan.qty, need) * tol then
		return plan.qty, plan.cost
	end

	--[[
		It was not. Something smaller may still be, so the frontier is walked
		from the top down for the largest quantity that is.

		Never above what was asked for. Overshooting is only ever worth it when
		it is close to free, and a plan that has already failed the test at the
		quantity you wanted is not going to redeem itself by buying more.
	]]
	local best, cost = 0, nil
	for _, o in ipairs((d and d.options) or {}) do
		if o.n <= need and o.cost <= item.unit * o.n * tol and o.n > best then
			best, cost = o.n, o.cost
		end
	end
	return best, cost
end

--[[
	How much this reagent may spend without touching anybody else's share.

	Everything still to come keeps the amount the quote gave it. What is left
	over after that - this reagent's own quote, plus whatever the ones already
	bought came in under - is this one's to use. So a price that crept up between
	the quote and the purchase can be covered out of savings, and never out of
	the gold set aside for the flask reagents further down the list.

	Because the budget is the quoted total, what this returns can never take
	the run past what you approved.
]]
function BS:ShopAllowance(current)
	local shop = self.shopRun
	if not shop then return 0 end

	local reserve = 0
	for i = (shop.at or 0) + 1, #shop.queue do
		local it = shop.queue[i]
		if it ~= current then reserve = reserve + (it.quoteCost or 0) end
	end
	return (shop.budget or 0) - (shop.spent or 0) - reserve
end

--[[
	The most of `need` that can be bought now without breaking the quote.

	Judged quantity by quantity against the quote's own price table, not against
	an average: a reagent quoted as one cheap stack is not allowed to become a
	pile of dear singles just because the total happens to fit. Each quantity
	may cost up to its quoted price plus your +%, and never more than the
	allowance above.

	Only the quantities where one of the two tables changes can be the answer -
	between those both prices are flat - so those are the only ones tried,
	largest first.
]]
function BS:ShopAffordQuoted(item, need)
	local d = self.buyDP
	if not d or not d.options or #d.options == 0 then return 0, nil end

	-- never past what you approved for it, counting what earlier passes got
	local limit = min(need or 0, (item.quoteQty or 0) - (item.got or 0))
	if limit > (d.maxq or 0) then limit = d.maxq or 0 end
	if limit <= 0 then return 0, nil end

	local tol       = 1 + (self.shopRun.over / 100)
	local allowance = self:ShopAllowance(item)

	local cands, seen = { limit }, { [limit] = true }
	local function add(n)
		if n and n > 0 and n < limit and not seen[n] then
			seen[n] = true
			cands[#cands + 1] = n
		end
	end
	for _, o in ipairs(d.options) do add(o.n) end
	for _, o in ipairs(item.options or {}) do add(o.n) end
	table.sort(cands, function(x, y) return x > y end)

	for _, n in ipairs(cands) do
		local fresh  = d.dp[n]
		local quoted = QuotedCost(item, n)
		if fresh and fresh < math.huge and quoted
		   and fresh <= quoted * tol and fresh <= allowance then
			return n, fresh
		end
	end
	return 0, nil
end

--[[
	A search has come back during the survey. Write down what it found.

	The listings themselves are kept, not just the number. The buying pass needs
	a plan to arm, and rebuilding one from a snapshot taken a minute ago costs
	nothing, whereas searching for all of it again would double the length of a
	run. Auctions that have gone in the meantime are not a problem this has to
	solve: arming a purchase re-asks the auction house where everything is, and
	says so when something has been taken.
]]
function BS:ShopSurveyed()
	local shop = self.shopRun
	if not shop then return end

	local item = shop.queue[shop.at]
	if not item then self:ShopProductsBegin() return end

	local plan, d = self.buyPlan, self.buyDP
	item.forSale    = (self.buy and self.buy.total) or 0
	-- what you were short of before anything was cut or bought; the buying
	-- pass reuses `need` for each purchase, and the report needs the original
	item.surveyNeed = item.need

	if not self.buy or not plan or not d or #plan.lines == 0 or (plan.qty or 0) <= 0 then
		item.options, item.fairQty, item.maxQty = nil, 0, 0
	else
		--[[
			Three numbers, and no decision. Whether to buy the dear part is
			yours to make in the quote, so the survey only writes down what it
			would take:

			  * `options` - the exact cost of every quantity on offer;
			  * `fairQty` - how many of what you are short of can be had within
			    your +% of the usual price;
			  * `maxQty`  - how many can be had at all, whatever they cost.
		]]
		item.options = d.options
		local top    = d.options[#d.options]
		item.maxQty  = top and min(item.need, top.n) or 0

		if item.noPrice then
			-- no usual price means nothing counts as fair: every one is a choice
			item.fairQty = 0
		else
			item.fairQty = min(item.need, (self:ShopAfford(item, item.need)) or 0)
		end
	end

	item.accept = false
	item.avail  = item.fairQty
	self:ShopNext()
end

--=============================================================================
--  the solve
--=============================================================================

--[[
	Everything has been looked at. Work out what can actually be made.

	The survey wrote a number against every reagent, so the whole picture is on
	the table at once and the arithmetic is one pass: each recipe, most
	profitable first, takes what all of its reagents together allow, and what it
	does not take is left for the next one. SolveWants does that; this only
	gathers the supply figures and records what came back.

	The bank is added here and nowhere else in the run, and only for this
	question. What can be made and what needs buying are different sums: a stack
	in the bank never stops a reagent being bought - the list has always counted
	bags alone and says so - but pretending you cannot make a flask you plainly
	have the materials for would be a worse lie, and would cut a whole batch
	over a reagent sitting in the bank two rooms away.
]]
function BS:ShopSolve()
	local shop = self.shopRun
	if not shop then return end

	--[[
		Only surveyed reagents constrain anything. One that never made the queue
		is one your bags already covered, or a vial off a vendor, and neither is
		a limit on how many you can make.
	]]
	shop.phase    = "quote"
	shop.quotedAt = time()

	local q = self:ShopQuote()
	self:Print(format("|cffffd100Quote ready:|r spend |cffffffff%s|r, expected profit %s. "
		.. "Nothing has been bought - untick anything you would rather not make, then "
		.. "approve or cancel in the window.", BS.Money(q.total), MoneySigned(q.profit)))

	if self.ShowShopQuote then
		self:ShowShopQuote()
	else
		self:PrintShopQuote(q)
	end
	self:RefreshBuy()
end

--=============================================================================
--  the quote
--=============================================================================

--[[
	What the whole list costs, exactly, with your choices applied.

	Worked out from the survey rather than from the last scan: every price here
	is one somebody is asking right now, for a quantity that is really up. And
	the plan is solved before it is priced, so a shortage in one reagent has
	already cut the recipes it caps - and with them the other reagents those
	recipes would have used - before any of it is added up. The total is the
	total for the flasks you can actually make, not for the ones you typed.

	`accept` is the one thing you can change. Each reagent can supply its fair
	part, or everything that is up; ticking it in the window moves it from one
	to the other, and because that can give a recipe its numbers back, the whole
	thing is solved again rather than one line adjusted.
]]
function BS:ShopQuote()
	local shop = self.shopRun
	if not shop then return nil end

	local function usable(item)
		return item.accept and (item.maxQty or 0) or (item.fairQty or 0)
	end

	local supply = {}
	for _, item in ipairs(shop.queue) do
		local bags, bank = BS.ReagentHave(item)
		supply[item.name] = (bags or 0) + (bank or 0) + usable(item)
	end

	-- solved from what you left ticked in the quote rather than from the Want
	-- column: untick a craft and its reagents stop being bought, which is the point
	local wants, changes = self:SolveWants(shop.prof, self:ShopSelectedWants(shop),
		supply, shop.mode)
	local list, vendor   = self:ShoppingList(shop.prof, wants)
	local short = {}
	for _, e in ipairs(list) do short[e.name] = e.short or 0 end

	local q = { total = 0, rows = {}, changes = changes, wants = wants,
	            vendor = vendor or {}, shortAny = false }

	for _, item in ipairs(shop.queue) do
		local need = short[item.name] or 0
		local take = min(need, usable(item))
		local cost, gets = QuotedCost(item, take)
		if not cost then take, cost, gets = 0, 0, 0 end

		-- the choice, measured on the reagent's own numbers so it never depends
		-- on the choice itself: unticking something must not hide its tick box
		local fairCost = QuotedCost(item, item.fairQty or 0) or 0
		local fullCost = QuotedCost(item, item.maxQty or 0) or 0
		local extra    = max(0, (item.maxQty or 0) - (item.fairQty or 0))

		local row = {
			item = item, need = need, take = take, cost = cost, gets = gets,
			canTick   = (not item.searchFailed) and extra > 0,
			extraQty  = extra,
			extraCost = max(0, fullCost - fairCost),
		}

		if item.unit and item.unit > 0 and (item.maxQty or 0) > 0 then
			row.overPct = floor((fullCost / (item.unit * item.maxQty) - 1) * 100 + 0.5)
		end

		--[[
			One short phrase per row, worked out here so the window and the chat
			version say exactly the same thing. `tone` is how loud to say it.
		]]
		local over = shop.over
		if item.searchFailed then
			row.note, row.tone = "could not be looked up", "bad"
		elseif (item.forSale or 0) <= 0 then
			row.note, row.tone = "nobody is selling it", "bad"
		elseif need <= 0 then
			row.note, row.tone = "not needed - its recipe was cut back", "dim"
		elseif take < need then
			if row.canTick and not item.accept then
				row.note = item.noPrice
					and "no usual price on file - tick to buy at market"
					or  format("%d more cost over +%d%% - tick to buy them",
						min(extra, need - take), over)
			else
				row.note = format("only %d for sale", take)
			end
			row.tone = "warn"
		elseif item.accept and item.noPrice then
			row.note, row.tone = "at market price - no usual price to compare", "warn"
		elseif item.accept and take > (item.fairQty or 0) then
			row.note = format("includes %d over your +%d%%", take - (item.fairQty or 0), over)
			row.tone = "warn"
		else
			row.note, row.tone = "fair price", "good"
		end

		if take < need then q.shortAny = true end
		q.total = q.total + cost
		q.rows[#q.rows + 1] = row
	end

	--[[
		What each craft costs and earns, priced from this run's own purchases.

		A reagent's price is the average of everything the run buys of it, across
		every craft that uses it - blended with what your bags already hold, at its
		usual price. That is what makes the quote a filter rather than a bill. The
		planner takes the cheapest auctions first, so the more of a shared reagent
		you buy the dearer the last of it gets, and that cost lands on *every* craft
		using it. Untick one, and the dearest auctions drop out of the plan: the
		average falls, and the crafts you kept earn more.

		The whole of an auction's cost is carried by the items you needed out of
		it. A stack bought for its first fifteen costs what it costs, and the
		spares are yours - but a craft is only worth making if it pays for the
		stack it made you buy.
	]]
	local queueByName, rowByName = {}, {}
	for _, item in ipairs(shop.queue) do queueByName[item.name] = item end
	for _, row in ipairs(q.rows) do
		rowByName[row.item.name] = row
		row.paidEach = (row.take > 0) and (row.cost / row.take) or nil
	end

	local avg = {}
	for _, e in ipairs(list) do
		local total = e.total or 0
		if total > 0 then
			local row  = rowByName[e.name]
			local take = row and row.take or 0
			local paid = row and row.cost or 0
			local rest = total - take
			if rest <= 0 then
				if take > 0 then avg[e.name] = paid / take end
			else
				local restUnit = e.unit or ((take > 0) and (paid / take)) or nil
				if restUnit then avg[e.name] = (paid + rest * restUnit) / total end
			end
		end
	end
	for _, e in ipairs(vendor or {}) do avg[e.name] = 0 end

	--[[
		A reagent this plan is not using - it belongs only to crafts you have
		unticked, or cut to nothing. Priced at what the check saw it would cost to
		make those crafts, so an unticked row still says what it would have earned
		and you can tell whether it is worth ticking again.
	]]
	local function reagentUnit(reagent, count)
		local u = avg[reagent.name]
		if u then return u, "blend" end
		if self:IsVendorReagent(shop.prof, reagent.name) then return 0, "vendor" end
		local item = queueByName[reagent.name]
		if item and item.options and #item.options > 0 then
			local n    = max(1, (reagent.need or 1) * max(1, count))
			local cost = QuotedCost(item, n)
			if cost then return cost / n, "live" end
			local top = item.options[#item.options]
			return top.cost / top.n, "live"
		end
		return self:UnitPrice(reagent.name, reagent.link), "scan"
	end

	local costed, recipes, cutBy = {}, self:Recipes(shop.prof), {}
	for _, c in ipairs(self:Costed(shop.prof)) do costed[c.name] = c end
	for _, ch in ipairs(changes) do cutBy[ch.name] = ch.why end

	q.crafts, q.profit, q.unknown = {}, 0, 0
	for _, craft in ipairs(shop.crafts or {}) do
		local r      = recipes[craft.name]
		local cc     = costed[craft.name]
		local on     = not shop.off[craft.name]
		local chosen = on and (shop.sel[craft.name] or 0) or 0
		local making = wants[craft.name] or 0
		local count  = (making > 0) and making or max(1, shop.sel[craft.name] or craft.want or 1)

		local row = {
			name = craft.name, link = craft.link, want = craft.want,
			on = on, chosen = chosen, making = making, cutBy = cutBy[craft.name],
			each = 0, lines = {}, sp = shop.sellPrice and shop.sellPrice[craft.name],
		}

		for _, reagent in ipairs((r and r.reagents) or {}) do
			local u, how = reagentUnit(reagent, count)
			row.lines[#row.lines + 1] = { name = reagent.name, link = reagent.link,
			                              need = reagent.need or 0, unit = u, how = how }
			if u then
				row.each = row.each + u * (reagent.need or 0)
			else
				row.missing = true
			end
		end

		row.yield = (cc and cc.yield)
			or (r and ((r.minMade or 1) + (r.maxMade or r.minMade or 1)) / 2) or 1
		if row.sp and row.sp.unit then row.sell = row.sp.unit * row.yield end

		if row.sell and not row.missing then
			row.profitEach   = row.sell - row.each
			row.afterCutEach = row.sell * 0.95 - row.each
			if making > 0 then
				row.profit = making * row.profitEach
				q.profit   = q.profit + row.profit
			end
		elseif making > 0 then
			q.unknown = q.unknown + 1
		end

		q.crafts[#q.crafts + 1] = row
	end

	return q
end

function BS:ShopToggleAccept(item)
	local shop = self.shopRun
	if not shop or shop.phase ~= "quote" or not item then return end
	item.accept = not item.accept
	if self.RefreshShopQuote then self:RefreshShopQuote() end
end

-- how many of each craft the quote is for, after your ticks and numbers
function BS:ShopSelectedWants(shop)
	local w = {}
	for _, c in ipairs((shop and shop.crafts) or {}) do
		local n = shop.off[c.name] and 0 or (shop.sel[c.name] or 0)
		if n > 0 then w[c.name] = n end
	end
	return w
end

function BS:ShopToggleCraft(name)
	local shop = self.shopRun
	if not shop or shop.phase ~= "quote" or not name then return end
	shop.off[name] = (not shop.off[name]) or nil
	if self.RefreshShopQuote then self:RefreshShopQuote() end
end

--[[
	Make fewer of a craft than the Want column says.

	Never more: the price check looked for enough reagents for what you asked
	for and no further, so a bigger number would be priced against auctions
	nobody has looked at.
]]
function BS:ShopSetCraft(name, n)
	local shop = self.shopRun
	if not shop or shop.phase ~= "quote" or not name then return end
	local want = 0
	for _, c in ipairs(shop.crafts or {}) do
		if c.name == name then want = c.want end
	end
	shop.sel[name] = max(0, min(want, floor(tonumber(n) or 0)))
	if self.RefreshShopQuote then self:RefreshShopQuote() end
end

--=============================================================================
--  what the crafts sell for
--=============================================================================

--[[
	After the reagents, the other half of the profit: what each finished craft
	sells for.

	The same price the Sell tab would post at - the cheapest listing the rest of
	the market agrees with, giveaways ignored and your own auctions not counted -
	because that is the price you are actually going to get. And the same rule
	about asking: a price checked or scanned within the hour is used as it
	stands, so a run straight after a scan does not search for anything twice.
	What it does search is saved, so the Sell tab has it too.
]]
function BS:ShopProductsBegin()
	local shop = self.shopRun
	if not shop then return end
	shop.phase = "products"
	shop.pat   = 0
	self:ShopProductNext()
end

-- a price for a craft from anything but a fresh look
function BS:ShopProductFallback(c, why)
	local shop = self.shopRun
	if not shop or not c then return end
	local unit = self:UnitPrice(c.name, c.link)
	if unit then
		shop.sellPrice[c.name] = { unit = unit, src = "lastscan", why = why }
	else
		shop.sellPrice[c.name] = { none = true, why = why or "no price on file anywhere" }
	end
end

function BS:ShopProductNext()
	local shop = self.shopRun
	if not shop then return end

	-- a loop, for the same reason the reagent walk is one: a price already in
	-- hand costs no round trip, and a list of them would otherwise nest
	while true do
		shop.pat = (shop.pat or 0) + 1
		local c = shop.crafts[shop.pat]
		if not c then
			self:ShopSolve()
			return
		end

		local known = self.SellQuote and self:SellQuote(c.name)
		if known and known.unit then
			shop.sellPrice[c.name] = {
				unit = known.unit, src = (known.src == "scan") and "scan" or "check",
				rivals = known.rivals, dropped = known.dropped, partial = known.partial,
			}
		elseif known and known.none then
			self:ShopProductFallback(c, "nobody else is selling it")
		else
			local fromScan = self.SellScanQuote and self:SellScanQuote(c.name)
			if fromScan and fromScan.unit then
				shop.sellPrice[c.name] = {
					unit = fromScan.unit, src = "scan",
					rivals = fromScan.rivals, dropped = fromScan.dropped,
					partial = fromScan.partial,
				}
			else
				self.buyTarget = 1
				self:SetStatus(format("Pricing what you make %d/%d: %s...",
					shop.pat, #shop.crafts, c.name))
				if self:BuyStartSearch(c.name, true) then
					self:RefreshBuy()
					return
				end
				self:ShopProductFallback(c, "the search would not start")
			end
		end
	end
end

-- results are in for the craft being priced
function BS:ShopProductSeen()
	local shop = self.shopRun
	if not shop then return end

	local c, b = shop.crafts[shop.pat], self.buy
	if c then
		local same = b and b.name and string.lower(b.name) == string.lower(c.name)
		local q    = same and self.SellQuoteFrom and self:SellQuoteFrom(b.offers) or nil
		local quotes = self.SellQuotes and self:SellQuotes()

		if q then
			shop.sellPrice[c.name] = { unit = q.unit, src = "search",
			                           rivals = q.rivals, dropped = q.dropped }
			if quotes then quotes[c.name] = q end
		else
			-- an answer too: written down so the Sell tab does not ask again
			if same and quotes then
				quotes[c.name] = { rivals = 0, dropped = 0, none = true, at = time() }
			end
			self:ShopProductFallback(c, "nobody else is selling it")
		end
	end
	self:ShopProductNext()
end

-- the quote in chat, for when the window cannot be shown
function BS:PrintShopQuote(q)
	q = q or self:ShopQuote()
	if not q then
		self:Print("No quote to show - press Price & buy on a crafting page first.")
		return
	end
	for _, row in ipairs(q.rows) do
		self:Print(format("   %s  %s/%s  %s   |cff888888%s|r", row.item.link or row.item.name,
			BS.Comma(row.take), BS.Comma(row.need), BS.Money(row.cost), row.note or ""))
	end
	for _, r in ipairs(q.crafts or {}) do
		self:Print(format("   %s%s  making %s, reagents %s each, sells %s each  %s",
			r.on and "" or "|cff777777(left out)|r ", r.link or r.name, BS.Comma(r.making),
			r.missing and "?" or BS.Money(r.each), r.sell and BS.Money(r.sell) or "?",
			r.profit and MoneySigned(r.profit) or ""))
	end
	self:Print(format("Spend |cffffffff%s|r, expected profit %s.", BS.Money(q.total),
		MoneySigned(q.profit)))
end

--[[
	You said yes. Fix the numbers and start spending.

	Solved once more first, from the bags as they are now: a window can sit open
	while you move things about, and the approval is for the list as it stands
	when you press the button, not when the quote was drawn up.

	From here the total is a ceiling that is never crossed. Each reagent keeps
	its price table from the quote, and the buying pass holds every purchase to
	it - see ShopAffordQuoted.
]]
function BS:ShopApprove()
	local shop = self.shopRun
	if not shop or shop.phase ~= "quote" then return end
	if not self.atAH then
		self:ShopStop("The auction house closed.")
		return
	end

	local q = self:ShopQuote()
	if q.total <= 0 then
		self:ShopStop("Nothing to buy for the crafts left ticked.")
		return
	end

	shop.budget     = q.total
	shop.wants      = q.wants
	shop.approvedAt = time()

	--[[
		What you chose in the quote becomes what the run is for. The buying pass
		solves again before each purchase, and it has to solve from these numbers:
		from the Want column it would quietly put back the crafts you left out.
		What you originally asked for is kept, so the report can say what you
		dropped rather than letting it look like a shortage.
	]]
	shop.askedWants = shop.origWants
	shop.origWants  = self:ShopSelectedWants(shop)
	shop.dropped    = {}
	for _, c in ipairs(shop.crafts or {}) do
		local kept = shop.origWants[c.name] or 0
		if kept < c.want then
			shop.dropped[#shop.dropped + 1] = { name = c.name, from = c.want, to = kept }
		end
	end
	shop.expectedProfit = q.profit

	-- recorded as already announced, so the first re-solve while buying does
	-- not report the cuts you just approved as the market having moved
	shop.capped, shop.shown = {}, {}
	for _, ch in ipairs(q.changes) do
		shop.capped[#shop.capped + 1] = {
			name = ch.name, from = ch.from, to = ch.to,
			why  = table.concat(ch.why, " and "),
		}
		shop.shown[ch.name] = ch.to
	end

	for _, row in ipairs(q.rows) do
		local item = row.item
		item.why       = nil		-- the survey's findings are superseded by the choice
		item.want      = row.need
		item.quoteQty  = row.take
		item.quoteCost = row.cost
		item.avail     = row.take

		if row.take <= 0 then
			if item.searchFailed then
				Note(item, "could not be looked up")
			elseif (item.forSale or 0) <= 0 then
				Note(item, "nobody is selling it")
			elseif row.need <= 0 then
				Note(item, "not needed once the plan was cut back")
			elseif item.noPrice then
				Note(item, "no usual price on file, and you left it unticked")
			else
				Note(item, format("costs more than your +%d%% limit, and you left it "
					.. "unticked", shop.over))
			end
		elseif row.take < row.need then
			Note(item, (row.canTick and not item.accept)
				and format("the other %d cost more than your +%d%% limit, and you left "
					.. "them unticked", row.need - row.take, shop.over)
				or  format("only %d were for sale", row.take))
		end
	end

	if self.HideShopQuote then self:HideShopQuote() end
	self:Print(format("|cff00ff00Approved %s|r, expected profit %s. It will not spend a "
		.. "copper more than that.", BS.Money(q.total), MoneySigned(q.profit)))
	if #shop.capped > 0 then
		self:PrintCapped(shop, "|cffffd100Buying for these numbers:|r")
	end
	self:ShopBuyPhase()
end

--[[
	Work the plan out from every availability figure currently on the table.

	Always from `origWants`, never from the last answer. Solving from the last
	answer would make every pass a further cut and nothing could ever recover,
	which matters because this runs again before each purchase: a reagent that
	has been restocked since the survey must be allowed to give a recipe its
	number back rather than being stuck behind a shortage that has passed.

	Returns only what has changed since the last time it was announced, so
	repeated runs stay silent unless there is genuinely news.
]]
function BS:ShopApplySolve()
	local shop = self.shopRun
	if not shop then return {} end

	--[[
		Only surveyed reagents constrain anything. One that never made the queue
		is one your bags already covered, or a vial off a vendor, and neither is
		a limit on how many you can make.
	]]
	local supply = {}
	for _, item in ipairs(shop.queue) do
		if item.avail ~= nil then
			local bags, bank = BS.ReagentHave(item)

			--[[
				And what this run has already bought, which is the one part of
				your supply that nothing else here can see.

				A buyout goes to the post, not to the bags, so `bags` reads the
				same after buying forty Lichbloom as it did before. Leaving that
				out made the solve believe the forty did not exist, and the
				consequence was circular in the worst way: the reagent came up
				short, so the recipes needing it were cut back, so the shortfall
				stopped being a shortfall, so the run decided it had nothing
				left to go back for - having just said it was going back.

				That is exactly the sequence "40 of 52 - going back for the
				other 12" followed by silence and a cut recipe.
			]]
			supply[item.name] = (bags or 0) + (bank or 0) + item.avail
			                    + (item.got or 0)
		end
	end

	local newWants, changes = self:SolveWants(shop.prof, shop.origWants, supply,
		shop.mode)
	shop.wants = newWants

	-- rebuilt rather than added to: this is the whole answer each time, and
	-- appending would leave superseded numbers in the report
	shop.capped = {}
	shop.shown  = shop.shown or {}

	local news = {}
	for _, ch in ipairs(changes) do
		local entry = {
			name = ch.name, from = ch.from, to = ch.to,
			why  = table.concat(ch.why, " and "),
		}
		shop.capped[#shop.capped + 1] = entry
		if shop.shown[ch.name] ~= ch.to then
			shop.shown[ch.name] = ch.to
			news[#news + 1] = entry
		end
	end

	return news
end

-- the cut-back lines, without the heading: for saying what has just moved
function BS:ShopPrintChanges(list)
	for _, f in ipairs(list) do
		self:Print(format("   %s  %s instead of %s   |cff888888- not enough %s|r",
			f.name,
			f.to > 0 and ("|cffffffff" .. BS.Comma(f.to) .. "|r") or "|cffff4444none|r",
			BS.Comma(f.from), f.why))
	end
end

--[[
	Say what the survey concluded, before a copper moves.

	The quantities on the confirmation you approved are no longer the
	quantities being bought, and that has to be said out loud rather than left
	to be worked out afterwards from a list of purchases. It can only ever be
	less than you approved, so it needs no second approval - but it does need
	saying.
]]
function BS:ShopAnnounce()
	local shop = self.shopRun
	if not shop then return end

	if #shop.capped == 0 then
		self:Print("Everything on the list can be had. Buying it.")
		return
	end

	self:PrintCapped(shop, "|cffffd100What the auction house can actually supply:|r")
	self:Print("|cff888888Buying for those numbers, not the ones you typed. Your Want "
		.. "column is untouched - fix the short reagent and run it again for the rest.|r")
end

--[[
	The cut-back recipes, one line each.

	Collapsed on the way out, because a recipe can be cut twice - once by the
	mushrooms and again by the moss - and that is one piece of news rather than
	two. The number that matters is where it ended up, not the route it took,
	and every reagent that had a hand in it is named on the same line.

	Shared by the announcement before buying and the report after it, so the two
	can never tell you different stories about the same run.
]]
function BS:PrintCapped(shop, heading)
	if not shop or #shop.capped == 0 then return end

	local final, order = {}, {}
	for _, ch in ipairs(shop.capped) do
		if not final[ch.name] then
			final[ch.name] = { name = ch.name, from = ch.from, to = ch.to, why = {} }
			order[#order + 1] = final[ch.name]
		end
		local f = final[ch.name]
		if ch.to < f.to then f.to = ch.to end
		local seen = false
		for _, w in ipairs(f.why) do if w == ch.why then seen = true end end
		if not seen then f.why[#f.why + 1] = ch.why end
	end

	self:Print(heading)
	for _, f in ipairs(order) do
		self:Print(format("   %s  %s instead of %s   |cff888888- not enough %s|r",
			f.name,
			f.to > 0 and ("|cffffffff" .. BS.Comma(f.to) .. "|r") or "|cffff4444none|r",
			BS.Comma(f.from), table.concat(f.why, " or ")))
	end
end

--=============================================================================
--  walking the queue, in whichever pass we are on
--=============================================================================

--[[
	On to the next reagent.

	Shared by both passes, because they walk the same list in the same order and
	differ only in what they do when they arrive. The survey searches; the
	buying pass plans and arms from what the survey already found.

	The quantity is re-read from the shopping list rather than taken off the
	queue, and in the buying pass that is what applies the solve: the list is
	worked out from the run's own cut-back recipe quantities, so the number
	being bought is the number that can be made.
]]
function BS:ShopNext()
	local shop = self.shopRun
	if not shop then return end

	local list, short = self:ShoppingList(shop.prof, shop.wants), {}
	for _, e in ipairs(list) do short[e.name] = e.short or 0 end

	--[[
		A loop rather than a call back into itself. Everything that skips a
		reagent without asking the auction house anything is instant, so a list
		of twenty you already hold would otherwise go twenty frames deep for no
		reason.
	]]
	while true do
		shop.at = shop.at + 1
		local item = shop.queue[shop.at]

		if not item then
			if shop.phase == "survey" then
				self:ShopProductsBegin()
			else
				self:ShopStop("Shopping list finished.")
			end
			return
		end

		if shop.phase == "survey" then
			--[[
				Surveyed at the quantity originally asked for, because nothing
				has been solved yet and the question is how much could be had,
				not how much is wanted. `need` here is the shortfall the run
				started with.
			]]
			self.buyTarget = max(1, min(9999, item.need))
			self:SetStatus(format("Checking %d/%d: %s...",
				shop.at, #shop.queue, item.name))

			if self:BuyStartSearch(item.name, true) then
				self:RefreshBuy()
				return
			end

			item.avail = 0
			Note(item, "the search would not start")

		else
			--[[
				What the bags still say is missing, less what this run has
				already bought towards it.

				A buyout does not land in your bags, it lands in the post. So
				the shortfall worked out above cannot see a single thing this
				run has bought, and on a second pass at the same reagent it
				would cheerfully set out to buy the whole seventy-five again.

				`want` is the figure the run set out with, kept for the report -
				"45 of 75" is the useful sentence, and it needs both halves.
			]]
			local total = short[item.name] or 0
			if item.want == nil then item.want = total end
			local need = total - (item.got or 0)

			if need <= 0 then
				--[[
					Two very different reasons for the same zero, and telling
					them apart matters: one means you already had it, the other
					means the solve decided none of it was needed after all.
					Reporting the second as "your bags covered it" would be a
					lie about where the gold went.
				]]
				Note(item, (#shop.capped > 0)
					and "not needed once the plan was cut back"
					or  "your bags already covered it")

			elseif (item.avail or 0) <= 0 then
				-- the survey already said why, and it is already on the item
				Note(item, "nothing worth buying was found")

			else
				item.need = min(need, item.avail)
				item.est  = QuotedCost(item, item.need) or 0

				--[[
					Searched again rather than bought off what the survey saw.

					The survey's listings are minutes old by the time the buying
					gets here - one search per reagent, and the last reagent on
					the list waits for all of them. Auctions do not sit still for
					that long: the ones it wrote down get bought by other people,
					and arming a purchase against them means pressing BUY on
					auctions that are not there any more. That is where "some of
					the items it tried to buy were not found" came from.

					A second search per reagent is the price of buying from a
					list that is seconds old instead of minutes. It is a query,
					not a purchase, and it is worth it.
				]]
				self.buyTarget = max(1, min(9999, item.need))
				self:SetStatus(format("Buying %d/%d: %s...",
					shop.at, #shop.queue, item.name))

				if self:BuyStartSearch(item.name, true) then
					self:RefreshBuy()
					return
				end

				Note(item, "the search would not start")
			end
		end
	end
end

--=============================================================================
--  buying one reagent
--=============================================================================

--[[
	Plan and arm the purchase for a reagent the survey found.

	The listings come back out of the snapshot the survey took rather than from
	a fresh search, which is what keeps a run to one search per reagent. They
	are minutes old at worst, and staleness cannot cause a wrong purchase: what
	the plan is worth is judged against the quote, exactly as before, and arming
	it re-asks the auction house where every one of those auctions actually is.
	An auction somebody else has taken in the meantime is simply not found, and
	is reported as such.

	Returns true when a purchase is armed and the run should wait for a press.
]]
function BS:ShopArm(item)
	local shop = self.shopRun
	if not shop or not self.buy then
		Note(item, "the listings for it were lost")
		return false
	end

	-- the search that just finished, seconds old, rather than the survey's copy
	self.buyDP, self.buyPlan = nil, nil
	self.buyTarget = max(1, min(9999, item.need))
	self:BuyReplan()

	local plan = self.buyPlan
	if not plan or #plan.lines == 0 or (plan.qty or 0) <= 0 then
		Note(item, "nothing left to buy by the time we got to it")
		return false
	end

	--[[
		The same test the survey applied, applied again to the plan that is
		actually about to be bought. The quantity has changed since - it is the
		solved one now - and a quantity that changed is a plan that changed, so
		it is checked rather than assumed.
	]]
	local useful = min(plan.qty, item.need)
	local quoted = QuotedCost(item, useful)
	local cap    = quoted and min(quoted * (1 + shop.over / 100), self:ShopAllowance(item))

	if not cap or plan.cost > cap then
		Note(item, format("%s now cost %s - the quote was %s",
			BS.Comma(useful), BS.Money(plan.cost), BS.Money(quoted or 0)))
		return false
	end

	if shop.spent + plan.cost > shop.budget then
		Note(item, format("%s would go past the %s you approved",
			BS.Money(plan.cost), BS.Money(shop.budget)))
		return false
	end

	if GetMoney() < plan.cost then
		--[[
			Skipped rather than stopped. The list is walked dearest first, so
			what is left below this is cheaper than what we are standing on and
			there is every chance the rest of it is still affordable.
		]]
		Note(item, format("it costs %s and you have %s",
			BS.Money(plan.cost), BS.Money(GetMoney())))
		return false
	end

	item.planned  = plan.qty
	item.planCost = plan.cost

	--[[
		Straight to the purchase, with no confirmation of its own. The whole
		list was approved once, by total, on the way in, and the survey has
		since only ever made it smaller; asking again per reagent would turn one
		decision into fifteen and teach you to click through them, which is
		worse than not asking at all.
	]]
	self:BuyRun(plan)
	if self.buyRun then self.buyRun.shop = true end
	self:RefreshBuy()
	return true
end

-- the survey is over; go back to the top and start spending
function BS:ShopBuyPhase()
	local shop = self.shopRun
	if not shop then return end
	shop.phase = "buy"
	shop.at    = 0
	self:ShopNext()
end

--[[
	A search came back, in whichever pass asked for it.

	Only the survey searches, so this is only ever the survey - but it is the
	single door the buy page knocks on, so it says which pass it is answering
	for rather than assuming.
]]
function BS:ShopSearchDone()
	local shop = self.shopRun
	if not shop then return end
	if shop.phase == "survey" then
		self:ShopSurveyed()
	elseif shop.phase == "products" then
		self:ShopProductSeen()
	else
		self:ShopBuyReady()
	end
end

--[[
	Fresh results are in for a reagent we are about to buy.

	The survey's figure for this one is replaced by what is really up now, and
	the plan is worked out again from all of them. Usually nothing moves. When
	it does - somebody bought the cheap half of the Ghost Mushroom while we were
	reading the rest of the list - the recipes come down before the gold goes
	out, which is the same protection the survey gives, applied again at the last
	possible moment.

	Solving from the untouched original every time is what makes that safe to do
	repeatedly: the answer depends only on what is available now, so it can go
	back up as easily as down, and a reagent that has been restocked since the
	survey is not held against a cut that no longer applies.
]]
function BS:ShopBuyReady()
	local shop = self.shopRun
	if not shop then return end

	local item = shop.queue[shop.at]
	if not item then self:ShopStop("Shopping list finished.") return end

	local plan = self.buyPlan
	if not self.buy or not plan or (plan.qty or 0) <= 0 then
		item.avail = 0
	else
		item.avail = (self:ShopAffordQuoted(item, item.need))
	end

	local news = self:ShopApplySolve()
	if #news > 0 then
		self:Print("|cffff8800The market moved while we were reading it.|r")
		self:ShopPrintChanges(news)
	end

	-- what the solve now says this reagent is for, against what is really there
	local list = self:ShoppingList(shop.prof, shop.wants)
	local need = 0
	for _, e in ipairs(list) do
		if e.name == item.name then need = e.short or 0 end
	end

	-- and less what is already in the post for it, for the reason above
	if item.want == nil then item.want = need end
	need = need - (item.got or 0)

	--[[
		Both of these can end a reagent we have just announced we were going
		back for, and a promise that quietly evaporates is worse than one never
		made. So a second pass says out loud why it stopped, rather than leaving
		"going back for the other 12" as the last word on the subject and the
		reason buried in the report at the end.
	]]
	if need <= 0 then
		Note(item, "not needed once the plan was cut back")
		if (item.passes or 1) > 1 then
			self:Print(format("|cff888888%s: not going back after all - the plan came "
				.. "down to what the reagents allow, and the %s already bought covers "
				.. "it.|r", item.link or item.name, BS.Comma(item.got or 0)))
		end
		self:ShopNext()
		return
	end
	if (item.avail or 0) <= 0 then
		Note(item, "nothing left at the price the quote gave it")
		if (item.passes or 1) > 1 then
			self:Print(format("|cffff8800%s: nothing left worth buying - stopping at "
				.. "%s of %s.|r", item.link or item.name,
				BS.Comma(item.got or 0), BS.Comma(item.want or 0)))
		end
		self:ShopNext()
		return
	end

	--[[
		Asked again for the need as it now stands. A cut can shrink it, and the
		price table is not smooth: the most of the old need that fitted is not
		necessarily a quantity that fits the new one, so the new one is tested
		on its own terms rather than clipped.
	]]
	local fits = self:ShopAffordQuoted(item, need)
	if fits <= 0 then
		Note(item, "costs more now than the quote said")
		if (item.passes or 1) > 1 then
			self:Print(format("|cffff8800%s: the rest now costs more than the quote - "
				.. "stopping at %s.|r", item.link or item.name, BS.Comma(item.got or 0)))
		end
		self:ShopNext()
		return
	end

	item.need = fits
	item.est  = QuotedCost(item, fits) or 0

	if not self:ShopArm(item) then self:ShopNext() end
end

-- the search never came back: the server would not take it, or it timed out
function BS:ShopSearchFailed(reason)
	local shop = self.shopRun
	if not shop then return end

	-- a craft's price check that never answered: fall back and carry on
	if shop.phase == "products" then
		self:ShopProductFallback(shop.crafts[shop.pat], reason or "the search did not come back")
		self:ShopProductNext()
		return
	end

	local item = shop.queue[shop.at]
	Note(item, reason or "the search did not come back")
	-- never found out what was for sale, so the safe assumption is none of it
	if item and item.avail == nil then item.avail = 0 end
	if item and shop.phase == "survey" then
		item.searchFailed = true
		item.options, item.fairQty, item.maxQty = nil, 0, 0
	end
	self:ShopNext()
end

--[[
	Fold a finished purchase into the run.

	Whatever it managed to buy is bought, whether it finished the reagent, ran
	out of gold, or was stopped half way through. So this is the only place the
	totals move, and every way a purchase can end comes through it.
]]
function BS:ShopTally(shop, run)
	if not shop or not run then return end

	shop.spent  = shop.spent  + (run.spent  or 0)
	shop.got    = shop.got    + (run.got    or 0)
	shop.bought = shop.bought + (run.bought or 0)

	local item = shop.queue[shop.at]
	if item then
		item.got  = (item.got  or 0) + (run.got   or 0)
		item.paid = (item.paid or 0) + (run.spent or 0)
		if (item.got or 0) <= 0 then
			Note(item, "the auctions were gone by the time we got to them")
		end
	end
end

--[[
	How many times one reagent may be gone back for.

	Belt and braces rather than the thing that makes this terminate - that is
	the "it bought something last time" test below, which walks the shortfall
	strictly downwards. This is here so that a server doing something genuinely
	strange cannot turn a shopping trip into an endless one.
]]
local MAX_PASSES = 4

--[[
	Still short of this reagent, and the last pass proved there is more to be
	had: go back for the rest.

	A purchase run buys against a plan built from one search. Auctions named in
	that plan get taken by other people while the run is working through them,
	and a plan cannot buy what it never listed - so a run would routinely come
	back with forty-five of the seventy-five it wanted while the auction house
	still held plenty, report the plan as filled, and move on. The shortfall was
	real and invisible: nothing compared what arrived against what was asked
	for.

	So it is compared here, and a fresh search is worth far more than a clever
	one. Every pass re-searches, re-plans and re-prices from what is up *now*,
	which means the same price ceiling, the same budget and the same gold check
	apply to the rest of the order as applied to the start of it.

	The condition for going again is that the pass just finished actually bought
	something. That is what makes this stop: each pass strictly reduces what is
	outstanding, so the passes cannot repeat forever. A pass that bought nothing
	has already told us the answer - the price is wrong, the gold has run out,
	or there is nothing left up - and searching again would find the same
	nothing.
]]
function BS:ShopGoAgain(run)
	local shop = self.shopRun
	local item = shop and shop.queue[shop.at]
	if not item then return false end

	-- you asked it to leave this one; short is the point, not a problem
	if item.skipped then return false end

	-- what you approved, not what the recipes wanted: the difference was your
	-- choice in the quote, and going back for it would be spending past it
	local target = item.quoteQty or item.want or 0
	local short  = target - (item.got or 0)
	if short <= 0 then return false end

	-- no progress last time round: another search finds the same nothing. That
	-- is an answer, though, and the reagent keeps it rather than ending short
	-- with nothing written against it
	if (run.got or 0) <= 0 then
		Note(item, StopReasonText(run)
			or format("the other %s could not be bought", BS.Comma(short)))
		return false
	end

	item.passes = (item.passes or 1) + 1
	if item.passes > MAX_PASSES then
		Note(item, format("still %s short after %d tries",
			BS.Comma(short), MAX_PASSES))
		return false
	end

	self:Print(format("%s: |cffffffff%s|r of %s so far - going back for the other %s.",
		item.link or item.name, BS.Comma(item.got or 0),
		BS.Comma(target), BS.Comma(short)))

	--[[
		Back one, so the queue walker lands on this same reagent again and runs
		the buying pass for it exactly as it did the first time. Everything that
		matters - the fresh search, the re-solve, the ceiling, the budget - is
		in that path already, and a second copy of it here would be a second
		copy to keep right.
	]]
	shop.at = shop.at - 1
	self:ShopNext()
	return true
end

--[[
	A purchase this run started has ended by itself.

	Nothing is re-solved here. The survey settled how many of each recipe are
	makeable before any of this started, and a purchase that came up short
	because somebody else got there first is not a reason to tear that up - the
	reagents are bought either way, and what they will and will not make is a
	question for the Craft page once the mail is in.

	What it does do is check that what arrived is what was asked for, and go
	back for the difference while there is still some to be had.
]]
function BS:ShopItemDone(run)
	local shop = self.shopRun
	if not shop then return end
	self:ShopTally(shop, run)

	if self:ShopGoAgain(run) then return end
	self:ShopNext()
end

--[[
	Leave this reagent and go on to the next.

	Three states it can be in, and each has its own way out. Armed and waiting
	for a press, the purchase is stopped, which settles anything already bought
	and comes back to us through ShopItemDone. Mid-search, the search is
	cancelled and comes back through ShopSearchFailed. Between the two there is
	nothing in flight and the run simply moves on.

	Skipping during the survey counts as none of it being available, which is
	the honest reading: whatever the reason, this run is not getting any.
]]
function BS:ShopSkip()
	local shop = self.shopRun
	if not shop then return end
	if shop.phase == "quote" then return end		-- nothing is running to skip

	-- leaving one craft's price check: it falls back to the last scan's price
	if shop.phase == "products" then
		if self.buySearch then
			self:BuyCancelSearch("Skipped that price check.")	-- back through ShopSearchFailed
		else
			self:ShopProductNext()
		end
		return
	end

	local item = shop.queue[shop.at]
	Note(item, "you skipped it")
	if item and shop.phase == "survey" then item.avail = 0 end

	--[[
		Marked, not just noted. Stopping the purchase below comes back through
		ShopItemDone, which goes back for a reagent that came up short - and
		"short because you told it to stop" is the one case where it must not.
	]]
	if item then item.skipped = true end

	if self.buyRun then
		-- claimed before stopping it rather than trusted to have been claimed
		-- already: an unmarked purchase would stop without telling us, and the
		-- run would sit on a reagent it had just been asked to leave
		self.buyRun.shop = true
		self:BuyStop(format("Skipped %s.", item and item.name or "it"))
	elseif self.buySearch then
		self:BuyCancelSearch(nil)
	else
		self:ShopNext()
	end
end

--[[
	The end of a run, however it got here.

	shopRun is cleared before anything else happens, and that ordering is load
	bearing: stopping a purchase asks us whether to move on to the next reagent,
	and the answer while we are shutting down is no. With the run already gone
	the question answers itself, and there is no second flag to get out of step
	with the first.
]]
function BS:ShopStop(reason, finished)
	local shop = self.shopRun
	if not shop then return end
	self.shopRun = nil

	if finished then self:ShopTally(shop, finished) end
	if self.HideShopQuote then self:HideShopQuote() end

	--[[
		Stopped while pricing, or at the quote. Nothing has been spent, so there
		is nothing to report - a page of "left alone" reasons for a list you
		simply decided not to buy is noise. One line, and back to the page you
		came from. The last real run stays remembered, so its uncollected-mail
		warning is not lost to a cancel.
	]]
	if shop.phase ~= "buy" and (shop.got or 0) <= 0 then
		if self.buyRun then self:BuyStop(nil) end
		if self.buySearch then self:BuyCancelSearch(nil) end
		self:BuyClearTarget()

		local line = (reason or "Shopping cancelled.") .. " Nothing was bought."
		self:Print(line)
		self:SetStatus(line)
		self:RefreshBuy()
		self:RefreshCraft()

		local mode = self.Mode and self:Mode(shop.mode)
		if mode and mode.tab and self.SetTab then self:SetTab(mode.tab) end
		return
	end

	local run = self.buyRun
	if run then
		self:BuyStop(nil)
		self:ShopTally(shop, run)
	end
	if self.buySearch then self:BuyCancelSearch(nil) end

	-- the run's claim on the quantity goes with it; the number you typed into
	-- the box was never touched, so there is nothing to put back
	self:BuyClearTarget()

	--[[
		The page's finished notice, replacing whichever single reagent happened
		to be last. "Bought 30 Lichbloom" is true and useless at the end of a
		run that bought eleven other things; what the page has to say is that
		the errand is over.

		Set last so that the per-reagent notice BuyStop leaves behind cannot
		outlive it.
	]]
	local reagents = 0
	for _, item in ipairs(shop.queue) do
		if (item.got or 0) > 0 then reagents = reagents + 1 end
	end
	self.buyDone = {
		shop = true, reagents = reagents, capped = #shop.capped,
		qty = shop.got, cost = shop.spent, at = GetTime(),
	}

	self.shopLast = shop
	self:ShopReport(shop)

	--[[
		"Shopping list finished" is true and says nothing, and it is the line
		you are looking at when a run buys none of the one thing you sent it
		for. The reason is already worked out - it is on the reagent, and it is
		in the report - so there is no excuse for the status line to be the one
		place that does not carry it.

		With a single reagent its reason *is* the run's reason and goes up
		whole. With several there is no one answer, so it points at the report
		rather than picking one of them to be misleading with.
	]]
	local status = reason or "Shopping finished."
	if (shop.got or 0) <= 0 then
		local why, n = nil, 0
		for _, item in ipairs(shop.queue) do
			if item.why then
				n   = n + 1
				why = why or item.why
			end
		end
		if n == 1 and why then
			status = format("Bought nothing - %s.", why)
		elseif n > 1 then
			status = "Bought nothing - see chat for why, reagent by reagent."
		end
	end
	self:SetStatus(status)
	self:RefreshBuy()
	self:RefreshCraft()

	--[[
		Back to the page that sent it.

		A run takes the window over - it drives the Buy tab so you can watch it
		work - and then used to leave you sitting on a page whose job is done,
		with the numbers you actually came for one tab away. The errand started
		on the crafting page and its results belong there: what the reagents in
		the post will make, and what is still short.

		The mode is the run's own copy rather than whatever is selected now,
		for the same reason everything else here uses it: the tab you are
		looking at can change while a run is going.
	]]
	local mode = self.Mode and self:Mode(shop.mode)
	if mode and mode.tab and self.SetTab then
		self:SetTab(mode.tab)
	end
end

--[[
	The auction house has gone, and with it the list every plan points at.

	The reagent we were standing on gets the true reason before the tally runs,
	because the tally's own account of a reagent that bought nothing - that the
	auctions were gone when we reached them - is the wrong story here and would
	otherwise be the one on the report.
]]
function BS:ShopForget(run)
	if not self.shopRun then return end
	Note(self.shopRun.queue[self.shopRun.at], "the auction house closed")
	self:ShopStop("The auction house closed.", run)
end

--=============================================================================
--  what happened
--=============================================================================

function BS:ShopReport(shop)
	shop = shop or self.shopLast
	if not shop then
		self:Print("No shopping run to report on.")
		return
	end

	local bought, left = {}, {}
	for _, item in ipairs(shop.queue) do
		if (item.got or 0) > 0 then
			bought[#bought + 1] = item
		else
			left[#left + 1] = item
		end
	end

	if shop.got > 0 then
		self:Print(format("Shopping done: |cffffffff%s|r item%s across |cffffffff%d|r "
			.. "reagent%s for %s.", BS.Comma(shop.got), shop.got == 1 and "" or "s",
			#bought, #bought == 1 and "" or "s", BS.Money(shop.spent)))
		for _, item in ipairs(bought) do
			--[[
				"45 of 75" rather than "45" whenever the two differ, because
				a bare count reads as success and a shortfall you cannot see is
				a shortfall you find out about at the forge.
			]]
			local want  = item.want or 0
			local count = BS.Comma(item.got)
			if want > 0 and item.got < want then
				count = format("|cffff8800%s of %s|r", count, BS.Comma(want))
			end

			self:Print(format("   |cff00ff00%s|r %s for %s%s%s", count,
				item.link or item.name, BS.Money(item.paid),
				(item.passes or 1) > 1
					and format("   |cff888888(%d tries)|r", item.passes) or "",
				item.why and ("   |cffff8800" .. item.why .. "|r") or ""))
		end
	else
		self:Print("Shopping done, and it bought nothing.")
	end

	--[[
		What you can actually make, which is the question the whole run was
		really answering. It goes above the list of what it did not buy, because
		a recipe being cut back is the reason for most of what is on that list
		and reads as an explanation rather than a second complaint.
	]]
	-- the cuts themselves, and why, are in the what-you-can-make list at the end:
	-- worked out from what really arrived rather than from what was planned

	if #left > 0 then
		self:Print(format("|cffff8800%d left alone:|r", #left))

		--[[
			Counted while they are printed, because "all dearer than the list
			said" is the one reason with a knob attached and the knob is worth
			naming. Being told what stopped it and not being told what to turn
			is how a setting stays undiscovered.
		]]
		local dear = 0
		for _, item in ipairs(left) do
			if item.why and string.find(item.why, "limit", 1, true) then
				dear = dear + 1
			end
			self:Print(format("   %s|cff888888 - %s|r", item.link or item.name,
				item.why or "no reason recorded"))
		end

		if dear > 0 then
			self:Print(format("|cff888888%s over your +%d%% limit and left unticked in "
				.. "the quote. Tick it next time to buy it anyway, or move the limit "
				.. "with |cffffffff/snipe shopmax <percent>|r|cff888888.|r",
				dear == 1 and "That one was" or format("%d of those were", dear),
				self:ShopOver()))
		end

		self:Print("|cff888888Any of those you still want are one search away on this "
			.. "tab - the plan and the price are worked out the same way.|r")
	end

	self:ReportAchievable(shop)

	if shop.unpriced and #shop.unpriced > 0 then
		self:Print(format("|cff888888Never looked at: %s - no price on file to keep "
			.. "under.|r", table.concat(shop.unpriced, ", ")))
	end
end

--[[
	The line the whole errand was for: what you can now actually make.

	Everything else in the report is about reagents, and reagents are not what
	anybody went shopping for. A list of eleven purchases does not answer "did I
	get what I needed for the flasks", and working it out by hand means checking
	every reagent of every recipe against a mailbox.

	It is recomputed rather than assumed, and from what was really bought - not
	from what the run set out to buy, and not from what the survey said was
	available. Purchases fail; the confirmed count is the one that decides this,
	so a run that pressed for forty and got thirty-one says thirty-one's worth
	here. Same solver as the plan itself, so the answer cannot disagree with the
	one given at the start for any reason other than a purchase falling through.

	And it says to go to the mailbox, because on 3.3.5a none of it is in your
	bags yet and a flask cannot be made out of a parcel.
]]
--[[
	Why one reagent left a recipe short: the counts, and the cause.

	Two very different kinds of shortfall, and telling them apart is the point.

	One is decided before a copper moves: the quote could not cover the reagent,
	because not enough was for sale, or because the rest cost more than your
	limit and you left it unticked. The survey wrote down exactly what was up
	and what was fair, so this is worked out from those figures rather than
	from whatever happened to be noted last.

	The other happens while buying: the quote covered it, and the purchase did
	not get there - taken by somebody else, dearer by the time it was bought, the
	gold ran out, you skipped it. Those were written against the reagent at the
	moment they happened.

	Returns the reagent as a link, the counts, and the reason, separately: a
	link carries its own colour and ends it, so whatever follows has to set its
	own.
]]
function BS:ShopShortReason(shop, item)
	local over = shop.over or self:ShopOver()
	local got  = item.got or 0
	local need = item.surveyNeed or item.want or 0
	local counts = format("got %s of %s", BS.Comma(got), BS.Comma(need))

	local usable = item.accept and (item.maxQty or 0) or (item.fairQty or 0)
	local why

	if item.searchFailed then
		why = "the auction house would not answer the search for it"
	elseif (item.forSale or 0) <= 0 then
		why = "nobody was selling it"
	elseif item.skipped then
		why = "you skipped it"
	elseif usable < need then
		if not item.accept and (item.maxQty or 0) > (item.fairQty or 0) then
			if item.noPrice then
				why = "there is no usual price on file for it, and you left it unticked "
					.. "in the quote"
			else
				why = format("only %s were within your +%d%% limit, and you left the "
					.. "rest unticked in the quote", BS.Comma(item.fairQty or 0), over)
			end
			if (item.maxQty or 0) < need then
				why = why .. format(" - and only %s were up in all",
					BS.Comma(item.maxQty or 0))
			end
		else
			why = format("only %s were for sale", BS.Comma(item.maxQty or 0))
		end
	elseif got < (item.quoteQty or 0) then
		why = item.why or format("%s of the %s approved did not come through",
			BS.Comma((item.quoteQty or 0) - got), BS.Comma(item.quoteQty or 0))
	else
		why = item.why or "not enough of it arrived"
	end

	return item.link or item.name, counts, why
end

function BS:ReportAchievable(shop)
	if not shop or not shop.origWants then return end

	local supply = {}
	for _, item in ipairs(shop.queue) do
		local bags, bank = BS.ReagentHave(item)
		supply[item.name] = (bags or 0) + (bank or 0) + (item.got or 0)
	end

	--[[
		The solver already knows which reagent capped each recipe - that is how
		it decided the cap - so the reason comes from the same answer as the
		number beside it and cannot disagree with it.
	]]
	local can, changes = self:SolveWants(shop.prof, shop.origWants, supply, shop.mode)
	local blockedBy, byName, explained = {}, {}, {}
	for _, ch in ipairs(changes or {}) do blockedBy[ch.name] = ch.why end
	for _, item in ipairs(shop.queue) do byName[item.name] = item end

	--[[
		Ordered by what you asked for rather than by what came back, so a recipe
		that ended up at nothing still gets a line. "I planned forty and it is
		not on the list" is the one thing a summary like this must never leave
		you to work out.
	]]
	local lines, any, short = {}, false, false
	for _, c in ipairs(self:Costed(shop.prof)) do
		local asked = shop.origWants[c.name]
		if asked and asked > 0 then
			local got = can[c.name] or 0
			any = true
			if got >= asked then
				lines[#lines + 1] = format("   |cff00ff00%s|r x %s", BS.Comma(got), c.name)
			else
				short = true
				lines[#lines + 1] = format("   |cffff8800%s|r x %s   |cff888888(you "
					.. "asked for %s)|r", BS.Comma(got), c.name, BS.Comma(asked))

				--[[
					And why, one line per reagent that held it back. A reagent
					that caps several recipes is explained the first time and
					pointed at after that - the same paragraph four times is how
					the one line that matters gets scrolled past.
				]]
				for _, reagent in ipairs(blockedBy[c.name] or {}) do
					local item = byName[reagent]
					if not item then
						lines[#lines + 1] = format("      |cffffcc88short on %s - not "
							.. "enough in your bags, and it was not on the list to buy|r",
							reagent)
					elseif explained[reagent] then
						lines[#lines + 1] = format("      short on %s|cffffcc88 - see "
							.. "above|r", item.link or reagent)
					else
						explained[reagent] = true
						local label, counts, why = self:ShopShortReason(shop, item)
						lines[#lines + 1] = format("      short on %s|cffffcc88: %s - %s|r",
							label, counts, why)
					end
				end
			end
		end
	end

	if not any then return end

	self:Print(short and "|cffffd100You now have the reagents for:|r"
		or "|cff00ff00Done - you have the reagents for everything you planned:|r")
	for _, line in ipairs(lines) do self:Print(line) end

	if short then
		self:Print("|cff888888Your Want column is untouched - sort out the short reagent "
			.. "and run it again to pick up the rest.|r")
	end

	if shop.dropped and #shop.dropped > 0 then
		local parts = {}
		for _, d in ipairs(shop.dropped) do
			parts[#parts + 1] = (d.to > 0)
				and format("%s (%s of %s)", d.name, BS.Comma(d.to), BS.Comma(d.from))
				or  d.name
		end
		self:Print("|cff888888Left out in the quote, by you: " .. table.concat(parts, ", ")
			.. "|r")
	end

	if shop.got > 0 then
		self:Print("|cff888888Collect your mail before crafting - auction purchases "
			.. "arrive by post, so none of it is in your bags yet.|r")
	end
end

--[[
	One line for the top of the Buy page while a run is going, so the page you
	are pressing BUY on says which reagent that press is for and how far down
	the list it has got.
]]
function BS:ShopStatus()
	local shop = self.shopRun
	if not shop then return nil end

	if shop.phase == "quote" then
		return "|cffffd100Shopping list - quote ready|r" .. "\n"
			.. "Nothing has been bought. The exact total is in the window: tick anything "
			.. "over your limit you want anyway, then Buy or Cancel."
	end

	if shop.phase == "products" then
		local c = shop.crafts[shop.pat]
		return format("|cffffd100Pricing what you make %d/%d|r%s",
			min(shop.pat or 0, #shop.crafts), #shop.crafts,
			c and ("  -  |cffffffff" .. c.name .. "|r") or "")
			.. "\nChecking what each finished craft sells for, so the quote can show "
			.. "profit.  Nothing is being bought yet."
	end

	local item    = shop.queue[shop.at]
	local surveying = (shop.phase == "survey")

	local head = format("|cffffd100%s %d/%d|r",
		surveying and "Checking the list" or "Shopping list",
		min(shop.at, #shop.queue), #shop.queue)

	if item then
		-- what is still outstanding, not what the pass in front of us is for:
		-- on a second try those are different numbers and the first is the one
		-- that answers "how much longer"
		local outstanding = (item.want and item.want > 0)
			and (item.want - (item.got or 0)) or (item.need or 0)

		head = head .. format("  -  |cffffffff%s|r, short %s",
			item.name, BS.Comma(max(0, outstanding)))
		if self.buyRun and item.planCost then
			head = head .. format("  -  taking %s for %s",
				BS.Comma(item.planned or 0), BS.Money(item.planCost))
		end
	end

	--[[
		The survey line says plainly that nothing is being bought yet, because
		this is a page covered in prices with a purchase button on it and the
		obvious assumption is the wrong one.
	]]
	if surveying then
		return head .. "\nLooking at every reagent before buying any of them, so a "
			.. "shortage anywhere cuts the plan before the gold goes.  Nothing is "
			.. "being bought yet."
	end

	return head .. format("\n%s of %s spent, %s items bought so far.  Skip leaves this "
		.. "reagent and moves on; Stop ends the run.",
		BS.Money(shop.spent), BS.Money(shop.budget), BS.Comma(shop.got))
end

--=============================================================================
--  printed version, for people who would rather not open a panel
--=============================================================================

function BS:PrintShopPlan(p)
	local queue, est, unpriced, banked = self:ShopQueue(nil, p)

	if #queue == 0 then
		self:Print("Nothing to buy - put a number in Want against something first.")
		if #unpriced > 0 then
			self:Print("Not costed: " .. table.concat(unpriced, ", "))
		end
		return
	end

	local over = self:ShopOver()
	self:Print(format("%d reagent%s, about %s, and a run would leave anything more "
		.. "than %d%% over that:", #queue, #queue == 1 and "" or "s",
		BS.Money(est), over))

	for _, item in ipairs(queue) do
		self:Print(format("   |cffffffff%s|r %s   %s   |cff888888%s each, at most %s|r%s",
			BS.Comma(item.need), item.link or item.name, BS.Money(item.est),
			BS.Money(item.unit), BS.Money(item.est * (1 + over / 100)),
			item.inBank > 0 and format("   |cff777777%d in bank|r", item.inBank) or ""))
	end

	if #unpriced > 0 then
		self:Print("|cffff8800Not costed, so a run would leave them: |r"
			.. table.concat(unpriced, ", "))
	end
	if banked > 0 then
		self:Print(format("|cff777777%d of the total is sitting in your bank, and is "
			.. "never deducted.|r", banked))
	end
end
