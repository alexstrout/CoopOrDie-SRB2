--[[
	Coop or Die! v1.2 by fox: https://taraxis.com/CoopOrDie-SRB2

	--------------------------------------------------------------------------------
	Copyright (c) 2026 Alex Strout

	Permission is hereby granted, free of charge, to any person obtaining a copy of
	this software and associated documentation files (the "Software"), to deal in
	the Software without restriction, including without limitation the rights to
	use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
	of the Software, and to permit persons to whom the Software is furnished to do
	so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.

	--------------------------------------------------------------------------------
	Extensively draws code from foxBot, see license-foxBot.txt or:
	https://github.com/alexstrout/foxBot-SRB2/blob/master/license.txt
]]



--[[
	--------------------------------------------------------------------------------
	GLOBAL CONVARS
	(see "bothelp" at bottom for a description of each)
	--------------------------------------------------------------------------------
]]
local CV_CDDebug = CV_RegisterVar({
	name = "cd_debug",
	defaultvalue = "Off",
	flags = 0,
	PossibleValue = CV_OnOff
})
local CV_CDEnemyClearPct = CV_RegisterVar({
	name = "cd_enemyclearpct",
	defaultvalue = "40",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 100}
})
local CV_CDEnemyClearMax = CV_RegisterVar({
	name = "cd_enemyclearmax",
	defaultvalue = "75",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = UINT16_MAX}
})
local CV_CDDMFlags = CV_RegisterVar({
	name = "cd_dmflags",
	defaultvalue = "7",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 15}
})
local CV_CDTeamLives = CV_RegisterVar({
	name = "cd_teamlives",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_CDEmeraldBonus = CV_RegisterVar({
	name = "cd_emeraldbonus",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_CDShowHud = CV_RegisterVar({
	name = "cd_showhud",
	defaultvalue = "On",
	flags = 0,
	PossibleValue = CV_OnOff
})
local CV_CDHudMaxPlayers = CV_RegisterVar({
	name = "cd_hudmaxplayers",
	defaultvalue = "4",
	flags = 0,
	PossibleValue = {MIN = 0, MAX = 32}
})
local CV_CDHudSortTime = CV_RegisterVar({
	name = "cd_hudsorttime",
	defaultvalue = "2",
	flags = 0,
	PossibleValue = {MIN = -1, MAX = 10}
})



--[[
	--------------------------------------------------------------------------------
	GLOBAL TYPE DEFINITIONS
	Defines any mobj types etc. needed by CoopOrDie
	--------------------------------------------------------------------------------
]]
freeslot(
	"MT_FOXCD_SCOREBOP"
)
---@diagnostic disable-next-line: missing-fields
mobjinfo[MT_FOXCD_SCOREBOP] = {
	spawnstate = S_INVISIBLE,
	radius = FRACUNIT,
	height = FRACUNIT,
	flags = MF_NOGRAVITY|MF_NOCLIP|MF_NOTHINK|MF_NOCLIPHEIGHT|MF_ENEMY
}



--[[
	--------------------------------------------------------------------------------
	GLOBAL HELPER VALUES / FUNCTIONS
	Used in various points throughout code
	--------------------------------------------------------------------------------
]]
--Team lives for sync
local teamlives = 0
local revivequeue = {}
local lastmapnum = 0

--Level times (for NoReload reset detection)
local levelstarttime = 0
local lastleveltime = 0

--Current percentage of enemies destroyed in stage
local enemyct = 0
local targetenemyct = 0
local pendingenemyct = 0
local pendingenemycttime = 0
local notifythreshold = 0

--Current list of "active" mobj thinkers
local mobjthinkers = {}

--Track if we're a new client (re)joining the game
--This is needed as PlayerJoin does not fire for rejoining clients
local newclient = false

--NetVars!
addHook("NetVars", function(network)
	teamlives = network($)
	revivequeue = network($)
	lastmapnum = network($)
	levelstarttime = network($)
	lastleveltime = network($)
	enemyct = network($)
	targetenemyct = network($)
	pendingenemyct = network($)
	pendingenemycttime = network($)
	notifythreshold = network($)
	mobjthinkers = network($)
	newclient = true --Only set on server and joining client(s)
end)

--Sound to play next frame for teamlives-related noises
local lifesfx = nil
local lastlifesfx = nil

--Cache of mobjthinker functions for quick lookup later
local mobjthinkerfunc = {}

--Enemies ineligible for enemyct / targetenemyct
--These are signified by not having damage mechanics applied
--mobjinfo[MT_DETON].cd_skipcount = true
--mobjinfo[MT_POINTY].cd_skipcount = true
--mobjinfo[MT_EGGGUARD].cd_skipcount = true
mobjinfo[MT_CANARIVORE].cd_skipcount = true
--mobjinfo[MT_PTERABYTE].cd_skipcount = true
mobjinfo[MT_BIGMINE].cd_skipcount = true
mobjinfo[MT_ROSY].cd_skipcount = true
mobjinfo[MT_BUMBLEBORE].cd_skipcount = true
mobjinfo[MT_FOXCD_SCOREBOP].cd_skipcount = true

--Enemies that bots should spin-attack when tagged
mobjinfo[MT_SPINCUSHION].cd_aispinattack = true
mobjinfo[MT_SPRINGSHELL].cd_aispinattack = true
mobjinfo[MT_YELLOWSHELL].cd_aispinattack = true

--Enemies that bots should prioritize when tagged
mobjinfo[MT_HIVEELEMENTAL].cd_aipriority = true

--Text table used for HUD hook
local hudtext = {}

--Various HUD hook helpers
local hudinfo = {}

--Resolve player by name or number (string or int)
local function ResolvePlayer(bot)
	--Try num first
	local num = tonumber(bot)
	if num != nil and num >= 0 and num < 32 then
		return players[num]
	end

	--Try name
	if type(bot) == "string" then --Double-check before using string lib
		bot = string.lower($)
		for pbot in players.iterate do
			if string.lower(string.sub(pbot.name, 1, string.len(bot))) == bot then
				return pbot
			end
		end
	end

	--Merp, none here!
	return nil
end

--Returns absolute angle (0 to 180)
--Useful for comparing angles
local function AbsAngle(ang)
	if ang < 0 and ang > ANGLE_180 then
		return InvAngle(ang)
	end
	return ang
end



--[[
	--------------------------------------------------------------------------------
	CDINFO SETUP FUNCTIONS / CONSOLE COMMANDS
	Any CoopOrDie info "setup" logic, including console commands
	This is a lot like foxBot's stuff, but we swap out:
		"ai" struct for "cdinfo"
		"ai_followers" struct for "cd_pinnedplayers"
		Function / console command names
	--------------------------------------------------------------------------------
]]
--Reset (or define) all CDInfo vars to their initial values
local function ResetCDInfo(player)
	local pci = player.cdinfo
	pci.needsrevive = false --Spectating after hitting 0 lives
	pci.awardshieldtime = 0 --Time after which a shield is awarded
	pci.finished = false --Previously finished level at some point
	pci.laststarpostnum = player.starpostnum --Last starpost we've reached
	pci.reexittimeout = 0 --If reborn again in this time, end level instead of warp
end

--Register pin with player for lookup later
local function RegisterPinnedPlayer(player, pin)
	if not player.cd_pinnedplayers then
		player.cd_pinnedplayers = {}
	end
	if player.cd_pinnedplayers[pin] then
		return false
	end
	player.cd_pinnedplayers[pin] = pin
	return true
end

--Unregister pin with player
local function UnregisterPinnedPlayer(player, pin)
	if not (player.cd_pinnedplayers and player.cd_pinnedplayers[pin]) then
		return false
	end
	player.cd_pinnedplayers[pin] = nil
	if not next(player.cd_pinnedplayers) then
		player.cd_pinnedplayers = nil
	end
	return true
end

--Unregister all pins with player
local function UnregisterAllPinnedPlayers(player)
	if player.cd_pinnedplayers then
		for _, pin in pairs(player.cd_pinnedplayers) do
			UnregisterPinnedPlayer(player, pin)
		end
		return true
	end
	return false
end

--Create CDInfo table for a given player, if needed
local function SetupCDInfo(player)
	if player.cdinfo then
		return
	end

	--Create table, defining any vars that shouldn't be reset via ResetCDInfo
	player.cdinfo = {
		lastshield = SH_NONE, --Last shield of player (used for end-of-level teleport)
		lastlives = player.lives, --Last life count of player (used to sync w/ team)
		useteamlives = false, --Current sync setting for teamlives
		reborn = false --Just recently reborn from hitting end of level
	}
	ResetCDInfo(player) --Define the rest w/ their respective values
end

--Destroy CDInfo table (and any child tables / objects) for a given player, if needed
local function DestroyCDInfo(player)
	if not player.cdinfo then
		return
	end

	--Remove us from the revive queue
	for k, v in ipairs(revivequeue) do
		if v == player then
			table.remove(revivequeue, k)
			break
		end
	end

	--Unregister us from all players' pinned players
	for p in players.iterate do
		UnregisterPinnedPlayer(p, player)
	end

	--My work here is done
	player.cdinfo = nil
	collectgarbage()
end

--CONS_Printf but substituting consoleplayer for secondarydisplayplayer
local function ConsPrint(player, ...)
	if player == secondarydisplayplayer then
		player = consoleplayer
	end
	CONS_Printf(player, ...)
end

--List all players, possible including pins only
local function ListPlayers(player)
	local count = 0
	for p in players.iterate do
		local msg = " " .. #p .. " - " .. p.name

		--Use different formatting for splitscreen
		if splitscreen then
			if p == consoleplayer then
				msg = $ .. " \x88(1p)"
			elseif p == secondarydisplayplayer then
				msg = $ .. " \x8E(2p)"
			end

			if consoleplayer
			and consoleplayer.valid
			and consoleplayer.cd_pinnedplayers
			and consoleplayer.cd_pinnedplayers[p] then
				msg = $ .. " \x84(1p pinned)"
			end
			if secondarydisplayplayer
			and secondarydisplayplayer.valid
			and secondarydisplayplayer.cd_pinnedplayers
			and secondarydisplayplayer.cd_pinnedplayers[p] then
				msg = $ .. " \x85(2p pinned)"
			end
		else
			if p == player then
				msg = $ .. " \x8A(you)"
			end

			if player.cd_pinnedplayers
			and player.cd_pinnedplayers[p] then
				msg = $ .. " \x81(pinned)"
			end
		end
		ConsPrint(player, msg)
		count = $ + 1
	end
	ConsPrint(player, "Returned " .. count .. " nodes")
end
COM_AddCommand("LISTPLAYERS", ListPlayers, COM_LOCAL)

--Pin a particular player to the coop hud
local function PinPlayer(player, pin)
	--Make sure we're valid / won't end up pinning ourself
	pin = ResolvePlayer($)
	if not (pin and pin.valid) or pin == player then
		if pin == player then
			ConsPrint(player, "You can't pin yourself! Please try a different player:")
		else
			ConsPrint(player, "Invalid player! Please specify a player by number:")
		end
		ListPlayers(player)
		return
	end

	--Pin that player!
	if RegisterPinnedPlayer(player, pin) then
		ConsPrint(player, "Pinning " .. pin.name)
	else
		ConsPrint(player, "Already pinned " .. pin.name .. "!")
	end
end
COM_AddCommand("PINPLAYER2", PinPlayer, COM_SPLITSCREEN)
COM_AddCommand("PINPLAYER", PinPlayer, 0)

--Unpin a particular player from the coop hud
local function UnpinPlayer(player, pin)
	--Make sure we have pins!
	if not player.cd_pinnedplayers then
		ConsPrint(player, "You don't have any pinned players!")
		return
	end

	--Support "all" argument
	if pin != nil and string.lower(pin) == "all"
	and UnregisterAllPinnedPlayers(player) then
		ConsPrint(player, "Unpinning all players")
		return
	end

	--Make sure we're valid / won't end up unpinning ourself
	pin = ResolvePlayer($)
	if not (pin and pin.valid) or pin == player then
		if pin == player then
			ConsPrint(player, "You can't unpin yourself! Please try a different player:")
		else
			ConsPrint(player, "Invalid player! Please specify a player by number:")
		end
		ListPlayers(player)
		return
	end

	--Unpin that player!
	if UnregisterPinnedPlayer(player, pin) then
		ConsPrint(player, "Unpinning " .. pin.name)
	else
		ConsPrint(player, "Already unpinned " .. pin.name .. "!")
	end
end
COM_AddCommand("UNPINPLAYER2", UnpinPlayer, COM_SPLITSCREEN)
COM_AddCommand("UNPINPLAYER", UnpinPlayer, 0)

--Debug command for printing out CDInfo objects
local function DumpNestedTable(player, t, level, pt)
	local function ResolveName(v)
		local ret = tostring(v)
		if type(v) == "userdata" and v.valid and v.name then
			ret = $ .. "\x8C (" .. tostring(v.name) .. ")\x80"
		end
		return ret
	end

	pt[t] = true
	for k, v in pairs(t) do
		local msg = ResolveName(k) .. " = " .. ResolveName(v)
		for i = 0, level do
			msg = " " .. $
		end
		ConsPrint(player, msg)
		if type(v) == "table" and not pt[v] then
			DumpNestedTable(player, v, level + 1, pt)
		end
	end
end
COM_AddCommand("DEBUG_CDINFODUMP", function(player, bot)
	if string.lower(tostring(bot)) == "hud" then
		ConsPrint(player, "-- hudinfo --")
		DumpNestedTable(player, hudinfo, 0, {})
		return
	end
	bot = ResolvePlayer($)
	if not (bot and bot.valid) then
		ConsPrint(player, "-- mobjthinkers --")
		DumpNestedTable(player, mobjthinkers, 0, {})
		ConsPrint(player, "-- revivequeue --")
		DumpNestedTable(player, revivequeue, 0, {})
		return
	end
	if bot.cdinfo then
		ConsPrint(player, "-- cdinfo " .. bot.name .. " --")
		DumpNestedTable(player, bot.cdinfo, 0, {})
	end
	if bot.cd_pinnedplayers then
		ConsPrint(player, "-- cd_pinnedplayers " .. bot.name .. " --")
		DumpNestedTable(player, bot.cd_pinnedplayers, 0, {})
	end
end, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	COOP OR DIE LOGIC
	Now we're getting into actual CD-specific stuff
	--------------------------------------------------------------------------------
]]
--Get the next threshold to do an audio notification at
--(and other cool things now, like team revive)
local function GetNextNotifyThreshold(threshold)
	if targetenemyct == 0
	or enemyct >= targetenemyct then
		return -1
	end
	return 25 * ((enemyct * 100 / targetenemyct / 25) + 1)
end

--Determine if we're a valid enemy for CD purposes
local function ValidEnemy(mobj)
	return (mobj.flags & (MF_BOSS | MF_ENEMY))
		and mobj.info.spawnhealth < 16 --Skip anything crazy
		and mobj.health > 0 --Doesn't hurt to check
		and not mobj.info.cd_skipcount
end

--Set skincolor for target mobj based on source
local function SetColorFor(mobj, source)
	if source and source.player then
		if source.player == consoleplayer then
			if splitscreen then
				mobj.color = SKINCOLOR_AZURE
			else
				mobj.color = SKINCOLOR_GREY
			end
		elseif source.player == secondarydisplayplayer then
			mobj.color = SKINCOLOR_PINK
		else
			mobj.color = SKINCOLOR_YELLOW
		end
	else
		mobj.color = SKINCOLOR_YELLOW
	end
end

--Handle mobj tic logic for enemies
local MobjThinkForEnemy = 1
mobjthinkerfunc[MobjThinkForEnemy] = function(mobj)
	--Decrement frettime
	if mobj.cd_frettime then
		mobj.cd_frettime = $ - 1
		if mobj.cd_frettime <= 0 then
			mobjthinkers[mobj] = nil
			mobj.cd_frettime = nil
			mobj.flags2 = $ & ~MF2_FRET
		end
	end
end

--Handle mobj tic logic for spheres
local MobjThinkForSphere = 2
mobjthinkerfunc[MobjThinkForSphere] = function(mobj)
	--Decrement frettime
	if mobj.cd_frettime then
		mobj.cd_frettime = $ - 1
		mobj.colorized = not $ --Flash on/off
		if mobj.cd_frettime <= 0 then
			mobjthinkers[mobj] = nil
			mobj.cd_frettime = nil

			--Set target color when done
			mobj.colorized = true
			SetColorFor(mobj, mobj.cd_lastattacker)
		end
	end
end

--Print various event messages
local function PrintDownMessage(player)
	print(player.name .. " is out!")
end
local function PrintReviveMessage(player)
	if player then --Assumed valid
		print(player.name .. " has revived!")
	else
		print("The party has revived via a 1up monitor!")
	end
end
local function PrintRebornMessage(player)
	--Assumes targetenemyct > enemyct > 0
	print(player.name .. " has warped to start. (" .. 100 - (enemyct * 100 / targetenemyct) .. "% enemy goal remaining)")
end

--Think for players!
local function PreThinkFrameFor(player)
	if not player.valid then
		return
	end

	--Make sure we have a proper CoopOrDie info
	if not player.cdinfo then
		SetupCDInfo(player)
	end
	local pci = player.cdinfo

	--Handle lives here - note that useteamlives lags behind a tic
	--This fixes some timing issues w/ foxBot if loaded first
	if pci.useteamlives
	and player.lives > 0
	and pci.lastlives > 0 then
		if player.lives != pci.lastlives then
			teamlives = player.lives
		elseif leveltime > levelstarttime then
			if teamlives > player.lives
			and not lifesfx --Revive sound takes priority
			and (
				--Play sound only for local players
				player == consoleplayer
				or player == secondarydisplayplayer
			) then
				lifesfx = sfx_3db09
			end
			player.lives = teamlives
		end
	--KO'd? Register for revive if not already
	elseif player.lives <= 0
	and pci.lastlives <= 0
	and not pci.needsrevive then
		pci.needsrevive = true
		table.insert(revivequeue, player)

		--Do teamlives mechanics if enabled; otherwise, just reset to 1
		if CV_CDTeamLives.value then
			PrintDownMessage(player)
		else
			teamlives = 1
		end
	end
	pci.useteamlives = CV_CDTeamLives.value --Set based on setting
		and not (player.ai and player.ai.synclives) --And foxBot sync

	--Handle revives
	if pci.needsrevive
	and (
		(
			--Team revive
			teamlives > 1
			and (
				player.lives > pci.lastlives --Party revive via 1up
				or revivequeue[1] == player --Next in queue
			)
		)
		or (
			--Somehow revived on our own
			player.mo and player.mo.valid
			and player.mo.health > 0
		)
	) then
		pci.needsrevive = false
		for k, v in ipairs(revivequeue) do
			if v == player then
				table.remove(revivequeue, k)
				break
			end
		end
		--Do teamlives mechanics if enabled; otherwise, just reset to 1
		if CV_CDTeamLives.value then
			--Decrement teamlives if not a 1up
			if player.lives <= pci.lastlives then
				teamlives = max($ - 1, 1)
				PrintReviveMessage(player)
			--Otherwise print a party revive message once
			elseif #revivequeue == 0 then
				PrintReviveMessage()
			end
			lifesfx = sfx_marioa --Takes priority over other lifesfx
		else
			teamlives = 1
		end
		player.lives = teamlives
		player.spectator = false
		player.playerstate = PST_REBORN
	end
	pci.lastlives = player.lives

	--Handle exiting here
	if (player.pflags & PF_FINISHED)
	and enemyct < targetenemyct then
		--Short-circuit failsafe for custom exit triggers
		if pci.reexittimeout > 0 then
			pci.reexittimeout = 0
			pendingenemyct = targetenemyct - enemyct
			pendingenemycttime = 1 --Process this tic
			return
		end

		--Record last shield if applicable
		pci.lastshield = player.powers[pw_shield]

		--Reset starposts
		player.starpostnum = 0
		player.starposttime = 0
		pci.laststarpostnum = 0

		--If we're a bot, bump our leader to the top of the queue
		--This prevents us from continually respawning at the exit
		if player.ai
		and player.ai.leader
		and player.ai.leader.valid
		and player.ai.leader.spectator then
			for k, v in ipairs(revivequeue) do
				if v == player.ai.leader then
					table.remove(revivequeue, k)
					table.insert(revivequeue, 1, v)
					break
				end
			end
		end

		--Remember that we finished level for later
		pci.finished = true

		--Unset our finished state and queue for respawn
		player.pflags = $ & ~PF_FINISHED
		player.playerstate = PST_REBORN
		pci.reborn = true
		pci.reexittimeout = TICRATE / 2
		PrintRebornMessage(player)

		--Revive someone if needed
		teamlives = max($, 2)
		return
	--Reapply finished state if we previously finished level
	--Note this is cleared on map reset so we don't cheat the time bonus
	elseif pci.finished
	and targetenemyct > 0
	and enemyct >= targetenemyct then
		P_DoPlayerFinish(player)
		pci.finished = false
	elseif pci.reexittimeout > 0 then
		pci.reexittimeout = $ - 1
	end
	if pci.reborn then
		pci.reborn = false

		--Rings don't carry over - instead, we get reborn w/ bonus rings
		--This keeps things simple and also means we can re-earn extra lives
		--This also stacks with ring-sync bots and that's ok
		player.rings = $ + 20

		--We'll also get additional bonus rings if we have all emeralds
		--This does not stack with ring-sync bots since that would be ridiculous
		if All7Emeralds(emeralds)
		and not (player.ai and player.ai.syncrings)
		and CV_CDEmeraldBonus.value then
			player.rings = $ + 20
		end

		--Carry over shield, if applicable - otherwise queue shield award
		if (pci.lastshield & SH_NOSTACK)
		and pci.lastshield != SH_PINK then
			P_SwitchShield(player, pci.lastshield)
			pci.lastshield = SH_NONE
		elseif leveltime == levelstarttime then --Randomize a bit on level start
			pci.awardshieldtime = P_RandomByte() * TICRATE / 170
		else
			pci.awardshieldtime = TICRATE
		end

		--Woosh!
		if player.realmo and player.realmo.valid
		and (leveltime > levelstarttime or player == consoleplayer) then
			S_StartSound(player.realmo, sfx_mixup)
		end
		P_FlashPal(player, PAL_MIXUP, TICRATE / 4)
	end

	--Revive someone if we've hit a new starpost?
	if player.starpostnum > pci.laststarpostnum then
		teamlives = max($, 2)

		--Set for all players to avoid coopstarposts issues
		for p in players.iterate do
			if p.cdinfo then
				p.cdinfo.laststarpostnum = p.starpostnum
			end
		end
	end

	--Award shields if queued
	if pci.awardshieldtime > 0 then
		pci.awardshieldtime = $ - 1
		if pci.awardshieldtime <= 0 then
			--Pick from array of random shields
			local shieldchoices = {
				SH_ARMAGEDDON,
				SH_ELEMENTAL,
				SH_ATTRACT,
				SH_FLAMEAURA,
				SH_BUBBLEWRAP,
				SH_THUNDERCOIN,
				SH_PITY | SH_FIREFLOWER
			}
			local i = P_RandomKey(#shieldchoices) + 1

			--Switch that shield! Honoring an existing SH_STACK if present
			P_SwitchShield(player, (pci.lastshield & SH_STACK) | shieldchoices[i])
			pci.lastshield = SH_NONE

			--Sounds and fireflower color
			if player.realmo and player.realmo.valid then
				if player.powers[pw_shield] & SH_FIREFLOWER then
					player.realmo.color = SKINCOLOR_WHITE
				end
				S_StartSound(player.realmo, sfx_shield)
			end
		end
	end
end



--[[
	--------------------------------------------------------------------------------
	LUA HOOKS
	Define all hooks used to actually interact w/ the game
	--------------------------------------------------------------------------------
]]
--Tic? Tock! Call thinker functions for players and any registered mobjthinkers
addHook("PreThinkFrame", function()
	for player in players.iterate do
		PreThinkFrameFor(player)
	end

	--Process mobjthinkers
	--Note: pairs is typically not netsafe, as it iterates in an arbitrary order
	--See https://wiki.srb2.org/wiki/Lua/Functions#Base_Lua_functions
	--However, it's OK here as long as mobjthinkers don't care which order they execute in
	for k_mobj, v_func in pairs(mobjthinkers) do
		if k_mobj.valid then
			mobjthinkerfunc[v_func](k_mobj)
		else
			mobjthinkers[k_mobj] = nil
		end
	end

	--Handle any pendingenemyct
	if pendingenemycttime > 0 then
		pendingenemycttime = $ - 1
		if pendingenemycttime <= 0
		or pendingenemyct + enemyct >= targetenemyct then
			enemyct = $ + pendingenemyct
			pendingenemyct = 0

			--Make noises! And revive players
			if notifythreshold > 0 and targetenemyct > 0
			and enemyct * 100 / targetenemyct >= notifythreshold then
				notifythreshold = GetNextNotifyThreshold($)
				teamlives = max($, 2)
				if consoleplayer and consoleplayer.valid then
					if enemyct >= targetenemyct then
						S_StartSound(nil, sfx_ideya, consoleplayer)
					else
						S_StartSound(nil, sfx_3db06, consoleplayer)
					end
				end
			end
		end
	end

	--Play any lifesfx set for this frame
	if lifesfx and lifesfx == lastlifesfx then
		if consoleplayer and consoleplayer.valid then
			S_StartSound(nil, lifesfx, consoleplayer)
		end
		lifesfx = nil
	end
	lastlifesfx = lifesfx

	--Handle anything required for (re)joining clients
	--Note that consoleplayer is server for a few tics on new clients
	--Thus, newclient never gets unset on the server itself, but that's ok
	if newclient
	and consoleplayer
	and consoleplayer != server then
		newclient = false

		--Fix grey enemies for mid-game joiners
		for mobj in mobjs.iterate() do
			if mobj.cd_lastattacker then
				SetColorFor(mobj, mobj.cd_lastattacker)
			end
		end
	end

	--Record lastleveltime, for reset detection
	lastleveltime = leveltime
end)

--Handle MapChange for resetting things
local function HandleMapChange(mapnum)
	for player in players.iterate do
		if player.cdinfo then
			ResetCDInfo(player)

			--Reset a few more things if different map
			if mapnum != lastmapnum then
				player.cdinfo.reborn = false
			--Hand out shields if restarting map from death
			elseif teamlives <= 1 then
				player.cdinfo.reborn = true
			end
		end
	end

	--Clean up HUD tables
	hudinfo = {}

	--Reset level times
	levelstarttime = 0
	lastleveltime = 0

	--Reset enemy count, unless we're restarting the map
	if mapnum != lastmapnum then
		enemyct = 0
	elseif multiplayer then
		enemyct = $ / 2 --Unchanged for singleplayer
	end
	targetenemyct = 0
	pendingenemyct = 0
	pendingenemycttime = 0
	notifythreshold = -1

	--Reset revivequeue / mobjthinkers
	revivequeue = {}
	mobjthinkers = {}
	collectgarbage()

	--Reset teamlives - set by PlayerSpawn later
	teamlives = 1
end
addHook("MapChange", HandleMapChange)

--Handle MapLoad for post-load actions
local PostMapLoadFor = 3
mobjthinkerfunc[PostMapLoadFor] = function(mobj)
	if mobj.cd_counttime then
		mobj.cd_counttime = $ - 1
		if mobj.cd_counttime <= 0 then
			mobjthinkers[mobj] = nil
			mobj.cd_counttime = nil

			--Count up enemies
			--Only done here to avoid altering targetenemyct mid-game
			for mobj in mobjs.iterate() do
				if mobj.cd_active and ValidEnemy(mobj) then
					targetenemyct = $ + mobj.info.spawnhealth

					--Debug
					if CV_CDDebug.value and not netgame then
						mobj.colorized = true
						mobj.color = SKINCOLOR_ORANGE
					end
				end
			end
			if CV_CDDebug.value then
				print("-- CDDebug: Counted " .. targetenemyct .. " enemies * spawnhealth")
			end
			targetenemyct = min(
				--40% of 1 enemy is still 1 enemy!
				FixedCeil($ * FRACUNIT * CV_CDEnemyClearPct.value / 100) / FRACUNIT,
				CV_CDEnemyClearMax.value
			)
			if CV_CDDebug.value then
				print("-- CDDebug: Adjusting count to " .. targetenemyct)
			end
			notifythreshold = GetNextNotifyThreshold($)
		end
	end
end
local function HandleMapLoad(mapnum)
	if G_IsSpecialStage() then
		--Tighten special stage time!
		if CV_CDDMFlags.value & 4 then
			local count = 0
			for player in players.iterate do
				if not (player.spectator or player.outofcoop) then
					count = $ + 1
				end
			end
			for player in players.iterate do
				player.nightstime = max($ * 3 / max(count, 3), 60 * TICRATE)
			end
		end
	end
	lastmapnum = mapnum

	--Handle any post-MapLoad logic - just use mobjthinkers for this
	--Server may be nil when exiting to title, but should otherwise always be valid
	if server and server.valid then
		mobjthinkers[server] = PostMapLoadFor
		server.cd_counttime = TICRATE
	end
end
addHook("MapLoad", HandleMapLoad)

--Handle enemy spawning
local function HandleMobjSpawn(mobj)
	--Flag boss types as priority AI target
	if mobj.info.flags & MF_BOSS then
		mobj.info.cd_aipriority = true
	end

	--Flag enemy as "active" to run damage hooks etc. on
	if ValidEnemy(mobj) then
		mobj.cd_active = true

		--Debug
		if CV_CDDebug.value and not netgame then
			mobj.colorized = true
			mobj.color = SKINCOLOR_GREEN
		end
	end
end
addHook("MobjSpawn", HandleMobjSpawn)

--Handle enemy collision (no collide on merp)
local function HandleCollide(tmthing, thing)
	if thing.cd_frettime
	and thing.cd_lastattacker
	and (
		thing.cd_lastattacker.mo == tmthing
		or (tmthing.player and thing.cd_lastattacker.player == tmthing.player)
	) then
		return false
	end
end
addHook("MobjCollide", HandleCollide, MT_PLAYER)
addHook("MobjMoveCollide", HandleCollide, MT_PLAYER)

--Handle enemy damage (now with more merp)
addHook("MobjDamage", function(target, inflictor, source, damage, damagetype)
	if target.cd_active
	and source and source.valid
	and (CV_CDDMFlags.value & 1)
	and not (
		--Nukes and other big explosions also instantly deal real damage
		damagetype == DMG_NUKE
		or (damagetype & (DMG_CANHURTSELF | DMG_DEATHMASK))
	) then
		if not target.cd_lastattacker then
			target.cd_lastattacker = {
				mo = source,
				player = source.player
			}

			--Handle colorization
			target.colorized = true
			SetColorFor(target, source)

			--Spawn and immediately destroy a scorebop
			--This gives us POINTS using native scoring
			local scorebop = P_SpawnMobjFromMobj(target, 0, 0, 0, MT_FOXCD_SCOREBOP)
			scorebop.height = target.height
			P_KillMobj(scorebop, inflictor, source, damagetype)

			--Boop!
			mobjthinkers[target] = MobjThinkForEnemy
			target.cd_frettime = TICRATE / 4
			target.flags2 = $ | MF2_FRET
			S_StartSound(target, sfx_dmpain)
			return true
		elseif target.cd_lastattacker.mo == source
		or (source.player and target.cd_lastattacker.player == source.player) then
			--Merp
			if inflictor
			and not target.cd_frettime then
				mobjthinkers[target] = MobjThinkForEnemy
				target.cd_frettime = TICRATE / 2
				S_StartSound(target, sfx_s3k7b)

				--Count number of merps, eventually retaliating
				if not target.cd_merpcount then
					target.cd_merpcount = 3
				else
					target.cd_merpcount = $ - 1
					if target.cd_merpcount < 2 then
						--cd_frettime already set above
						target.flags2 = $ | MF2_FRET
					end
					if target.cd_merpcount <= 0 then
						--Player or player-like buddy object :)
						if inflictor.player then
							S_StartSound(inflictor, sfx_shldls)
							P_DoPlayerPain(inflictor.player, target, target)
						elseif inflictor.info.spawnstate == mobjinfo[MT_PLAYER].spawnstate then
							S_StartSound(inflictor, sfx_shldls)
							inflictor.state = S_PLAY_PAIN
						end
						target.cd_merpcount = nil
					end
				end
			end
			return true
		else
			--Allow hit trading on bosses etc.
			target.cd_lastattacker = nil

			--Decolorize for proper explosion fx / bosses
			target.colorized = false
			target.color = SKINCOLOR_NONE
		end
	end
end)

--Handle enemy death
local function HandleDeath(target, inflictor, source, damagetype)
	--Need to check valid as MobjRemoved may fire outside level
	--Also check leveltime in case any enemies are removed at level start
	--(+ 1 tic incase we're spamming retry for some reason)
	if leveltime > levelstarttime + 1
	and target.valid and target.cd_active then
		target.cd_active = false
		target.cd_lastattacker = nil
		mobjthinkers[target] = nil

		--Decolorize for proper explosion fx
		target.colorized = false
		target.color = SKINCOLOR_NONE

		--Increment enemy count!
		pendingenemyct = $ + target.info.spawnhealth
		pendingenemycttime = TICRATE / 2
	end
end
addHook("MobjDeath", HandleDeath)
addHook("MobjRemoved", HandleDeath)

--Handle player death
addHook("MobjDeath", function(target, inflictor, source, damagetype)
	if CV_CDDMFlags.value & 8 then
		for mobj in mobjs.iterate() do
			if mobj.cd_lastattacker
			and (
				mobj.cd_lastattacker.mo == target
				or (target.player and mobj.cd_lastattacker.player == target.player)
			) then
				mobj.cd_lastattacker = nil

				--Decolorize
				mobj.colorized = false
				mobj.color = SKINCOLOR_NONE
			end
		end
	end
end, MT_PLAYER)

--Handle special stage spheres
addHook("TouchSpecial", function(special, toucher)
	if not (CV_CDDMFlags.value & 2)
	or not multiplayer then --No teammates in singleplayer special stages
		return nil
	end
	if not special.cd_lastattacker then
		special.cd_lastattacker = {
			mo = toucher,
			player = toucher.player
		}

		--Handle colorization
		special.colorized = true
		special.color = SKINCOLOR_WHITE

		--*iconic sphere noises*
		mobjthinkers[special] = MobjThinkForSphere
		special.cd_frettime = TICRATE / 8
		S_StartSound(toucher, sfx_s3k65)
		return true
	elseif special.cd_lastattacker.mo == toucher
	or (toucher.player and special.cd_lastattacker.player == toucher.player)
	or special.cd_frettime then --Simulate MF2_FRET behavior
		return true
	end
end, MT_BLUESPHERE)

--Handle (re)spawning for players
local function HandlePlayerSpawn(player)
	--Players get awards w/ all emeralds since it's more difficult
	if All7Emeralds(emeralds)
	and CV_CDEmeraldBonus.value then
		SetupCDInfo(player) --For first-time joiners; safe if existing
		player.cdinfo.reborn = true --No effect on eol teleport
	end

	--Handle NoReload resets
	if leveltime < lastleveltime then
		HandleMapChange(lastmapnum)
		HandleMapLoad(lastmapnum)
	end

	--Record level start time (for NoReload levels)
	--This could be in MapLoad, but dedicated servers start w/ no players
	if levelstarttime == 0 then
		levelstarttime = leveltime
	end

	--Match teamlives to (highest) expected player lives at level start
	if leveltime == levelstarttime then
		teamlives = max($, player.lives)
	end
end
addHook("PlayerSpawn", HandlePlayerSpawn)

--Handle sudden quitting for players
addHook("PlayerQuit", function(player, reason)
	if player.cdinfo then
		DestroyCDInfo(player)
	end

	--Clean up HUD tables
	hudinfo[#player] = nil
end)

--HUD hook!
local function BuildHudFor(v, stplyr, cam, player, i, namecolor)
	--Already drawn this tic?
	local huddrawntime = hudinfo[#stplyr].drawntime
	if huddrawntime[player] == stplyr.jointime then
		return i
	end
	huddrawntime[player] = stplyr.jointime

	--Only draw one player / bot per bot group! Unless pinned
	local leader = (player.ai and (player.ai.realleader or player.ai.leader))
		or player.botleader --Lua's wild! (evaluates bool-ish but returns value!)
	if leader and leader.valid then
		if huddrawntime[leader] == stplyr.jointime
		and not (stplyr.cd_pinnedplayers and stplyr.cd_pinnedplayers[player]) then
			return i
		end
		huddrawntime[leader] = stplyr.jointime
	else
		--Inspect us for bot count
		leader = player
	end

	--Ring / time hud!
	local rcolor = "\x82"
	if player.nightstime then
		if player.mo and player.mo.valid
		and (player.mo.eflags & (MFE_TOUCHWATER | MFE_UNDERWATER))
		and leveltime % (TICRATE / 4) < TICRATE / 8 then
			rcolor = "\x85"
		end
		hudtext[i] = rcolor .. "Time \x80" .. player.nightstime / TICRATE
	else
		if player.rings <= 0
		and leveltime % TICRATE < TICRATE / 2 then
			rcolor = "\x85"
		end
		hudtext[i] = rcolor .. "Rings \x80" .. player.rings
	end
	if string.len(player.name) > 11 then
		hudtext[i + 1] = string.sub(player.name, 0, 10) .. ".."
	else
		hudtext[i + 1] = player.name
	end
	if namecolor then
		hudtext[i + 1] = namecolor .. $
	end

	--Draw bot count i/a (foxBot only, tricky to tally vanilla bots here)
	if leader and leader.valid
	and leader.ai_followers and #leader.ai_followers > 1 then
		hudtext[i + 1] = $ .. "\x84 +" .. #leader.ai_followers - 1
	end

	--Spectating or dead? (will only display if AI leader or pinned)
	local pmo = player.realmo
	if player.spectator
	or not (pmo and pmo.valid)
	or pmo.health <= 0 then
		hudtext[i] = "\x86" .. "Dead.."
	end
	hudtext[i + 2] = ""
	hudtext[i + 3] = ""

	local bmo = stplyr.realmo
	if bmo and bmo.valid
	and pmo and pmo.valid then
		--Distance (pre-scaled for approximate drawing purposes - can get very large)
		local zdist = (pmo.z - bmo.z) / bmo.scale
		local dist = FixedHypot(
			R_PointToDist2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			) / bmo.scale,
			zdist
		)
		hudtext[i + 2] = "\x86" .. "Dist "
		if dist > INT16_MAX
		or dist < 0 then
			hudtext[i + 2] = $ .. "Far.."
		else
			hudtext[i + 2] = $ .. dist / 100
		end

		--Angle (note angleturn is converted to angle by constant of 16, not FRACBITS)
		local angle = stplyr.cmd.angleturn << 16
			- R_PointToAngle2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			)

		local dir = nil
		if dist <= 256 then
			dir = " "
		elseif AbsAngle(angle) > ANGLE_135 then
			dir = "v"
		elseif AbsAngle(angle) > ANGLE_45 then
			if angle < 0 then
				dir = "<"
			else
				dir = ">"
			end
		else
			dir = "^"
		end
		if abs(zdist) > 256 then
			if dist - abs(zdist) < dist / 8 then
				dir = " "
			end
			if zdist < 0 then
				dir = "-" .. $
			else
				dir = "+" .. $
			end
		end
		hudtext[i + 3] = "\x86" .. dir
	end

	--Keep simple foxBot concepts in case player prefers only this hud
	local bot = (stplyr.ai and stplyr.ai.leader == player) and stplyr
		or (player.ai and player.ai.realleader == stplyr) and player or nil
	if bot then
		if bot.ai.playernosight then
			hudtext[i + 2] = "\x87" .. string.sub($, 2)
		end
		if bot.ai.cmd_time > 0
		and bot.ai.cmd_time < 3 * TICRATE then
			hudtext[i + 3] = "\x81" .. "AI ctl: " .. bot.ai.cmd_time / TICRATE + 1 .. ".."
		elseif bot.ai.doteleport then
			hudtext[i + 3] = "\x84Teleport.."
		end
	end

	--Return increment
	return i + 4
end
hud.add(function(v, stplyr, cam)
	--If not previous text in buffer... (e.g. debug)
	if hudtext[1] == nil then
		--And we don't want a hud...
		if CV_CDShowHud.value == 0 then
			return
		end

		--Otherwise generate a simple coop hud
		if targetenemyct > 0 then
			local ct = enemyct * 100 / targetenemyct
			hudtext[1] = ct .. "%"
			hudtext[2] = "Enemy Goal:"
			if pendingenemyct then
				hudtext[1] = $ .. " \x83+" .. pendingenemyct .. "x"
			end
			if ct < 25 then
				hudtext[1] = "\x85" .. $
			elseif ct < 50 then
				hudtext[1] = "\x84" .. $
			elseif ct < 75 then
				hudtext[1] = "\x81" .. $
			elseif ct < 100 then
				hudtext[1] = "\x8A" .. $
			else
				hudtext[1] = "\x83" .. "DONE!"
			end
		else
			hudtext[1] = ""
			hudtext[2] = ""
		end

		--Resolve per-player hudinfo tables
		local phudinfo = hudinfo[#stplyr]
		if not phudinfo then
			phudinfo = {
				drawntime = {},
				dist = {},
				playersbydist = {}
			}
			hudinfo[#stplyr] = phudinfo
		end
		local hudplayersbydist = phudinfo.playersbydist

		--Sort players by dist every so often
		local hudsorttime = CV_CDHudSortTime.value
		if hudsorttime <= 0
		or leveltime % (hudsorttime * TICRATE) == 0 then
			--(Re)pack array
			local i = 1
			for player in players.iterate do
				hudplayersbydist[i] = player
				i = $ + 1
			end
			while hudplayersbydist[i] do
				phudinfo.drawntime[hudplayersbydist[i]] = nil
				phudinfo.dist[hudplayersbydist[i]] = nil
				hudplayersbydist[i] = nil
				i = $ + 1
			end

			--If sorting...
			if hudsorttime >= 0 then
				--Grab dists for everyone
				local huddist = phudinfo.dist
				for _, player in ipairs(hudplayersbydist) do
					local bmo = stplyr.realmo
					local pmo = player.realmo
					if bmo and bmo.valid
					and pmo and pmo.valid
					and pmo.health > 0 then
						huddist[player] = FixedHypot(
							R_PointToDist2(
								bmo.x, bmo.y,
								pmo.x, pmo.y
							) / bmo.scale,
							(pmo.z - bmo.z) / bmo.scale
						)
					else
						huddist[player] = INT32_MAX
					end
				end

				--And sort!
				table.sort(hudplayersbydist, function(p1, p2)
					return huddist[p1] < huddist[p2]
				end)
			end
		end

		--Put AI leader up top if using foxBot (or vanilla botleader!)
		local i = 3 --First 2 are enemyct
		if stplyr.ai then
			if stplyr.ai.realleader and stplyr.ai.realleader.valid then
				i = BuildHudFor(v, stplyr, cam, stplyr.ai.realleader, i, "\x83")
			elseif stplyr.ai.leader and stplyr.ai.leader.valid then --Legacy foxBot? Idk
				i = BuildHudFor(v, stplyr, cam, stplyr.ai.leader, i, "\x87")
			end
		elseif stplyr.botleader and stplyr.botleader.valid then
			i = BuildHudFor(v, stplyr, cam, stplyr.botleader, i, "\x84")
		end

		--Put any pinned players after
		if stplyr.cd_pinnedplayers then
			for _, player in ipairs(hudplayersbydist) do
				if stplyr.cd_pinnedplayers[player] and player.valid then
					i = BuildHudFor(v, stplyr, cam, player, i, "\x81")
				end
			end
		end

		--Draw rest of players
		local hudmax = CV_CDHudMaxPlayers.value
		for _, player in ipairs(hudplayersbydist) do
			if player.valid then
				--Account for cd_hudmaxplayers
				if i <= hudmax * 4 + 2 --4 hudtext each + 2 for enemyct
				and player != stplyr
				and not player.spectator then
					i = BuildHudFor(v, stplyr, cam, player, i)
				end
			end
		end
	end

	--Positioning / size
	local x = 16
	local y = 16
	local size = "small"
	local size_r = "small-right"
	local scale = 1

	--Special stage?
	if G_IsSpecialStage() then
		y = $ + 32
	end

	--Small fonts become illegible at low res
	if v.height() < 400 then
		size = nil
		size_r = "right"
		scale = 2
	end

	--Draw! Flushing hudtext after
	--This is messy and made more sense in foxBot, but oh well
	for k, s in ipairs(hudtext) do
		if k & 1 then
			if k == 1 then --Enemy goal % (e.g. "26% +1x")
				v.drawString(320 - x - 30 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | V_PERPLAYER | V_ALLOWLOWERCASE | v.localTransFlag(), size)
			else
				v.drawString(320 - x - 30 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | V_PERPLAYER | v.localTransFlag(), size)
			end
		else
			if k > 2 and (k + 2) % 4 == 0 --Direction indicator
			and string.len(s) < 4 then --Displaying a direction
				v.drawString(320 - x - 34 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | V_PERPLAYER | V_MONOSPACE | V_ALLOWLOWERCASE | v.localTransFlag(), size_r)
			else
				v.drawString(320 - x - 34 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | V_PERPLAYER | v.localTransFlag(), size_r)
			end
			y = $ + 4 * scale

			--Insert a small line break between players
			if (k + 2) % 4 == 0 then
				y = $ + 2 * scale

				--Wrap to another column if needed
				if (k + 2) % (68 / scale) == 0 then --17 players * 4 hudtext each
					x = $ + 80 * scale
					y = $ - 160 * scale --Honor prior adjustments (special stage etc.)
				end
			end
		end
		hudtext[k] = nil
	end
end, "game")



--[[
	--------------------------------------------------------------------------------
	HELP STUFF
	Things that may or may not be helpful
	--------------------------------------------------------------------------------
]]
local function BotHelp(player)
	print(
		"\x87 Coop or Die! v1.2: 2026-xx-xx",
		"",
		"\x87 MP Server Admin:",
		"\x80  cd_enemyclearpct - Required % of enemies for level completion",
		"\x80  cd_enemyclearmax - Maximum # of enemies for level completion",
		"\x80  cd_dmflags - Difficulty modifier flags",
		"\x86   (1 = Enemies require 2+ hits from different players)",
		"\x86   (2 = Spheres require 2 pickups from different players)",
		"\x86   (4 = Special Stages restrict time based on player count)",
		"\x86   (8 = Players reset their tagged enemy hits on death)",
		"\x83   Note: These options can be combined by adding them together!",
		"\x80  cd_teamlives - Share team lives using goal-driven revive mechanics?",
		"\x80  cd_emeraldbonus - Award ring / shield bonuses on spawn w/ all emeralds?",
		"",
		"\x87 MP Client:",
		"\x80  cd_showhud - Draw CoopOrDie info to HUD?",
		"\x80  cd_hudmaxplayers - Maximum # of players to draw on HUD",
		"\x80  cd_hudsorttime - Interval to sort HUD by distance \x86(-1 = no sorting)",
		"\x80  pinplayer <player> - Pin <player> to HUD",
		"\x80  unpinplayer <player> - Unpin <player> from HUD \x86(\"all\" = all players)",
		"\x80  listplayers - List active players"
	)
	if not player then
		print(
			"",
			"\x87 Use \"cdhelp\" to show this again!"
		)
	end
end
COM_AddCommand("CDHELP", BotHelp, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	INIT ACTIONS
	Actions to take once we've successfully initialized
	--------------------------------------------------------------------------------
]]
BotHelp() --Display help

if gamestate == GS_LEVEL then
	HandleMapChange(gamemap)
	for mobj in mobjs.iterate() do
		HandleMobjSpawn(mobj)
	end
	HandleMapLoad(gamemap)
	for player in players.iterate do
		HandlePlayerSpawn(player)
	end
end
