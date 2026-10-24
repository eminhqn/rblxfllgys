--!strict
-- Minimal synchronous signal used for module-to-module events on one machine.
-- (Use RemoteEvents to talk across the network.)

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local listeners: { [Connection]: (T...) -> () } = {}

	local function connect(_self: Signal<T...>, callback: (T...) -> ()): Connection
		local connection: Connection
		connection = {
			Connected = true,
			Disconnect = function(_conn: Connection)
				connection.Connected = false
				listeners[connection] = nil
			end,
		}
		listeners[connection] = callback
		return connection
	end

	local function fire(_self: Signal<T...>, ...: T...)
		-- Copy first so listeners may connect/disconnect while we iterate.
		local snapshot: { (T...) -> () } = {}
		for _, callback in listeners do
			table.insert(snapshot, callback)
		end
		for _, callback in snapshot do
			callback(...)
		end
	end

	local function disconnectAll(_self: Signal<T...>)
		for connection in listeners do
			connection.Connected = false
		end
		table.clear(listeners)
	end

	return {
		Connect = connect,
		Fire = fire,
		DisconnectAll = disconnectAll,
	}
end

return Signal
