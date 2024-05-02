type ChangedPackage = {
	Callback : (NewValue : any) -> (),
	Path : {any}
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileService = require(script.ProfileService)
local DefaultData = require(script.DefaultData)

local cborModule = script.cbor
cborModule.Name = "PLAYER_DATA_SERIALIZER"
cborModule.Parent = ReplicatedStorage

local cbor = require(cborModule)

local PlayerDataChangedRemote = Instance.new("RemoteEvent")
PlayerDataChangedRemote.Name = "PLAYER_DATA_CHANGED"
PlayerDataChangedRemote.Parent = ReplicatedStorage

local ProfileStore = ProfileService.GetProfileStore({
	Name = "Alpha",
	Scope = "0.0.1"
}, DefaultData)

--- @class Server
--- @server

local Server = {}
Server._Profiles = {}

--- Attempts to load the specified ``Player``'s ``Profile``
--- @within Server

function Server.CreateProfile(Player : Player)
	if Server._Profiles[Player] then
		return
	end
	
	local Profile = ProfileStore:LoadProfileAsync(tostring(Player.UserId))

	if not Profile then
		Player:Kick("Data couldn't be loaded, try rejoining!")
		
		return
	end

	Profile:Reconcile()
	Profile:AddUserId(Player.UserId)
	Profile:ListenToRelease(function()
		Server._Profiles[Player] = nil
		
		Player:Kick("Data loaded on another server!")
	end)

	if not Player:IsDescendantOf(Players) then
		Profile:Release()
		
		return
	end

    Profile._IsUpdating = false
	Profile._ChangedPackages = {}
	Profile._UpdateQueue = {}
	
	Server._Profiles[Player] = Profile
	
	Server._ReplicateDataChange(Player, Profile.Data, {})
end

--- Attempts to unload the specified ``Player``'s ``Profile``
--- @within Server

function Server.RemoveProfile(Player : Player)
	if Server._Profiles[Player] then
		Server._Profiles[Player]:Release()
	end
end

--[=[
	Attempts to get the specified ``Player``'s ``Profile``

	:::info
	Will only yield if the specified ``Player``'s ``Profile`` doesn't already exist
	:::

	:::caution
	Will error if the specified ``Player`` leaves during invocation
	:::

	@within Server
	@yields
]=]

function Server.Get(Player : Player) : any
	while not Server._Profiles[Player] do
		assert(Player:IsDescendantOf(Players), "Player left while retrieving data")
		
		task.wait()
	end
	
	return Server._Profiles[Player]
end

--- Gets the specified ``Player``'s ``Profile`` without yielding
--- @within Server

function Server.Peek(Player : Player) : any?
	return Server._Profiles[Player]
end

--[=[
	Update's the specified ``Player``'s ``Profile`` Data

	:::warning
	This should be the **only** way you update a ``Player``'s ``Profile``
	:::

	:::info
	If a ``Player``'s ``Profile`` tries to be updated while already being updated (eg. asynchronous collisions or recursively called), any subsequent updates will be added to a queue and fired synchronously in order. The first update will yield until the queue has been fully flushed
	:::

	```lua
	-- Example Usage
	Server.Update(game.Players.qut100, function(Profile)
		Profile.Data.Coins += 10

		if Profile.Data.Coins > 50 then
			Profile.Data.Coins -= 50
			Profile.Data.Gems += 1
		end
	end)
	```

	@within Server
	@yields
]=]

function Server.Update(Player : Player, Callback : (Profile : any) -> ())
	local Profile = Server.Get(Player)

	if Profile._IsUpdating then
		print(`added to queue {#Profile._UpdateQueue}`)

		table.insert(Profile._UpdateQueue, Callback)

		return
	end

	print("started updating")

    Profile._IsUpdating = true

	local PreviousDataVersion = Server._DeepCopy(Profile.Data)
	
	Callback(Profile)

	local Added, Removed = Server._GetDiff(PreviousDataVersion, Profile.Data)

	Server._ReplicateDataChange(Player, Added, Removed)
	Server._FireChangedCallbacks(Player, Added, Removed)

	while #Profile._UpdateQueue > 0 do
		PreviousDataVersion = Server._DeepCopy(Profile.Data)

		Profile._UpdateQueue[1](Profile)

		table.remove(Profile._UpdateQueue, 1)

		Added, Removed = Server._GetDiff(PreviousDataVersion, Profile.Data)

		Server._ReplicateDataChange(Player, Added, Removed)
		Server._FireChangedCallbacks(Player, Added, Removed)

		print("iterated")
	end

    Profile._IsUpdating = false

	print("stopped updating")
end

--[=[
	Listens to whenever the specified ``Path``'s value is changed

	:::info
	``Callback`` will fire upon declaration if the ``Path``'s value is not ``nil``
	:::

	```lua
	--- Example Usage
	local Player = game.Players.qut100
	local Disconnect = Server.ListenToValueChanged(Player, {"Currencies", "Money"}, function(Money : number)
		if Money > 50 then
			Server.Update(Player, function(Profile)
				Profile.Data.Gems += 1
			end)
		end
	end)

	task.delay(5, Disconnect)
	```

	@within Server
	@param Player Player
	@param Path {string} -- {"Index", "NestedIndex"} -> Table.Index.NestedIndex
	@param Callback (NewValue : any) -> ()
	@return () -> () -- Disconnect function
]=]

function Server.ListenToValueChanged(Player : Player, Path : {string}, Callback : (NewValue : any) -> ()) : () -> ()
	local Profile = Server.Get(Player)

	local Package = {
		Callback = Callback,
		Path = Path
	}
	
	local InitialPeek = Server._GetDataFromPath(Profile.Data, Path)
	
	if InitialPeek ~= nil then
		task.spawn(Callback, InitialPeek)
	end
	
	Profile._ChangedPackages[Package] = true
	
	return function()
		Profile._ChangedPackages[Package] = nil
	end
end

--[=[
@within Server
@private
]=]

function Server._ReplicateDataChange(Player : Player, Added : {any}, Removed : {any})
	if not (next(Added) or next(Removed)) then
		return
	end

	Added = cbor.encode(Added)
	Removed = cbor.encode(Removed)

	PlayerDataChangedRemote:FireClient(Player, Added, Removed)
end

--- @within Server
--- @private

function Server._DeepCopy(Table: {any}) : {any}
	local Clone = table.clone(Table)

	for Index, Value in Clone do
		if typeof(Value) == "table" then
			Clone[Index] = Server._DeepCopy(Value)
		end
	end

	return Clone
end

--- @within Server
--- @private

function Server._GetDataFromPath(Root : {[any] : any}, Path : {string})
	for _, Index : any in Path do
		Root = Root[Index]
		
		if Root == nil then
			return nil
		end
	end
	
	return Root
end

--- @within Server
--- @private

function Server._FireChangedCallbacks(Player : Player, Added : {any}, Removed : {any})
	local Profile = Server.Get(Player)

	for Package : ChangedPackage in Profile._ChangedPackages do
		local AddedPath = Server._GetDataFromPath(Added, Package.Path)
		local RemovedPath = Server._GetDataFromPath(Removed, Package.Path)
		
		if AddedPath or RemovedPath then
			task.spawn(Package.Callback, Server._GetDataFromPath(Profile.Data, Package.Path))
		end
	end
end

--- @within Server
--- @private

function Server._GetDiff(Previous : {any}, Current : {any}) : ({any}, {any})
	local Added = {}
	local Removed = {}

	for Index, Value in Previous do
		if typeof(Value) == "table" and typeof(Current[Index]) == "table" then
			local NestedAddedDiff, NestedRemovedDiff = Server._GetDiff(Value, Current[Index])

			if next(NestedAddedDiff) then
				Added[Index] = NestedAddedDiff
			end
			if next(NestedRemovedDiff) then
				Removed[Index] = NestedRemovedDiff
			end
		elseif Current[Index] ~= Value then
			if Current[Index] == nil then
				Removed[Index] = true
			else
				Added[Index] = Current[Index]
			end
		end
	end

	for Index, Value in Current do
		if Previous[Index] == nil then
			Added[Index] = Value
		end
	end

	return Added, Removed
end

for _, Player in Players:GetPlayers() do
	task.spawn(Server.CreateProfile, Player)
end

Players.PlayerAdded:Connect(Server.CreateProfile)
Players.PlayerRemoving:Connect(Server.RemoveProfile)

return Server