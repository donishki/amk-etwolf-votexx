---
-- Enhanced voting for ET server.
-- Author: a domestic cat
---

local MOD_NAME = "vote++.lua"

-- bg_public.h
local CS_VOTE_TIME   = 6
local CS_VOTE_STRING = 7
local CS_VOTE_YES    = 8
local CS_VOTE_NO     = 9

-- client commands
local CMD_CALLVOTE      = "callvote"
local CMD_REFEREE       = "ref"
local CMD_VOTE          = "vote"
local CMD_PASSVOTE_XX   = "passvote++"
local CMD_CANCELVOTE_XX = "cancelvote++"
local CMD_PASSVOTE      = "passvote"
local CMD_CANCELVOTE    = "cancelvote"

-- client command arguments
local ARG_VOTE_YES = "yes"

-- formatting
local FORMAT_CP    = 'cp "%s"'
local FORMAT_CPM   = 'cpm "%s"'
local FORMAT_PRINT = 'print "%s"'
local FORMAT_CS    = 'cs %i "%s"\n'

-- messages
local MSG_CALLVOTE_IN_PROGRESS = "A vote is already in progress.\n"
local MSG_VOTE_ALREADY_CAST    = "Vote already cast.\n"
local MSG_VOTE_SPECTATOR       = "Not allowed to vote as spectator.\n"
local MSG_CALLED_VOTE_PRINT    = "[lof]%s^7 [lon]called a vote.[lof]  Voting for: %s\n"
local MSG_CALLED_VOTE_CP       = "[lof]%s\n^7[lon]called a vote.\n"
local MSG_VOTE_DISABLED        = "Sorry, [lof]^3%s^7 [lon]voting has been disabled\n"
local MSG_VOTE_FAILED          = "^2Vote FAILED! ^3(%s^3)"
local MSG_VOTE_FAILED_LOG      = "Vote Failed: %s\n"
local MSG_VOTE_CANCELLED       = "Vote cancelled"
local MSG_VOTE_PASSED          = "^5Vote passed!\n"
local MSG_VOTE_PASSED_LOG      = "Vote Passed: %s\n"
local MSG_INVALID_VOTE_STRING  = "Invalid vote string.\n"
local MSG_INVALID_SLOT_NUMBER  = "Invalid slot number.\n"
local MSG_CLIENT_NOT_FOUND     = "No players matching '%s' found.\n"
local MSG_AMBIGUOUS_CLIENT     = "Multiple players matching '%s' found.\n"
local MSG_CLIENT_NOT_ACTIVE    = "Client %d is not active\n"
local MSG_REFEREE_CHANGE       = "^1** Referee Server Setting Change **\n"

-- sounds
local SOUND_BELL    = "sound/misc/vote.wav"
local SOUND_REFEREE = "sound/misc/referee.wav"

-- misc
local VOTE_TIME           = 30000
local VOTE_TIME_MIN       = 1000
local TEAM_AXIS           = 1
local TEAM_ALLIES         = 2
local TEAM_SPECTATOR      = 3
local ENT_SESSION_TEAM    = "sess.sessionTeam"
local ENT_SESSION_REF     = "sess.referee"
local ENT_PERS_NETNAME    = "pers.netname"
local ENT_PERS_VOTE_COUNT = "pers.voteCount"
local ENT_INUSE           = "inuse"
local CONFIG_NAME         = "vote++.config.lua"

-- vote types
local VOTE_SCOPE_GLOBAL
local VOTE_SCOPE_TEAM   = 1

-- local scope
local this = {
 
	-- virtual vote info
	info = {
		time       = nil,
		voteString = "",
		voted      = {}, -- cno: bool
		yes        = 0,
		no         = 0,
		caller     = nil,
		callerTeam = nil,
		target     = nil,
		targetTeam = nil,
		handler    = nil,
		arguments  = {},
		dirty      = false,
	},

	-- referee info
	ref = {
		caller     = nil,
		callerTeam = nil,
		target     = nil,
		targetTeam = nil,
		handler    = nil,
		arguments  = {},
	},

	-- context, points to this.info or this.ref
	context = nil,

	-- do not trap server console commands if set
	callbackExecuting = false,

	time       = 0,  -- level time
	commands   = {}, -- vote handlers
	disabled   = {}, -- command: true
	maxClients = nil,

}

--
-- Vote definition API.
--

local Vote   = {}
local VoteMT = {__index = Vote}
this.Vote = Vote

--- Instantiates a vote definition.
-- @param command string
function Vote:new(command)
	
	local s, e = string.find(command, "^[a-zA-Z0-9_]+")

	if s == e then
		error(string.format("%s: Vote:new() command has an invalid format", MOD_NAME))
	end

	local id = string.lower(string.sub(command, s, e))

	if id == "getn" then
		error(string.format("%s: Vote:new() reserved command name", MOD_NAME))
	end

	local arguments = {}

	for a in string.gfind(command, "<([^>]+)>") do
		table.insert(arguments, a)
	end

	local m = setmetatable({
		id         = id,
		command    = command,
		arguments  = arguments,
		vCallbacks = {}
	}, VoteMT)
	
	this.enable(id)
	this.commands[id] = m

	return m
	
end

--- Sets vote description.
-- @param description string
function Vote:description(description)
	this.assertType("description", description, "string")
	self.vDescription = description
	return self
end

--- Makes the vote team specific.
function Vote:team()
	self.vScope = VOTE_SCOPE_TEAM
	return self
end

--- Sets a required percentage to pass.
function Vote:percent(percent)
	this.assertType("percent", percent, "number")
	self.vPercent = percent
	return self
end

--- Attaches a vote callback.
-- @param callback function or string
function Vote:vote(callback)
	this.assertCallback("vote", callback)
	self.vCallbacks.vote = callback
	return self
end

--- Attaches a pass callback.
-- @param callback function or string
function Vote:pass(callback)
	this.assertCallback("pass", callback)
	self.vCallbacks.pass = callback
	return self
end

--- Attaches a fail callback.
-- @param callback function or string
function Vote:fail(callback)
	this.assertCallback("pass", callback)
	self.vCallbacks.fail = callback
	return self
end

--
-- Internal functions.
--

--- The "callvote" command handler.
function this.callvote_f(clientNum)

	local voteLimit = tonumber(et.trap_Cvar_Get("vote_limit"));

	if voteLimit > 0 and et.gentity_get(clientNum, ENT_PERS_VOTE_COUNT) >= voteLimit then
		return 0
	end

	-- Virtual vote is already in progress.
	if this.info.time then
		et.trap_SendServerCommand(clientNum, string.format(FORMAT_CPM, MSG_CALLVOTE_IN_PROGRESS))
		return 1
	end

	-- Game vote is in progress.
	if et.trap_GetConfigstring(CS_VOTE_TIME) ~= "" then
		return 0
	end

	-- Sanitization.
	if not this.sanitize(clientNum) then
		return 1
	end

	-- Spectator?
	if tonumber(et.gentity_get(clientNum, ENT_SESSION_TEAM)) == TEAM_SPECTATOR then
		return 0
	end

	-- TODO: List commands.
	if et.trap_Argc() < 2 then
		return 0
	end

	local command = string.lower(et.trap_Argv(1))

	-- Lua internal function.
	if command == "getn" then
		return 0
	end

	if this.disabled[command] or this.disabled['*'] and this.disabled[command] ~= false then
		et.trap_SendServerCommand(clientNum, string.format(FORMAT_CPM, string.format(MSG_VOTE_DISABLED, command)))
		return 1
	end

	if this.commands[command] ~= nil then
		this.callvote(clientNum, this.commands[command])
		return 1
	end

	return 0

end

--- The "referee" command handler.
function this.referee_f(clientNum)

	-- Game does the authentication.
	if not et.gentity_get(clientNum, ENT_SESSION_REF) then
		return 0
	end

	-- Sanitization.
	if not this.sanitize(clientNum) then
		return 1
	end

	-- TODO: List commands.
	if et.trap_Argc() < 2 then
		return 0
	end

	local command = string.lower(et.trap_Argv(1))

	-- Lua internal function.
	if command == "getn" then
		return 0
	end

	if this.commands[command] ~= nil then
		this.referee(clientNum, this.commands[command])
		return 1
	end

	return 0

end

--- The "vote" command handler.
function this.vote_f(clientNum)

	-- No virtual vote in progress.
	if not this.info.time then
		return 0
	end

	-- Spectator?
	if tonumber(et.gentity_get(clientNum, ENT_SESSION_TEAM)) == TEAM_SPECTATOR then
		et.trap_SendServerCommand(clientNum, string.format(FORMAT_PRINT, MSG_VOTE_SPECTATOR))
		return 1 -- Game would say there's no vote in progress.
	end

	-- Game considers anything but "yes" to be a "no".
	this.vote(clientNum, et.trap_Argv(1) == ARG_VOTE_YES)
	return 1

end

--- Server console "passvote".
function this.passvote_s()

	if not this.callbackExecuting and this.info.time then
		this.pass()
	else
		et.trap_SendConsoleCommand(et.EXEC_APPEND, string.format("%s\n", CMD_PASSVOTE))
	end

	return 1

end

--- Server console "cancelvote".
function this.cancelvote_s()

	if not this.callbackExecuting and this.info.time then
		this.cancel()
	else
		et.trap_SendConsoleCommand(et.EXEC_APPEND, string.format("%s\n", CMD_CANCELVOTE))
	end

	return 1

end

--- Server console "ref".
function this.ref_s()

	if this.callbackExecuting then
		return 0
	end

	-- TODO: List commands.
	if et.trap_Argc() < 2 then
		return 0
	end

	local command = string.lower(et.trap_Argv(1))

	-- Lua internal function.
	if command == "getn" then
		return 0
	end

	if this.commands[command] ~= nil then
		this.referee(nil, this.commands[command])
		return 1
	end

	return 0

end

--- Sanitizes command.
function this.sanitize(clientNum)

	if string.find(et.ConcatArgs(1), "[;\r\n]") then
		et.trap_SendServerCommand(clientNum, string.format(FORMAT_CPM, MSG_CALLVOTE_IN_PROGRESS))
		return false
	end

	return true

end

--- Prints usage.
function this.usage(clientNum, command)
	
	local usage = string.format("\nUsage: ^3\\%s %s^7", et.trap_Argv(0), command.command)

	if command.vDescription ~= nil then
		usage = string.format("%s\n  %s", usage, command.vDescription)
	end

	this.error(clientNum, usage .. "\n")

end

--- Starts the vote.
function this.callvote(clientNum, command)

	-- Zero all the answers.
	for i = 0, this.maxClients - 1 do
		this.info.voted[i] = false
	end

	-- Except the caller.
	this.info.voted[clientNum] = true

	-- Arguments.
	if not this.loadArguments(clientNum, command, this.info) then
		return
	end

	-- The order is critical here.
	this.info.handler    = command
	this.info.caller     = clientNum
	this.info.callerTeam = tonumber(et.gentity_get(clientNum, ENT_SESSION_TEAM))

	-- Now we need to call the vote callback.
	local voteString, errorMessage = this.executeCallback("vote", false, this.info)
	
	if voteString == false then
		
		if type(errorMessage) == "string" then
			et.trap_SendServerCommand(clientNum, string.format(FORMAT_PRINT, errorMessage))
		end
		
		return

	elseif voteString == nil then
		voteString = et.ConcatArgs(1)
	end

	this.info.voteString = voteString
	this.info.yes        = 1
	this.info.no         = 0
	this.info.time       = this.time

	-- This is how we mimic the vote to clients.
	et.trap_SetConfigstring(CS_VOTE_STRING, this.info.voteString)
	et.trap_SetConfigstring(CS_VOTE_YES,    tostring(this.info.yes))
	et.trap_SetConfigstring(CS_VOTE_NO,     tostring(this.info.no))

	if command.scope == VOTE_SCOPE_GLOBAL then
		et.trap_SetConfigstring(CS_VOTE_TIME, tostring(this.info.time))
	else

		for i = 0, this.maxClients - 1 do

			-- Only players in the same team as the caller will see it.
			if et.gentity_get(i, ENT_SESSION_TEAM) == this.info.targetTeam then
				et.trap_SendServerCommand(i, string.format(FORMAT_CS, CS_VOTE_TIME, this.info.time))
			end

		end

	end

	-- Check result in the next frame.
	this.dirty = false

	-- Broadcast.
	local caller = et.gentity_get(clientNum, ENT_PERS_NETNAME)
	et.trap_SendServerCommand(-1, string.format(FORMAT_PRINT, string.format(MSG_CALLED_VOTE_PRINT, caller, this.info.voteString)))
	et.trap_SendServerCommand(-1, string.format(FORMAT_CP,    string.format(MSG_CALLED_VOTE_CP,    caller)))
	et.G_globalSound(SOUND_BELL)

	-- Advance vote count.
	et.gentity_set(clientNum, ENT_PERS_VOTE_COUNT, et.gentity_get(clientNum, ENT_PERS_VOTE_COUNT) + 1)

end

--- Executes referee command.
function this.referee(clientNum, command)

	if not this.loadArguments(clientNum, command, this.ref) then
		return
	end

	this.ref.handler = command

	if clientNum ~= nil then
		this.ref.caller     = clientNum
		this.ref.callerTeam = tonumber(et.gentity_get(clientNum, ENT_SESSION_TEAM))
	else
		this.ref.caller     = nil
		this.ref.callerTeam = nil
	end

	-- This is the same as in a normal vote.
	local voteString, errorMessage = this.executeCallback("vote", false, this.ref)

	if voteString == false then

		if type(errorMessage) == "string" then
			this.error(clientNum, errorMessage)
		end

		return

	end

	if clientNum ~= nil then
		local caller = et.gentity_get(clientNum, ENT_PERS_NETNAME)
		et.trap_SendServerCommand(-1, string.format(FORMAT_CP, string.format(MSG_REFEREE_CHANGE, caller)))
		et.G_globalSound(SOUND_REFEREE)
	end

	-- Call the handler straight away.
	this.executeCallback("pass", true, this.ref)

end

--- Loads arguments.
function this.loadArguments(clientNum, command, context)

	if table.getn(command.arguments) > et.trap_Argc() - 2 or et.trap_Argv(2) == "?" then
		this.usage(clientNum, command)
		return false
	end

	context.arguments = {}
	context.target    = nil

	local ok = true

	table.foreach(command.arguments, function(i, a)

		local value = et.trap_Argv(1 + i)

		if a == "player" then

			value = this.findClient(clientNum, value)

			if value == nil then
				ok = false
			end

			-- First <player> is our target.
			if context.target == nil and value ~= nil then
				context.target     = value
				context.targetTeam = et.gentity_get(value, ENT_SESSION_TEAM)
			end

		end

		table.insert(context.arguments, value)

	end)

	if not ok then
		return false
	end

	return true

end

--- Finds a client.
function this.findClient(clientNum, search)

	local pattern = string.lower(et.Q_CleanStr(search))

	if pattern == "" then
		this.error(clientNum, MSG_INVALID_SLOT_NUMBER)
		return nil
	end

	local num = tonumber(pattern)

	if string.len(pattern) < 3 and num ~= nil then

		if num < 0 or num >= this.maxClients then
			this.error(clientNum, MSG_INVALID_SLOT_NUMBER)
			return nil
		end

		local team = et.gentity_get(num, ENT_SESSION_TEAM)

		if team < TEAM_AXIS or team > TEAM_SPECTATOR then
			this.error(clientNum, string.format(MSG_CLIENT_NOT_ACTIVE, num))
			return nil
		end

		return num

	end

	num = nil

	for i = 0, this.maxClients - 1 do

		if et.gentity_get(i, ENT_INUSE) and string.find(string.lower(et.Q_CleanStr(et.gentity_get(i, ENT_PERS_NETNAME))), pattern, 1, true) then
			
			if num ~= nil then
				this.error(clientNum, string.format(MSG_AMBIGUOUS_CLIENT, search))
				return nil
			end

			num = i

		end

	end

	return num

end

--- Prints an error message to client or server.
function this.error(clientNum, error)

	if clientNum == nil then
		et.G_Print(string.format("%s\n", error))
	else
		et.trap_SendServerCommand(clientNum, string.format(FORMAT_PRINT, error))
	end

end

--- Casts a vote.
function this.vote(clientNum, answer)

	-- When caller votes no, we cancel the poll.
	if clientNum == this.info.caller and not answer then
		this.cancel()
		return
	end

	-- We could allow them for changing their opinion, for fun?
	if this.info.voted[clientNum] then

		-- Pass or cancel on referee double vote.
		if et.gentity_get(clientNum, ENT_SESSION_REF) then

			if answer then
				this.pass()
			else
				this.cancel()
			end

		else
			et.trap_SendServerCommand(clientNum, string.format(FORMAT_PRINT, MSG_VOTE_ALREADY_CAST))
		end

		return

	end

	this.dirty                 = true
	this.info.voted[clientNum] = true

	if answer then
		this.info.yes = this.info.yes + 1
		et.trap_SetConfigstring(CS_VOTE_YES, tostring(this.info.yes))
	else
		this.info.no = this.info.no + 1
		et.trap_SetConfigstring(CS_VOTE_NO, tostring(this.info.no))
	end

end

--- Passes/fails the poll if enough of votes is casted.
function this.checkVote()

	if this.time - this.info.time >= VOTE_TIME then
		this.fail()
		return
	end

	local percents = this.info.handler.vPercent
	local voters   = 0

	if percents == nil then
		percents = tonumber(et.trap_Cvar_Get("vote_percent"))
	end

	if percents < 1 then
		percents = 1
	elseif percents > 99 then
		percents = 99
	end

	for i = 0, this.maxClients - 1 do

		local team = et.gentity_get(i, ENT_SESSION_TEAM)

		if team == TEAM_AXIS or team == TEAM_ALLIES then

			if this.info.handler.vScope == VOTE_SCOPE_GLOBAL or team == this.info.targetTeam then
				voters = voters + 1
			end

		end

	end

	if this.info.yes > percents * voters / 100 then
		this.pass()
	elseif this.info.no and this.info.no >= (100 - percents) * voters / 100 then
		this.fail()
	end

end

--- Passes the vote.
function this.pass()
	this.clear()
	et.trap_SendServerCommand(-1, string.format(FORMAT_CPM, MSG_VOTE_PASSED))
	et.G_LogPrint(string.format(MSG_VOTE_PASSED_LOG, this.info.voteString))
	this.executeCallback("pass", true, this.info)
end

--- Fails the vote.
function this.fail()
	this.clear()
	et.trap_SendServerCommand(-1, string.format(FORMAT_CPM, string.format(MSG_VOTE_FAILED, this.info.voteString)))
	et.G_LogPrint(string.format(MSG_VOTE_FAILED_LOG, this.info.voteString))
	this.executeCallback("fail", true, this.info)
end

--- Caller or referee cancelation.
function this.cancel()
	this.clear()
	et.trap_SendServerCommand(-1, string.format(FORMAT_CPM, MSG_VOTE_CANCELLED))
end

--- Clears the virtual vote.
function this.clear()
	this.info.time = nil
	et.trap_SetConfigstring(CS_VOTE_TIME, "")
end

--- Checks that an option field is a valid callback.
function this.assertCallback(name, callback)

	if type(callback) ~= "function" and type(callback) ~= "string" then
		error(string.format('%s: Vote:%s() expects function or string, %s given', MOD_NAME, name, type(callback)))
	end

end

--- Checks that an option field has an expected type.
function this.assertType(name, value, expected)

	if type(value) ~= expected then
		error(string.format('%s: Vote:%s() expects %s, %s given', MOD_NAME, name, expected, type(value)))
	end

end

--- Executes vote callback (pass, fail and vote).
function this.executeCallback(name, execute, context)

	this.context           = context
	this.callbackExecuting = true

	if type(context.handler.vCallbacks[name]) == "function" then

		-- we really need to set $callbackExecuting back.
		local status, result = pcall(function()
			return context.handler.vCallbacks[name](unpack(context.arguments))
		end)

		this.callbackExecuting = false

		if not status then
			error(result)
		end

		return result

	end

	if type(context.handler.vCallbacks[name]) == "string" then

		local s = string.format("%s", context.handler.vCallbacks[name])

		if context.target ~= nil then
			s = this.replace(s, "<player:%s>", et.gentity_get(context.target, ENT_PERS_NETNAME))
			s = this.replace(s, "<player:%d>", tostring(context.target))
			s = this.replace(s, "<player:%i>", tostring(context.target))
		end

		if execute then
			et.trap_SendConsoleCommand(et.EXEC_NOW, string.format("%s\n", s))
			this.callbackExecuting = false
			return nil
		end

		return s

	end

	this.callbackExecuting = false

	return nil

end

--- Replaces a substring.
function this.replace(s, find, replacement)
	
	local a, b = string.find(s, find, 1, true)

	if a ~= b then
		s = string.sub(s, 1, a - 1) .. replacement .. string.sub(s, b + 1)
	end

	return s

end

--- Enables a command.
function this.enable(command)
	this.mask(command, false)
end

--- Disables a command.
function this.disable(command)
	this.mask(command, true)
end

--- Masks a command, internal or virtual.
function this.mask(command, mask)

	if command == "getn" then
		error(string.format("%s: reserved command name", MOD_NAME))
	end

	this.disabled[command] = mask

end

--- Loads the configuration.
function this.configure()

	this.maxClients = tonumber(et.trap_Cvar_Get("sv_maxclients"))

	local callback, err = loadfile(et.trap_Cvar_Get("fs_homepath") .. "/" .. et.trap_Cvar_Get("fs_game") .. "/" .. CONFIG_NAME)

	if err ~= nil then

		local fd, len = et.trap_FS_FOpenFile(CONFIG_NAME, et.FS_READ)

		-- The file exists, so it doesn't compile.
		if len >= 0 then
			et.trap_FS_FCloseFile(fd)
			error(err)
		end

		et.G_Print(MOD_NAME .. ": " .. CONFIG_NAME .. " not found.\n")
		return

	end

	local status, result = pcall(function()

		-- Initialize isolated scope without $this.
		local scope = {
			V              = this,
			Vote           = this.Vote,
			TEAM_AXIS      = TEAM_AXIS,
			TEAM_ALLIES    = TEAM_ALLIES,
			TEAM_SPECTATOR = TEAM_SPECTATOR,
			FORMAT_CP      = FORMAT_CP,
			FORMAT_CPM     = FORMAT_CPM,
			FORMAT_PRINT   = FORMAT_PRINT,
			FORMAT_CS      = FORMAT_CS,
		}

		table.foreach(_G, function(n, v)

			if n ~= "this" then
				scope[n] = v
			end

		end)

		setfenv(callback, scope)
		callback()

	end)

	if not status then
		error(result)
	end

end

--
-- ET.
--

--- Module registration.
function et_InitGame(levelTime, randomSeed, restart)
	et.RegisterModname(MOD_NAME .. " " .. et.FindSelf())
	this.configure()
end

--- Handles "callvote", "ref" and "vote" commands.
function et_ClientCommand(clientNum, command)

	command = string.lower(command)

	if command == CMD_CALLVOTE then
		return this.callvote_f(clientNum)
	elseif command == CMD_REFEREE then
		return this.referee_f(clientNum)
	elseif command == CMD_VOTE then
		return this.vote_f(clientNum)
	end

	return 0

end

--- Handles "passvote", "cancelvote" and "ref".
function et_ConsoleCommand()

	local command = string.lower(et.trap_Argv(0))

	if command == CMD_REFEREE then
		return this.ref_s()
	elseif command == CMD_PASSVOTE_XX then
		return this.passvote_s()
	elseif command == CMD_CANCELVOTE_XX then
		return this.cancelvote_s()
	end

	return 0

end

--- Handles timing.
function et_RunFrame(levelTime)

	this.time = levelTime

	if this.info.time and (this.time - this.info.time >= VOTE_TIME_MIN and math.mod(this.time, VOTE_TIME_MIN) == 0 or this.dirty) then
		this.dirty = false
		this.checkVote()
	end

end

return this