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

	And it will not pay more than the list said. That is the whole safety of the
	thing, so it is worth being exact about what the promise is:

	  * the list quoted a price for each reagent, taken from the last scan;
	  * a run will not pay more than that, plus a margin you set;
	  * the margin is measured against the part of the purchase you actually
	    needed, so a stack that overshoots is judged on the items you wanted
	    rather than on the ones that came along with them;
	  * anything dearer than that is left alone and said out loud, with both
	    figures, so you can go and look at it yourself.

	The consequence is that a run can come back having bought half the list.
	That is the correct outcome and not a failure: prices move between the scan
	and the shopping trip, and quietly paying triple for Frost Lotus because it
	was on a list you approved ten minutes ago is the thing this is built to
	stop.
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
		self:Print("Give it a percentage - 0 means never pay a copper over the list.")
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
	self:Print(format("Shopping runs will pay at most |cffffd100%d%%|r over what the "
		.. "list says.", n))
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

StaticPopupDialogs["BIDSNIPER_CONFIRM_SHOP"] = {
	text = "Buy the shopping list?\n\n%s\n\nIt will never spend more than %s, and it "
	    .. "leaves any reagent that costs more than the list said.",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self) BidSniper:ShopBegin(self.data) end,
	timeout = 60,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

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

	-- a queue made up entirely of things that cannot be priced has nothing to
	-- spend on, and a purchase run that cannot purchase is just a slow way of
	-- reading the auction house
	if #unpriced >= #queue then
		self:Print(format("Nothing on the list can be costed: %s ha%s no price "
			.. "anywhere, so there is no figure to keep a purchase under. Look %s up "
			.. "on the Buy tab.", table.concat(unpriced, ", "),
			#unpriced == 1 and "s" or "ve", #unpriced == 1 and "it" or "them"))
		return
	end

	local budget = floor(est * (1 + self:ShopOver() / 100))

	--[[
		Said before the dialog rather than inside it. Each of these is worth
		knowing and none of them is a reason to stop: a run buys what it can
		afford and reports the rest, and a stack in the bank stays your call.
	]]
	self:ShopWarnUncollected(queue)
	if #unpriced > 0 then
		self:Print(format("|cffff8800Will not buy %s|r - no price anywhere, so there "
			.. "is nothing to check a purchase against. It still gets looked up, "
			.. "because what is for sale decides how many of the rest are worth "
			.. "buying.", table.concat(unpriced, ", ")))
	end
	if banked > 0 then
		self:Print(format("|cff777777%d of what you are short of is sitting in your "
			.. "bank. The list never deducts it, and neither does this.|r", banked))
	end
	if GetMoney() < est then
		self:Print(format("|cffff8800The list comes to about %s and you have %s.|r It "
			.. "will buy down the list until the gold runs out and say what it left.",
			BS.Money(est), BS.Money(GetMoney())))
	end

	StaticPopup_Show("BIDSNIPER_CONFIRM_SHOP",
		format("%d reagent%s, about %s", #queue, #queue == 1 and "" or "s", BS.Money(est)),
		BS.Money(budget),
		{ queue = queue, est = est, budget = budget, unpriced = unpriced,
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
		budget   = plan.budget,
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
		capped   = {},		-- recipe -> { from, to, why }, in the order they were cut
		started  = time(),
	}

	-- the page it is about to drive, so you can watch it work
	if self.frame then self.frame:Show() end
	self:SetTab("buy")

	self:Print(format("Checking %d reagent%s before buying anything. It will not spend "
		.. "more than %s, and will leave anything dearer than %d%% over the list.",
		#plan.queue, #plan.queue == 1 and "" or "s", BS.Money(plan.budget),
		self.shopRun.over))

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
	if not item then self:ShopSolve() return end

	local plan = self.buyPlan

	if not self.buy or not plan or #plan.lines == 0 or (plan.qty or 0) <= 0 then
		item.avail = 0
		Note(item, "nobody is selling it")

	elseif item.noPrice then
		--[[
			Looked up so the plan could be cut to fit, never to be bought. There
			is no quoted price to hold this one to, so what is for sale is
			information and nothing more - and since none of it is coming, none
			of it counts towards what can be made.
		]]
		item.avail = 0
		item.forSale = plan.qty
		Note(item, format("%s up, but no price on file to check a purchase against",
			BS.Comma(plan.qty)))

	else
		local afford, cost = self:ShopAfford(item, item.need)
		item.avail    = afford
		item.planCost = cost
		item.forSale  = self.buy.total

		if afford <= 0 then
			Note(item, format("%s up, all dearer than the %s the list said",
				BS.Comma(self.buy.total or 0), BS.Money(item.unit)))
		elseif afford < item.need then
			Note(item, format("only %s of the %s could be had at a fair price",
				BS.Comma(afford), BS.Comma(item.need)))
		end

	end

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
	self:ShopApplySolve()
	self:ShopAnnounce()
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
			supply[item.name] = (bags or 0) + (bank or 0) + item.avail
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
				self:ShopSolve()
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
				item.est  = item.unit * item.need

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
	local useful  = min(plan.qty, item.need)
	local quoted  = item.unit * useful
	local ceiling = quoted * (1 + shop.over / 100)

	if plan.cost > ceiling then
		Note(item, format("%s for %s, and the list said %s",
			BS.Comma(plan.qty), BS.Money(plan.cost), BS.Money(quoted)))
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
		item.avail = self:ShopAfford(item, item.need)
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

	if need <= 0 then
		Note(item, "not needed once the plan was cut back")
		self:ShopNext()
		return
	end
	if (item.avail or 0) <= 0 then
		Note(item, "nothing worth buying was left by the time we got to it")
		self:ShopNext()
		return
	end

	item.need = min(need, item.avail)
	item.est  = item.unit * item.need

	if not self:ShopArm(item) then self:ShopNext() end
end

-- the search never came back: the server would not take it, or it timed out
function BS:ShopSearchFailed(reason)
	local shop = self.shopRun
	if not shop then return end

	local item = shop.queue[shop.at]
	Note(item, reason or "the search did not come back")
	-- never found out what was for sale, so the safe assumption is none of it
	if item and item.avail == nil then item.avail = 0 end
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

	local short = (item.want or 0) - (item.got or 0)
	if short <= 0 then return false end

	-- no progress last time round: another search finds the same nothing
	if (run.got or 0) <= 0 then return false end

	item.passes = (item.passes or 1) + 1
	if item.passes > MAX_PASSES then
		Note(item, format("still %s short after %d tries",
			BS.Comma(short), MAX_PASSES))
		return false
	end

	self:Print(format("%s: |cffffffff%s|r of %s so far - going back for the other %s.",
		item.link or item.name, BS.Comma(item.got or 0),
		BS.Comma(item.want or 0), BS.Comma(short)))

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
	if #shop.capped > 0 then
		self:PrintCapped(shop, "|cffffd100What you can make from this:|r")
		self:Print("|cff888888Everything was bought for those numbers, not the ones "
			.. "you typed - your Want column is untouched, so fixing the short reagent "
			.. "and running it again picks up the rest.|r")
	end

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
			if item.why and string.find(item.why, "dearer than", 1, true) then
				dear = dear + 1
			end
			self:Print(format("   %s|cff888888 - %s|r", item.link or item.name,
				item.why or "no reason recorded"))
		end

		if dear > 0 then
			self:Print(format("|cff888888%s priced above what the list allows. The "
				.. "limit is %d%% over the quoted price - |cffffffff/snipe shopmax "
				.. "<percent>|r|cff888888 moves it, and 0 means never pay a copper "
				.. "over.|r", dear == 1 and "That one was" or
				format("%d of those were", dear), self:ShopOver()))
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
function BS:ReportAchievable(shop)
	if not shop or not shop.origWants then return end

	local supply = {}
	for _, item in ipairs(shop.queue) do
		local bags, bank = BS.ReagentHave(item)
		supply[item.name] = (bags or 0) + (bank or 0) + (item.got or 0)
	end

	local can = self:SolveWants(shop.prof, shop.origWants, supply, shop.mode)

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
			end
		end
	end

	if not any then return end

	self:Print(short and "|cffffd100You now have the reagents for:|r"
		or "|cff00ff00Done - you have the reagents for everything you planned:|r")
	for _, line in ipairs(lines) do self:Print(line) end

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
