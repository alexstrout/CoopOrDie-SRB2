--[[
	Coop or Die! v0.x by fox: https://taraxis.com/

	--------------------------------------------------------------------------------
	Copyright (c) 2021 Alex Strout

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
	Extensively draws code from foxBot,
	Copyright (c) 2021 Alex Strout and CobaltBW - MIT License
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
	defaultvalue = "60",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 100}
})
local CV_CDEnemyClearMax = CV_RegisterVar({
	name = "cd_enemyclearmax",
	defaultvalue = "200",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = UINT16_MAX}
})
local CV_CDResetTagsOnDeath = CV_RegisterVar({
	name = "cd_resettagsondeath",
	defaultvalue = "Off",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_CDTeleMode = CV_RegisterVar({
	name = "cd_telemode",
	defaultvalue = "0",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = UINT16_MAX}
})
local CV_CDShowHud = CV_RegisterVar({
	name = "cd_showhud",
	defaultvalue = "On",
	flags = 0,
	PossibleValue = CV_OnOff
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

--Current percentage of enemies destroyed in stage
local enemyct = 0
local targetenemyct = 0
local notifythreshold = 0

--Current list of "active" mobj thinkers
local mobjthinkers = {}

--Track if we're a new client (re)joining the game
--This is needed as PlayerJoin does not fire for rejoining clients
local newclient = false

--NetVars!
addHook("NetVars", function(network)
	teamlives = network($)
	enemyct = network($)
	targetenemyct = network($)
	notifythreshold = network($)
	mobjthinkers = network($)
	newclient = true --Only set on server and joining client(s)
end)

--Cache of mobjthinker functions for quick lookup later
local mobjthinkerfunc = {}

--Enemies ineligible for enemyct / targetenemyct
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

--Resolve player by number (string or int)
local function ResolvePlayerByNum(num)
	if type(num) != "number"
		num = tonumber(num)
	end
	if num != nil and num >= 0 and num < 32
		return players[num]
	end
	return nil
end

--Returns absolute angle (0 to 180)
--Useful for comparing angles
local function AbsAngle(ang)
	if ang < 0 and ang > ANGLE_180
		return InvAngle(ang)
	end
	return ang
end

--Destroys mobj and returns nil for assignment shorthand
local function DestroyObj(mobj)
	if mobj and mobj.valid
		P_RemoveMobj(mobj)
	end
	return nil
end

--P_CheckSight wrapper to approximate sight checks for objects above/below FOFs
--Eliminates being able to "see" targets through FOFs at extreme angles
local function CheckSight(bmo, pmo)
	return bmo.floorz < pmo.ceilingz
		and bmo.ceilingz > pmo.floorz
		and P_CheckSight(bmo, pmo)
end



--[[
	--------------------------------------------------------------------------------
	LEADER SETUP FUNCTIONS / CONSOLE COMMANDS
	Any leader "setup" logic, including console commands
	This is exactly like foxBot's stuff, but we swap out:
		"ai" struct for "cdinfo"
		"ai_followers" struct for "cd_followers"
		Console command names
	--------------------------------------------------------------------------------
]]
--Reset (or define) all AI vars to their initial values
local function ResetAI(ai)
	ai.playernosight = 0 --How long the player has been out of view
	ai.doteleport = false --AI is attempting to teleport
	ai.reborn = false --Just recently reborn from hitting end of level
end

--Register follower with leader for lookup later
local function RegisterFollower(leader, bot)
	if not leader.cd_followers
		leader.cd_followers = {}
	end
	leader.cd_followers[#bot + 1] = bot
end

--Unregister follower with leader
local function UnregisterFollower(leader, bot)
	if not (leader and leader.valid and leader.cd_followers)
		return
	end
	leader.cd_followers[#bot + 1] = nil
	if table.maxn(leader.cd_followers) < 1
		leader.cd_followers = nil
	end
end

--Create AI table for a given player, if needed
local function SetupAI(player)
	if player.cdinfo
		return
	end

	--Create table, defining any vars that shouldn't be reset via ResetAI
	player.cdinfo = {
		leader = nil, --Bot's leader
		realleader = nil, --Bot's "real" leader (if temporarily following someone else)
		lastrings = 0, --Last ring count of bot (used for end-of-level teleport)
		lastxtralife = 0, --Last xtralife count of bot (also used for eol teleport)
		lastlives = player.lives --Last life count of bot (used to sync w/ team)
	}
	ResetAI(player.cdinfo) --Define the rest w/ their respective values
end

--Destroy AI table (and any child tables / objects) for a given player, if needed
local function DestroyAI(player)
	if not player.cdinfo
		return
	end

	--Unregister ourself from our (real) leader if still valid
	UnregisterFollower(player.cdinfo.realleader, player)

	--My work here is done
	player.cdinfo = nil
	collectgarbage()
end

--Get our "top" leader in a leader chain (if applicable)
--e.g. for A <- B <- D <- C, D's "top" leader is A
local function GetTopLeader(bot, basebot)
	if bot != basebot and bot.cdinfo
	and bot.cdinfo.realleader and bot.cdinfo.realleader.valid
		return GetTopLeader(bot.cdinfo.realleader, basebot)
	end
	return bot
end

--List all bots, optionally excluding bots led by leader
local function SubListBots(player, leader, bot, level)
	if bot == leader
		return 0
	end
	local msg = #bot .. " - " .. bot.name
	for i = 0, level
		msg = " " .. $
	end
	if bot.ai
		if bot.ai.cmd_time
			msg = $ .. " \x81(player-controlled)"
		end
		if bot.ai.ronin
			msg = $ .. " \x83(disconnected)"
		end
	else
		msg = $ .. " \x84(player)"
	end
	if bot.spectator
		msg = $ .. " \x87(KO'd)"
	end
	if bot.quittime
		msg = $ .. " \x86(disconnecting)"
	end
	CONS_Printf(player, msg)
	local count = 1
	if bot.cd_followers
		for _, b in pairs(bot.cd_followers)
			count = $ + SubListBots(player, leader, b, level + 1)
		end
	end
	return count
end
local function ListBots(player, leader)
	if leader != nil
		leader = ResolvePlayerByNum(leader)
		if leader and leader.valid
			CONS_Printf(player, "\x84 Excluding players/bots led by " .. leader.name)
		end
	end
	local count = 0
	for p in players.iterate
		if not (p.cdinfo and p.cdinfo.realleader)
			count = $ + SubListBots(player, leader, p, 0)
		end
	end
	CONS_Printf(player, "Returned " .. count .. " nodes")
end
COM_AddCommand("LISTPLAYERS", ListBots, COM_LOCAL)

--Set player as a bot following a particular leader
--Internal/Admin-only: Optionally specify some other player/bot to follow leader
local function SetBot(player, leader, bot)
	local pbot = player
	if bot != nil --Must check nil as 0 is valid
		pbot = ResolvePlayerByNum(bot)
	end
	if not (pbot and pbot.valid)
		CONS_Printf(player, "Invalid bot! Please specify a bot by number:")
		ListBots(player)
		return
	end

	--Make sure we won't end up following ourself
	local pleader = ResolvePlayerByNum(leader)
	if pleader and pleader.valid
	and GetTopLeader(pleader, pbot) == pbot
		CONS_Printf(player, pbot.name + " would end up following itself! Please try a different leader:")
		ListBots(player, #pbot)
		return
	end

	--Set up our AI (if needed) and figure out leader
	SetupAI(pbot)
	if pleader and pleader.valid
		CONS_Printf(player, "Tethering to " + pleader.name)
		if player != pbot
			CONS_Printf(pbot, player.name + " tethered " + pbot.name + " to " + pleader.name)
		end
	elseif pbot.cdinfo.realleader and pbot.cdinfo.realleader.valid
		CONS_Printf(player, "Untethering from " + pbot.cdinfo.realleader.name)
		if player != pbot
			CONS_Printf(pbot, player.name + " untethering " + pbot.name + " from " + pbot.cdinfo.realleader.name)
		end
	else
		CONS_Printf(player, "Invalid leader! Please specify a leader by number:")
		ListBots(player, #pbot)
	end

	--Valid leader?
	if pleader and pleader.valid
		--Unregister ourself from our old (real) leader (if applicable)
		UnregisterFollower(pbot.cdinfo.realleader, pbot)

		--Set the new leader
		pbot.cdinfo.leader = pleader
		pbot.cdinfo.realleader = pleader

		--Register ourself as a follower
		RegisterFollower(pleader, pbot)
	else
		--Destroy AI if no leader set
		DestroyAI(pbot)
	end

	--If we're a foxBot, update our AI leader as well
	if pbot.ai
		if bot != nil --Only setleadera can pass this arg
			COM_BufInsertText(player, "SETBOTA " + leader + " " + bot)
		else
			COM_BufInsertText(player, "SETBOT " + leader)
		end
	end
end
COM_AddCommand("SETLEADERA", SetBot, COM_ADMIN)
COM_AddCommand("SETLEADER", function(player, leader)
	SetBot(player, leader)
end, 0)

--Debug command for printing out AI objects
COM_AddCommand("DEBUG_CDINFODUMP", function(player, bot)
	bot = ResolvePlayerByNum(bot)
	if not (bot and bot.valid and bot.cdinfo)
		return
	end
	for k, v in pairs(bot.cdinfo)
		CONS_Printf(player, k .. " = " .. tostring(v))
	end
end, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	LEADER LOGIC
	Actual leader-related behavior etc.
	This is exactly like foxBot's stuff
	--------------------------------------------------------------------------------
]]
--Teleport a bot to leader, optionally fading out
local function Teleport(bot, fadeout)
	if not (bot.valid and bot.cdinfo)
	or bot.exiting or (bot.pflags & PF_FULLSTASIS) --Whoops
		--Consider teleport "successful" on fatal errors for cleanup
		return true
	end

	--Make sure everything's valid (as this is also called on respawn)
	--Check leveltime to only teleport after we've initially spawned in
	local leader = bot.cdinfo.leader
	if not (leveltime and leader and leader.valid)
	or leader.spectator --Don't teleport to spectators
		return true
	end
	local bmo = bot.realmo
	local pmo = leader.realmo
	if not (bmo and bmo.valid and pmo and pmo.valid)
	or pmo.health <= 0 --Don't teleport to dead leader!
		return true
	end

	--Leader in a zoom tube or other scripted vehicle?
	if leader.powers[pw_carry] == CR_NIGHTSMODE
	or leader.powers[pw_carry] == CR_ZOOMTUBE
	or leader.powers[pw_carry] == CR_MINECART
	or bot.powers[pw_carry] == CR_MINECART
		return true
	end

	--Teleport override?
	if CV_CDTeleMode.value
		--Probably successful if we're not in a panic and can see leader
		return not bot.cdinfo.playernosight
	end

	--Fade out (if needed), teleporting after
	if not fadeout
		bot.powers[pw_flashing] = TICRATE / 2 --Skip the fadeout time
	elseif not bot.powers[pw_flashing]
	or bot.powers[pw_flashing] > TICRATE
		bot.powers[pw_flashing] = TICRATE
	end
	if bot.powers[pw_flashing] > TICRATE / 2
		return false
	end

	--Adapted from 2.2 b_bot.c
	local z = pmo.z
	local zoff = pmo.height + 128 * pmo.scale
	if pmo.eflags & MFE_VERTICALFLIP
		z = max(z - zoff, pmo.floorz + pmo.height)
	else
		z = min(z + zoff, pmo.ceilingz - pmo.height)
	end
	bmo.flags2 = $
		& ~MF2_OBJECTFLIP | (pmo.flags2 & MF2_OBJECTFLIP)
		& ~MF2_TWOD | (pmo.flags2 & MF2_TWOD)
	bmo.eflags = $
		& ~MFE_VERTICALFLIP | (pmo.eflags & MFE_VERTICALFLIP)
		& ~MFE_UNDERWATER | (pmo.eflags & MFE_UNDERWATER)
	--bot.powers[pw_underwater] = leader.powers[pw_underwater] --Don't sync water/space time
	--bot.powers[pw_spacetime] = leader.powers[pw_spacetime]
	bot.powers[pw_gravityboots] = leader.powers[pw_gravityboots]
	bot.powers[pw_nocontrol] = leader.powers[pw_nocontrol]

	P_ResetPlayer(bot)
	bmo.state = S_PLAY_JUMP --Looks/feels nicer
	bot.pflags = $ | P_GetJumpFlags(bot)

	--Average our momentum w/ leader's - 1/4 ours, 3/4 theirs
	bmo.momx = $ / 4 + pmo.momx * 3/4
	bmo.momy = $ / 4 + pmo.momy * 3/4
	bmo.momz = $ / 4 + pmo.momz * 3/4

	--Zero momy in 2D mode (oops)
	if bmo.flags2 & MF2_TWOD
		bmo.momy = 0
	end

	P_TeleportMove(bmo, pmo.x, pmo.y, z)
	P_SetScale(bmo, pmo.scale)
	bmo.destscale = pmo.destscale
	bmo.angle = pmo.angle

	--Fade in (if needed)
	if bot.powers[pw_flashing] < TICRATE / 2
		bot.powers[pw_flashing] = TICRATE / 2
	end
	return true
end

--[[
	--------------------------------------------------------------------------------
	COOP OR DIE LOGIC
	Now we're getting into actual CD-specific stuff
	PreThinkFrameFor is very similar to foxBot's, but we alter a few things:
		All players have "cdinfo" structs, not just players following leaders
		Lives are synced game-wide via teamlives
		Added some logic to deny exiting if targetenemyct isn't met
		Altered leader logic (mostly to sync w/ foxBot)
		Additional range check added to bai.playernosight

	--------------------------------------------------------------------------------
]]
--Determine if we're a valid enemy for CD purposes
local function ValidEnemy(mobj)
	return mobj.flags & (MF_BOSS | MF_ENEMY)
end

--Set skincolor for target mobj based on source
local function SetColorFor(mobj, source)
	if source
		if source.player == consoleplayer
			if splitscreen
				mobj.color = SKINCOLOR_AZURE
			else
				mobj.color = SKINCOLOR_GREY
			end
		elseif source.player == secondarydisplayplayer
			mobj.color = SKINCOLOR_PINK
		else
			mobj.color = SKINCOLOR_YELLOW
		end
	else
		mobj.color = SKINCOLOR_YELLOW
	end
end

--Handle mobj tic logic for enemies
mobjthinkerfunc[1] = function(mobj) --MobjThinkForEnemy
	--Decrement frettime
	if mobj.cd_frettime
		mobj.cd_frettime = $ - 1
		if mobj.cd_frettime <= 0
			mobjthinkers[mobj] = nil
			mobj.cd_frettime = nil
			mobj.flags2 = $ & ~MF2_FRET
		end
	end
end

--Handle mobj tic logic for spheres
mobjthinkerfunc[2] = function(mobj) --MobjThinkForSphere
	--Decrement frettime
	if mobj.cd_frettime
		mobj.cd_frettime = $ - 1
		mobj.colorized = not $ --Flash on/off
		if mobj.cd_frettime <= 0
			mobjthinkers[mobj] = nil
			mobj.cd_frettime = nil

			--Set target color when done
			mobj.colorized = true
			SetColorFor(mobj, mobj.cd_lastattacker)
		end
	end
end

--Drive players based on whatever unholy mess is in this function
--Note that "bot" and "bai" are misnomers, but renames weren't necessary
local function PreThinkFrameFor(bot)
	if not bot.valid
		return
	end

	--CD: Ensure foxBot always thinks first (in case it was loaded after this)
	--There are some timing issues w/ life sync and EOL-warp ring transfer otherwise
	--Ugly, but there's no way to guarantee which order players will load addons
	if bot.ai and bot.ai.think_last != leveltime
	and bot.ai.PreThinkFrameFor != nil
		bot.ai.PreThinkFrameFor(bot)
	end

	--CD: Make sure we have a proper CoopOrDie info
	if not bot.cdinfo
		SetupAI(bot)
	end
	local bai = bot.cdinfo

	--CD: Handle lives here
	if bot.lives > 0
	and bai.lastlives > 0
		if bot.lives != bai.lastlives
			teamlives = bot.lives
		elseif teamlives > bot.lives
			if leveltime
				P_PlayLivesJingle(bot)
			end
			P_GivePlayerLives(bot, teamlives - bot.lives)
		else
			bot.lives = teamlives
		end
	end
	bai.lastlives = bot.lives

	--CD: Handle exiting here
	if (bot.pflags & PF_FINISHED)
	and enemyct < targetenemyct
		bai.lastrings = bot.rings
		bai.lastxtralife = bot.xtralife
		bot.starpostnum = 0
		bot.starposttime = 0
		bot.pflags = $ & ~PF_FINISHED
		bot.playerstate = PST_REBORN
		bai.reborn = true
		return
	end
	if bai.reborn
		bai.reborn = false
		bot.rings = bai.lastrings
		bot.xtralife = bai.lastxtralife
		S_StartSound(bmo, sfx_mixup)
		P_FlashPal(bot, PAL_MIXUP, TICRATE / 4)
	end

	--CD: Derp
	local leader = nil

	--CD: Just use same leader as foxBot if we're a bot
	if bot.ai
		bai.leader = bot.ai.leader
		bai.realleader = bot.ai.realleader

		--CD: Derp
		leader = bai.leader
	--CD: Otherwise...
	else
		--Bail here if no (real) leader
		--(unlike foxBot's ai struct, we may validly have a cdinfo w/ no realleader)
		if not bai.realleader
			return
		end

		--Find a new leader if ours quit
		if not (bai.leader and bai.leader.valid)
			--Reset to realleader if we have one
			if bai and bai.leader != bai.realleader
			and bai.realleader and bai.realleader.valid
				bai.leader = bai.realleader
				return
			end
			--CD: Otherwise don't bother
			--(foxBot will maintain its own valid leader if necessary)
			return
		end

		--CD: Derp
		leader = bai.leader

		--Reset leader to realleader if it's no longer valid or spectating
		--(we'll naturally find a better leader above if it's no longer valid)
		if leader != bai.realleader
		and (
			not (bai.realleader and bai.realleader.valid)
			or not bai.realleader.spectator
		)
			bai.leader = bai.realleader
			return
		end

		--Is leader spectating? Temporarily follow leader's leader
		if leader.spectator
		and leader.cdinfo
		and leader.cdinfo.leader
		and leader.cdinfo.leader.valid
		and GetTopLeader(leader.cdinfo.leader, leader) != leader
			bai.leader = leader.cdinfo.leader
			return
		end
	end

	--****
	--VARS (Player or AI)
	local bmo = bot.realmo
	local pmo = leader.realmo
	local cmd = bot.cmd
	if not (bmo and bmo.valid and pmo and pmo.valid)
		return
	end

	--Elements
	local flip = 1
	if bmo.eflags & MFE_VERTICALFLIP
		flip = -1
	end
	local scale = bmo.scale

	--Measurements
	local dist = R_PointToDist2(bmo.x, bmo.y, pmo.x, pmo.y)
	local zdist = FixedMul(pmo.z - bmo.z, scale * flip)

	--Check line of sight to player
	if CheckSight(bmo, pmo)
	and FixedHypot(dist, zdist) < 2048 * scale --CD: Add dist check here
		bai.playernosight = 0
	else
		bai.playernosight = $ + 1
	end

	--Check leader's teleport status
	if leader.cdinfo
		bai.playernosight = max($, leader.cdinfo.playernosight - TICRATE / 2)
	end

	--And teleport if necessary
	bai.doteleport = bai.playernosight > 3 * TICRATE
	if bai.doteleport and Teleport(bot, true)
		--Post-teleport cleanup
		bai.doteleport = false
		bai.playernosight = 0
		if bot.ai
			bot.ai.anxiety = 0
			bot.ai.panic = 0
		end
	end

	--Teleport override?
	if bai.doteleport and CV_CDTeleMode.value > 0
		cmd.buttons = $ | CV_CDTeleMode.value
	end
end

--Build hudtext for a particular player
local function BuildHudFor(v, stplyr, cam, player, i)
	--Ring hud!
	local rcolor = "\x82"
	if player.rings <= 0
	and leveltime % TICRATE < TICRATE / 2
		rcolor = "\x85"
	end
	hudtext[i] = rcolor .. "Rings \x80" .. player.rings
	hudtext[i + 1] = player.name
	if player == stplyr.cdinfo.leader
		hudtext[i + 1] = "\x83" .. $
	elseif player == stplyr.cdinfo.realleader
		hudtext[i + 1] = "\x87" .. $
	end

	--Spectating or dead?
	local pmo = player.realmo
	if player.spectator
	or not (pmo and pmo.valid)
	or pmo.health <= 0
		hudtext[i] = "\x86" .. "Dead.."
		hudtext[i + 2] = ""
		hudtext[i + 3] = ""
		return i + 4
	end

	local bmo = stplyr.realmo
	if bmo and bmo.valid
		--Distance
		local zdist = (pmo.z - bmo.z)
		local dist = FixedHypot(
			R_PointToDist2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			),
			zdist
		)
		hudtext[i + 2] = "Dist "
		if dist > 9999 * bmo.scale
		or dist < 0
			hudtext[i + 2] = $ .. "Far.."
		else
			hudtext[i + 2] = $ .. dist / bmo.scale
		end

		--Angle (note angleturn is converted to angle by constant of 16, not FRACBITS)
		local angle = stplyr.cmd.angleturn << 16
			- R_PointToAngle2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			)

		local dir = nil
		if AbsAngle(angle) > ANGLE_135
			dir = "v"
		elseif AbsAngle(angle) > ANGLE_45
			if angle < 0
				dir = "<"
			else
				dir = ">"
			end
		else
			dir = "^"
		end
		if abs(zdist) > 256 * bmo.scale
			if dist - abs(zdist) < dist / 8
				dir = "*"
			end
			if zdist < 0
				dir = "-" .. $
			else
				dir = "+" .. $
			end
		end
		hudtext[i + 3] = dir

		if player == stplyr.cdinfo.leader
			if stplyr.cdinfo.playernosight
				hudtext[i + 2] = "\x87" .. $
			end
			if stplyr.cdinfo.doteleport
				hudtext[i + 3] = "\x84Teleporting..."
			end
		end
	end
	return i + 4
end



--[[
	--------------------------------------------------------------------------------
	LUA HOOKS
	Define all hooks used to actually interact w/ the game
	--------------------------------------------------------------------------------
]]
--Tic? Tock! Call PreThinkFrameFor bot
addHook("PreThinkFrame", function()
	for player in players.iterate
		PreThinkFrameFor(player)
	end
	for k_mobj, v_func in pairs(mobjthinkers)
		mobjthinkerfunc[v_func](k_mobj)
	end

	--Handle anything required for (re)joining clients
	--Note that consoleplayer is server for a few tics on new clients
	--Thus, newclient never gets unset on the server itself, but that's ok
	if newclient and consoleplayer != server
		newclient = false

		--Fix grey enemies for mid-game joiners
		for mobj in mobjs.iterate()
			if mobj.cd_lastattacker
				SetColorFor(mobj, mobj.cd_lastattacker)
			end
		end
	end
end)

--Handle MapChange for resetting things
addHook("MapChange", function(mapnum)
	for player in players.iterate
		if player.cdinfo
			ResetAI(player.cdinfo)
		end
	end

	--Reset enemy count / notification threshold
	enemyct = 0
	targetenemyct = 0
	notifythreshold = 25

	--Reset mobjthinkers
	mobjthinkers = {}

	--Reset lives if exhausted
	teamlives = max($, 4)
end)

--Handle MapLoad for post-load actions
addHook("MapLoad", function(mapnum)
	--Decrement lives! Oof
	if not G_IsSpecialStage()
		for player in players.iterate
			teamlives = max($ - 1, 1)
		end
	end

	--Count up enemies
	--Only done here to avoid altering targetenemyct mid-game
	for mobj in mobjs.iterate()
		if ValidEnemy(mobj)
		and not mobj.info.cd_skipcount
			targetenemyct = $ + 1

			--Debug
			if CV_CDDebug.value
				mobj.colorized = true
				mobj.color = SKINCOLOR_ORANGE
			end
		end
	end
	targetenemyct = min(
		$ * CV_CDEnemyClearPct.value / 100,
		CV_CDEnemyClearMax.value
	)
end)

--Handle enemy spawning
addHook("MobjSpawn", function(mobj)
	--Flag enemy as "active" to run damage hooks etc. on
	if ValidEnemy(mobj)
		mobj.cd_active = true

		--Debug
		if CV_CDDebug.value
			mobj.colorized = true
			mobj.color = SKINCOLOR_GREEN
		end
	end
end)

--Handle enemy damage (now with more merp)
addHook("MobjDamage", function(target, inflictor, source, damage, damagetype)
	if target.cd_active
	and source and source.valid
		if not target.cd_lastattacker
			target.cd_lastattacker = {}
			target.cd_lastattacker.mo = source
			target.cd_lastattacker.player = source.player

			--Handle colorization
			target.colorized = true
			SetColorFor(target, source)

			--Spawn and immediately destroy a scorebop
			--This gives us POINTS using native scoring
			local scorebop = P_SpawnMobjFromMobj(target, 0, 0, 0, MT_FOXCD_SCOREBOP)
			scorebop.height = target.height
			P_KillMobj(scorebop, inflictor, source, damagetype)

			--Boop!
			mobjthinkers[target] = 1
			target.cd_frettime = TICRATE / 4
			target.flags2 = $ | MF2_FRET
			S_StartSound(target, sfx_dmpain)
			return true
		elseif target.cd_lastattacker.mo == source
		or target.cd_lastattacker.player == source.player
			--Merp
			if not target.cd_frettime
			and inflictor and inflictor.player
				mobjthinkers[target] = 1
				target.cd_frettime = TICRATE / 2
				S_StartSound(target, sfx_s3k7b)

				--Count number of merps, eventually retaliating
				--Bosses are mean and do this immediately
				if target.flags & MF_BOSS
					target.cd_merpcount = 1
				end
				if not target.cd_merpcount
					target.cd_merpcount = 3
				else
					target.cd_merpcount = $ - 1
					if target.cd_merpcount < 2
						--cd_frettime already set above
						target.flags2 = $ | MF2_FRET
					end
					if target.cd_merpcount <= 0
						S_StartSound(inflictor, sfx_shldls)
						P_DoPlayerPain(inflictor.player, target, target)
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
	if target.valid and target.cd_active
		target.cd_active = false
		target.cd_lastattacker = nil
		mobjthinkers[target] = nil

		--Decolorize for proper explosion fx
		target.colorized = false
		target.color = SKINCOLOR_NONE

		--Increment enemy count!
		if not target.info.cd_skipcount
			enemyct = $ + 1

			--Make noises!
			if targetenemyct > 0
			and consoleplayer.realmo
			and consoleplayer.realmo.valid
				if enemyct >= targetenemyct
					S_StartSound(consoleplayer.realmo, sfx_ideya, consoleplayer)
					targetenemyct = 0
				elseif notifythreshold <= 75
				and enemyct * 100 / targetenemyct >= notifythreshold
					S_StartSound(consoleplayer.realmo, sfx_3db06, consoleplayer)
					notifythreshold = 25 * ((enemyct * 100 / targetenemyct / 25) + 1)
				end
			end
		end
	end
end
addHook("MobjDeath", HandleDeath)
addHook("MobjRemoved", HandleDeath)

--Handle player death
addHook("MobjDeath", function(target, inflictor, source, damagetype)
	if CV_CDResetTagsOnDeath.value
		for mobj in mobjs.iterate()
			if mobj.cd_lastattacker
			and (
				mobj.cd_lastattacker.mo == target
				or mobj.cd_lastattacker.player == target.player
			)
				mobj.cd_lastattacker = nil

				--Decolorize
				mobj.colorized = false
				mobj.color = SKINCOLOR_NONE
			end
		end
	end
end, MT_PLAYER)

--Handle special stage spheres (unless we're in CR_NIGHTSMODE)
addHook("TouchSpecial", function(special, toucher)
	if toucher.player and toucher.player.valid
	and toucher.player.powers[pw_carry] == CR_NIGHTSMODE
		return nil
	end
	if not special.cd_lastattacker
		special.cd_lastattacker = {}
		special.cd_lastattacker.mo = toucher
		special.cd_lastattacker.player = toucher.player

		--Handle colorization
		special.colorized = true
		special.color = SKINCOLOR_WHITE

		--*iconic sphere noises*
		mobjthinkers[special] = 2
		special.cd_frettime = TICRATE / 8
		S_StartSound(toucher, sfx_s3k65)
		return true
	elseif special.cd_lastattacker.mo == toucher
	or special.cd_lastattacker.player == toucher.player
	or special.cd_frettime --Simulate MF2_FRET behavior
		return true
	end
end, MT_BLUESPHERE)

--Handle (re)spawning for bots
addHook("PlayerSpawn", function(player)
	if player.cdinfo
		--Engage!
		Teleport(player)
	end
end)

--Handle sudden quitting for bots
addHook("PlayerQuit", function(player, reason)
	if player.cdinfo
		DestroyAI(player)
	end
end)

--HUD hook!
hud.add(function(v, stplyr, cam)
	--If not previous text in buffer... (e.g. debug)
	if hudtext[1] == nil
		--And we're not a bot...
		if stplyr.cdinfo == nil
		or CV_CDShowHud.value == 0
			return
		end

		--Otherwise generate a simple bot hud
		local i = 100
		if targetenemyct > 0
			i = enemyct * 100 / targetenemyct
		end
		hudtext[1] = i .. "%"
		hudtext[2] = "Enemy Goal:"
		if i < 25
			hudtext[1] = "\x85" .. $
		elseif i < 50
			hudtext[1] = "\x84" .. $
		elseif i < 75
			hudtext[1] = "\x81" .. $
		elseif i < 100
			hudtext[1] = "\x8A" .. $
		else
			hudtext[1] = "\x83" .. "Done!"
		end

		--Put leader up top
		i = 3
		if stplyr.cdinfo.leader
		and stplyr.cdinfo.leader.valid
			i = BuildHudFor(v, stplyr, cam, stplyr.cdinfo.leader, i)

			--And realleader right below if different (e.g. dead)
			if stplyr.cdinfo.realleader != stplyr.cdinfo.leader
			and stplyr.cdinfo.realleader
			and stplyr.cdinfo.realleader.valid
				i = BuildHudFor(v, stplyr, cam, stplyr.cdinfo.realleader, i)
			end
		end

		--Draw rest of players
		for player in players.iterate
			if player != stplyr
			and player != stplyr.cdinfo.leader
			and player != stplyr.cdinfo.realleader
			and player.mo and player.mo.valid --Infers not spectator.. for now
			and player.mo.health > 0
				i = BuildHudFor(v, stplyr, cam, player, i)
			end

			--Stop after 12 players
			if i > 50 --12 players * 4 hudtext each + 2 for enemyct
				break
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
	if G_IsSpecialStage()
		y = $ + 32
	end

	--Account for splitscreen
	--Avoiding V_PERPLAYER as text gets a bit too squashed
	if splitscreen
		y = $ / 2
		if #stplyr > 0
			y = $ + 108 --Magic!
		end
	end

	--Small fonts become illegible at low res
	if v.height() < 400
		size = nil
		size_r = "right"
		scale = 2
	end

	--Draw! Flushing hudtext after
	for k, s in ipairs(hudtext)
		if k & 1
			v.drawString(320 - x - 30 * scale, y, s, V_SNAPTOTOP | V_SNAPTORIGHT | v.localTransFlag(), size)
		else
			v.drawString(320 - x - 34 * scale, y, s, V_SNAPTOTOP | V_SNAPTORIGHT | v.localTransFlag(), size_r)
			y = $ + 4 * scale

			--Insert a small line break between players
			if (k + 2) % 4 == 0
				y = $ + 2 * scale

				--Wrap to another column if needed
				if (k + 2) % 64 == 0 --16 players * 4 hudtext each
					x = $ + 64 * scale
					y = $ - 160 * scale --Honor splitscreen etc.
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
		"\x87 Coop or Die! v0.x: 2021-XX-XX",
		"",
		"\x87 MP Server Admin:",
		"\x80  cd_enemyclearpct - Required % of enemies for level completion",
		"\x80  cd_enemyclearmax - Maximum # of enemies for level completion",
		"\x80  cd_resettagsondeath - Reset players' enemy tags on death?",
		"\x80  cd_telemode - Override teleport behavior w/ button press?",
		"\x86   (64 = fire, 1024 = toss flag, 4096 = alt fire, etc.)",
		"",
		"\x87 MP Client:",
		"\x80  cd_showhud - Draw CoopOrDie info to HUD?",
		"\x80  setleader <leader> - Follow <leader> by number \x86(-1 = stop)",
		"\x80  listplayers - List active bots and players"
	)
	if not player
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
