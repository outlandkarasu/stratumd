module stratumd.rpc_connection;

import std.json : JSONValue;

import stratumd.tcp_connection :
    TCPHandler,
    TCPSender,
    TCPCloser,
    openTCPConnection;

/**
JSON-RPC sender.
*/
interface RPCSender : TCPCloser
{
    /**
    Send JSON method.
    */
    void send(int id, string method, scope const(JSONValue)[] params);
}

/**
JSON-RPC handler.
*/
interface RPCHandler
{
    /**
    Callback on message.
    */
    void onReceiveMessage(string method, scope const(JSONValue)[] params, scope RPCSender sender);

    /**
    Callback on response.
    */
    void onResponseMessage(int id, scope ref const(JSONValue) result, scope RPCSender sender);

    /**
    Callback on error response.
    */
    void onErrorResponseMessage(int id, scope ref const(JSONValue) error, scope RPCSender sender);

    /**
    Callback on error.
    */
    void onError(scope string errorText, scope RPCSender sender);

    /**
    Callback on idle time.
    */
    void onIdle(scope RPCSender sender);
}

