type ChangedPackage = {
	Callback : (NewValue : any) -> (),
	Path : {any}
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local cbor = require(ReplicatedStorage:WaitForChild("PLAYER_DATA_SERIALIZER"))

local DataChangedRemote = ReplicatedStorage:WaitForChild("PLAYER_DATA_CHANGED")

--- @class Client
--- @client

local Client = {}
Client._Data = {}
Client._ChangedPackages = {}
Client._LastDataDeepCopy = nil

--[=[
	Gets the ``LocalPlayer``'s current ``Profile`` Data

	:::caution
	Will yeild if the ``LocalPlayer``'s Data hasn't loaded
	:::

	:::info
	``Client.Get()`` is the same as ``Server.Get(LocalPlayer).Profile.Data``
	:::

	@within Client
	@return {any}
]=]

function Client.Get() : {any}
	while not Client._LastDataDeepCopy do
		task.wait()
	end

	return Client._LastDataDeepCopy
end

--[=[
	Listens to whenever the specified ``Path``'s value is changed

	:::info
	``Callback`` will fire upon declaration if the ``Path``'s value is not ``nil``
	:::

	```lua
	--- Example Usage
	local Disconnect = Client.ListenToValueChanged({"Currencies", "Money"}, function(Money : number)
		Gui.PathToTextLabel.Text = tostring(Money)
	end)

	task.delay(5, Disconnect)
	```

	@within Client
	@param Path {string} -- {"Index", "NestedIndex"} -> Table.Index.NestedIndex
	@param Callback (NewValue : any) -> ()
	@return () -> () -- Disconnect function
]=]

function Client.ListenToValueChanged(Path : {string}, Callback : (NewValue : any) -> ()) : () -> ()
	local Package = {
		Callback = Callback,
		Path = Path
	}
	
	local InitialPeek = Client._GetDataFromPath(Client.Get(), Path)
	
	if InitialPeek ~= nil then
		task.spawn(Callback, InitialPeek)
	end
	
	Client._ChangedPackages[Package] = true
	
	return function()
		Client._ChangedPackages[Package] = nil
	end
end

--[=[
	@within Client
	@private
]=]

function Client._ListenToDataChanges()
	DataChangedRemote.OnClientEvent:Connect(function(Added, Removed)
		Added, Removed = cbor.decode(Added), cbor.decode(Removed)

		Client._MergeDiff(Client._Data, Added, Removed)

		Client._LastDataDeepCopy = Client._DeepCopy(Client._Data)

		Client._FireChangedCallbacks(Added, Removed)
	end)
end

--- @within Client
--- @private

function Client._DeepCopy(Table: {any}) : {any}
	local Clone = table.clone(Table)

	for Index, Value in Clone do
		if typeof(Value) == "table" then
			Clone[Index] = Client._DeepCopy(Value)
		end
	end

	return Clone
end

--- @within Client
--- @private

function Client._GetDataFromPath(Root : {[any] : any}, Path : {string})
	for _, Index : any in Path do
		Root = Root[Index]
		
		if Root == nil then
			return nil
		end
	end
	
	return Root
end

--- @within Client
--- @private

function Client._FireChangedCallbacks(Added : {any}, Removed : {any})
	for Package : ChangedPackage in Client._ChangedPackages do
		local AddedPath = Client._GetDataFromPath(Added, Package.Path)
		local RemovedPath = Client._GetDataFromPath(Removed, Package.Path)
		
		if AddedPath or RemovedPath then
			task.spawn(Package.Callback, Client._GetDataFromPath(Client.Get(), Package.Path))
		end
	end
end

--- @within Client
--- @private

function Client._MergeDiff(ParentTable : {any}, Added : {any}, Removed : {any})
	for Index, Value in Added do
		if typeof(Value) == "table" and typeof(ParentTable[Index]) == "table" then
			Client._MergeDiff(ParentTable[Index], Value, {})
		else
			ParentTable[Index] = Value
		end
	end
	for Index, Value in Removed do
		if typeof(Value) == "table" and typeof(ParentTable[Index]) == "table" then
			Client._MergeDiff(ParentTable[Index], {}, Value)
		else
			ParentTable[Index] = nil
		end
	end
end

Client._ListenToDataChanges()

return Client