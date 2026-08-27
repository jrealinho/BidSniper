--[[--------------------------------------------------------------------------
	BidSniper - one GetAll, and both addons' answers out of it

	GetAll is a single request for the entire auction house, and the client
	allows it about once every fifteen minutes. That cooldown belongs to the
	client, not to the addon that used it, so whoever asks first has spent it
	for everybody.

	The Piggyback setting already covers one direction of that: press
	Auctionator's full scan and we read the dump it asked for, filling in beside
	it for free. This is the other direction. Press Scan AH here and Auctionator
	updates its price database from the same dump - one request, one cooldown,
	both addons' automations run.

	The awkward part is who reads it first, and it is worth explaining, because
	the obvious arrangement quietly loses data.

	Auctionator finishes a full scan by throwing the dump away: it queries for
	an item called "xyzzy" purely to replace forty thousand rows with none and
	give the memory back. Sensible on its own, fatal to anyone still reading -
	and we do still read, a slice per frame, because walking that many rows in
	one go freezes the client for seconds.

	So the order is forced. We ask Auctionator to make the request, then hold it
	still while the dump arrives; we read the whole thing at our own pace; and
	only when we have finished do we let it look. It reads an untouched list,
	updates its database, and throws the list away when nobody needs it.

	Holding it still is one global: Auctionator decides whether to process an
	incoming auction list by looking at gAtr_FullScanState, so setting that back
	to idle is enough for the dump to pass it by. Nothing is hooked, nothing is
	replaced, and its own code does every piece of the work on its own data.

	This does reach into another addon's internals, which is worth being honest
	about: it is version-specific by nature. Every global it touches is checked
	for before anything happens, and if any of them is missing or has changed
	shape, the scan falls back to making its own request and says so. Being
	wrong here would mean writing rubbish into somebody's price database, so the
	checks are the point rather than politeness.
]]

local BS = BidSniper
if not BS then return end

local format = string.format

-- NUM_AUCTION_ITEMS_PER_PAGE, hardcoded as in the core file so nothing has to
-- be loaded. A result larger than one page is a dump; nothing else makes one.
local ITEMS_PER_PAGE = 50

--=============================================================================
--  is Auctionator here, and is it the Auctionator we know?
--=============================================================================

--[[
	Checked as a set rather than one at a time.

	A build with some of these and not others is a version this was not written
	against, and the failure mode for guessing is not a Lua error - it is
	Auctionator's price database overwritten with something wrong. So a partial
	match counts as no match, and the scan makes its own request instead.
]]
function BS:AtrAvailable()
	return type(Atr_FullScanStart)   == "function"
	   and type(Atr_FullScanAnalyze) == "function"
	   and type(gAtr_FullScanState)  == "number"
	   and type(ATR_FS_NULL)         == "number"
	   and type(ATR_FS_STARTED)      == "number"
	   and type(Atr_FullScanStatus)      == "table"
	   and type(Atr_FullScanStartButton) == "table"
	   and type(Atr_FullScanDone)        == "table"
end

--[[
	Put Auctionator's own full-scan panel back to how it looks when nothing is
	happening.

	Its scan normally re-enables these itself at the end of processing. When we
	hold it still and then never hand it the dump - the scan was stopped, the
	request timed out, the auction house closed - nobody does, and its Start
	Scanning button would stay dead until a reload for no visible reason.
]]
local function RestoreAtrPanel()
	pcall(function()
		Atr_FullScanStatus:SetText("")
		Atr_FullScanStartButton:Enable()
		Atr_FullScanDone:Enable()
	end)
end

--=============================================================================
--  asking Auctionator to make the request
--=============================================================================

--[[
	Returns true when Auctionator has sent the GetAll and is being held; the
	caller must then not send one of its own.

	The decision is read back out of gAtr_FullScanState rather than assumed,
	because Atr_FullScanStart declines silently when GetAll is on cooldown - it
	simply does nothing at all. State moving to STARTED is the addon's own
	record that it committed, and it is set immediately before the request goes
	out, so it is the honest answer to "did a query leave".
]]
function BS:AtrFullScanBegin()
	if not self.db.atrSync then return false end
	if not self:AtrAvailable() then return false end

	-- its own scan is already running, which means it asked first; leave it
	-- alone and let Piggyback pick the dump up on the way past
	if gAtr_FullScanState ~= ATR_FS_NULL then return false end

	pcall(Atr_FullScanStart)

	if gAtr_FullScanState ~= ATR_FS_STARTED then
		-- it declined, and declining happens before it queries, so nothing has
		-- been spent and the caller is free to ask itself
		return false
	end

	--[[
		Held from here. Auctionator processes an incoming list only while this
		reads STARTED, so putting it back to idle means the dump arrives, we
		read it, and its own handler lets it go by without touching it.

		Idle is the right value to park on rather than one of the mid-scan ones:
		if this session ends badly - a reload, a disconnect, an error somewhere
		else entirely - the state it is left sitting in is the one it would have
		been in anyway.
	]]
	self.atrParked     = true
	gAtr_FullScanState = ATR_FS_NULL

	self:Print("|cff00ff00Sharing this scan with Auctionator|r - it made the request, "
		.. "we read it first, and its prices are updated from the same dump when we "
		.. "are done. One request, one cooldown.")
	return true
end

--=============================================================================
--  handing the dump over when we have finished with it
--=============================================================================

--[[
	Let Auctionator read the list we have just finished reading.

	The size check is the one thing here that must never be skipped. Auctionator
	writes whatever is in the auction list into its price database and does not
	ask where the list came from - that is exactly what makes this possible, and
	exactly what makes it dangerous. Hand it a fifty-row page instead of the
	dump and it would happily overwrite a server's worth of prices with one page
	of them.

	So: anything that is not obviously still the dump is refused, and the panel
	is put back instead. A shared scan that quietly does not happen costs a
	fifteen minute wait. A shared scan that writes one page over the database
	costs every price in it.
]]
function BS:AtrFullScanHandOff()
	if not self.atrParked then return false end

	if not self:AtrAvailable() then
		self.atrParked = nil
		return false
	end

	local num = GetNumAuctionItems("list")
	if not num or num <= ITEMS_PER_PAGE then
		self:Print("|cffff8800Auctionator was not given the scan|r - the auction list "
			.. "is no longer the full dump, and handing it a single page would "
			.. "overwrite its prices with it. Its database is untouched.")
		self:AtrRelease()
		return false
	end

	self.atrParked     = nil
	gAtr_FullScanState = ATR_FS_STARTED

	--[[
		From here it is entirely Auctionator's code on Auctionator's data: it
		walks the list, works out its own lowest prices, writes its own
		database, stamps its own last-scan time and clears the list down. We do
		not interpret a single row of it, which is the whole reason its numbers
		can be trusted afterwards.
	]]
	local ok = pcall(Atr_FullScanAnalyze)

	if not ok then
		gAtr_FullScanState = ATR_FS_NULL
		RestoreAtrPanel()
		self:Print("|cffff8800Auctionator could not read the shared scan.|r Ours is "
			.. "unaffected; run Auctionator's own full scan when the cooldown is up.")
		return false
	end

	return true
end

--[[
	Let go without handing anything over.

	For every way a scan can end without a dump to give: stopped by hand, the
	request never answered, the auction house closed. Auctionator's database is
	not touched - there is nothing to touch it with - and its panel goes back to
	idle so the Start Scanning button works again.
]]
function BS:AtrRelease()
	if not self.atrParked then return end
	self.atrParked = nil

	if not self:AtrAvailable() then return end

	gAtr_FullScanState = ATR_FS_NULL
	RestoreAtrPanel()
end

--[[
	The end of a scan, whichever way it went.

	One place to call from, so no exit from the scan has to remember which of
	the two endings it is: a GetAll that read a dump hands it over, and anything
	else lets go. A paged scan that got here after falling back from GetAll is
	the reason this is not simply "hand it over".

	Answers true only when Auctionator actually read the dump, because that is
	the moment its price database stops being the one from before this scan -
	and the caller has prices of its own to throw away when it does.
]]
function BS:AtrScanEnded(readDump)
	if not self.atrParked then return false end
	if readDump then
		return self:AtrFullScanHandOff() and true or false
	end
	self:AtrRelease()
	return false
end

--=============================================================================
--  the setting
--=============================================================================

function BS:ToggleAtrSync()
	self.db.atrSync = not self.db.atrSync

	if self.db.atrSync then
		self:Print("Shared GetAll |cff00ff00on|r - a fast scan here is made by "
			.. "Auctionator and read by both, so its prices come up to date with ours "
			.. "on one cooldown.")
		if not self:AtrAvailable() then
			self:Print("|cffff8800Auctionator is not loaded, or is a version this does "
				.. "not recognise.|r Scans will make their own request as before.")
		end
	else
		self:Print("Shared GetAll |cffff8800off|r - a fast scan here makes its own "
			.. "request, and Auctionator's prices stay where they were until you run "
			.. "its own full scan.")
	end
end

function BS:AtrSyncStatus()
	if not self.db.atrSync then return "off" end
	if not self:AtrAvailable() then return "on, but Auctionator is not available" end
	return "on"
end
