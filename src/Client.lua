type ChangedPackage = {
	Callback : (NewValue : any) -> (),
	Path : {any}
}

--- @class Client
--- @client

local Client = {}
Client._Data = {}
Client._ChangedPackages = {}

--- Gets the LocalPlayer's current Profile data
--- @within Client
--- @return {any} -- The LocalPlayer's Profile data

function Client.Get() : {any}
	return Client._Data
end

--[=[
	Listens to whenever the specified path's value is changed. The callback will fire upon declaration if the path's value is not nil

	```lua
	--- Listens to whenever Profile.Data.Currencies.Money is changed

	Client.ListenToValueChanged({"Currencies", "Money"}, function(Money : number)
		Gui.PathToTextLabel.Text = tostring(Money)
	end)
	```

	@within Client
	@param Path {any} -- The path of the value that is being listened to
	@param Callback (NewValue : any) -> () -- This function is called whenever the specified path's value is changed
	@return () -> () -- Disconnect function
]=]

function Client.ListenToValueChanged(Path : {any}, Callback : (NewValue : any) -> ()) : () -> ()
	local Package = {
		Callback = Callback,
		Path = Path
	}
	
	local InitialPeek = Client._Data
	
	for _, Index : any in Path do
		InitialPeek = InitialPeek[Index]
		
		if InitialPeek == nil then
			break
		end
	end
	
	if InitialPeek ~= nil then
		task.spawn(Callback, InitialPeek)
	end
	
	Client._ChangedPackages[Package] = true
	
	return function()
		Client._ChangedPackages[Package] = nil
	end
end

--[=[
	:::caution
	### This should not be called manually, and instead should be edited by the developer to properly listen for data changes from the server.

	```lua
	-- Example:
	function Client._ListenToDataChanges()
		local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Remotes"))
		Remotes.OnEvent("ReplicateData", function(Added, Removed)
			Client._MergeDiff(Client._Data, Added, Removed)
		end)
	end
	```
	:::

	Starts listening to any data changes that the server sends

	@within Client
]=]

function Client._ListenToDataChanges()
	
end

--- @within Client
--- @private

function Client._FireChangedCallbacks(Added : {any}, Removed : {any})
	for Package : ChangedPackage in Client._ChangedPackages do
		local Path = Added
		
		for _, Index : any in Package.Path do
			Path = Path[Index]
			
			if Path == nil then
				break
			end
		end
		
		if Path == nil then
			Path = Removed
			
			for _, Index : any in Package.Path do
				Path = Path[Index]

				if Path == nil then
					break
				end
			end
			
			if Path == true then
				task.spawn(Package.Callback, Path)
			end
		else
			task.spawn(Package.Callback, Path)
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
	
	Client._FireChangedCallbacks(Added, Removed)
end

Client._ListenToDataChanges()

return Client