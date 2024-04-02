type ChangedPackage = {
	Callback : (NewValue : any) -> (),
	Path : {any}
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileService = require(script.ProfileService)
local DefaultData = require(script.DefaultData)

script.cbor.Parent = ReplicatedStorage
local cbor = require(ReplicatedStorage.cbor)

local ProfileStore = ProfileService.GetProfileStore({
	Name = "Alpha",
	Scope = "0.0.1"
}, DefaultData)

--- @class Server
--- @server

local Server = {}
Server._Profiles = {}

--- Attempts to load the specified Player's Profile
--- @within Server
--- @param Player Player -- The specified Player

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
	
	Server._Profiles[Player] = Profile
	
	Server._ReplicateDataChange(Player, Profile.Data, {})
end

--- Attempts to unload the specified Player's Profile
--- @within Server
--- @param Player Player -- The specified Player

function Server.RemoveProfile(Player : Player)
	if Server._Profiles[Player] then
		Server._Profiles[Player]:Release()
	end
end

--[=[
	Attempts to get the specified Player's Profile. Will only yield if the specified Player's Profile doesn't already exist

	@within Server
	@yields
	@param Player Player -- The specified Player
	@return any -- The specified Player's Profile
]=]

function Server.Get(Player : Player) : any
	while not Server._Profiles[Player] do
		assert(Player:IsDescendantOf(Players), "Player left while retrieving data")
		
		task.wait()
	end
	
	return Server._Profiles[Player]
end

--- Gets the specified Player's Profile without yielding
--- @within Server
--- @param Player Player -- The specified Player
--- @return any? -- The specified Player's Profile (if it exists)

function Server.Peek(Player : Player) : any?
	return Server._Profiles[Player]
end

--- Use this function to update the specified Player's Profile data
--- @within Server
--- @param Player Player -- The specified Player
--- @param Callback (Profile : any) -> () -- Update the specified Player's data inside of this function

function Server.Update(Player : Player, Callback : (Profile : any) -> ())
	local Profile = Server.Get(Player)

    if Profile._IsUpdating then
        Callback(Profile)

        return
    end

    Profile._IsUpdating = true

	local PreviousDataVersion = Server._DeepCopy(Profile.Data)
	
	Callback(Profile)
	
	local Added, Removed = Server._GetDiff(PreviousDataVersion, Profile.Data)
	
	Server._FireChangedCallbacks(Player, Added, Removed)
	Server._ReplicateDataChange(Player, Added, Removed)

    Profile._IsUpdating = false
end

--[=[
	Listens to whenever the specified path's value is changed. The callback will fire upon declaration if the path's value is not nil

	```lua
	--- Listens to whenever Profile.Data.Currencies.Money for qut100's Profile is changed

	Server.ListenToValueChanged(game.Players.qut100, {"Currencies", "Money"}, function(Money : number)
		Gui.PathToTextLabel.Text = tostring(Money)
	end)
	```

	@within Server
	@param Player Player -- Target Player
	@param Path {any} -- The path of the value that is being listened to
	@param Callback (NewValue : any) -> () -- This function is called whenever the specified path's value is changed
	@return () -> () -- Disconnect function
]=]

function Server.ListenToValueChanged(Player : Player, Path : {any}, Callback : (NewValue : any) -> ()) : () -> ()
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
	:::caution
	### This should not be called manually, and instead should be edited by the developer to properly replicate data to the Player.

	```lua
	-- Example Code:
	function Server._ReplicateDataChange(Player : Player, Added : {any}, Removed : {any})
		local Remotes = require(game.ReplicatedStorage.Remotes)
		Remotes.Fire("ReplicateData", Player, Added, Removed)
	end
	```
	:::

	Replicates added and removed data to the specified Player

	@within Server
	@param Player Player -- The specified Player
	@param Added {any} -- Any data that was added
	@param Removed {any} -- Any data that was removed
]=]

function Server._ReplicateDataChange(Player : Player, Added : {any}, Removed : {any})
	Added = cbor.encode(Added)
	Removed = cbor.encode(Removed)

	
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

function Server._GetDataFromPath(Root, Path)
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