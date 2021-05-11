module stratumd.rpc_connection;

import std.algorithm : countUntil, copy;
import std.array : Appender;
import std.experimental.logger : tracef;
import std.json : JSONValue, parseJSON;
import std.string : representation;

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

/**
Open JSON-RPC connection.

Params:
    hostname = hostname.
    port = host port number.
*/
void openRPCConnection(string hostname, ushort port, scope RPCHandler handler)
    in (handler)
{
}

private:

final class RPCStack : TCPHandler
{
    this(RPCHandler rpcHandler) @nogc nothrow pure @safe scope
        in (rpcHandler)
    {
        this.rpcHandler_ = rpcHandler;
    }

    override void onSendable(scope TCPSender sender)
    {
        if (sendBuffer_[].length > 0)
        {
            const rest = sender.send(sendBuffer_[]);
            sendBuffer_.truncateBuffer(rest.length);
        }
    }

    override void onReceive(scope const(void)[] data, scope TCPCloser closer)
    {
        auto receiveBytes = cast(const(ubyte)[]) data;
        receiveBuffer_ ~= receiveBytes;
        scope slice = receiveBuffer_[];
        immutable foundSeparator = slice.countUntil(JSON_SEPARATOR);
        if (foundSeparator < 0)
        {
            return;
        }

        scope(exit) receiveBuffer_.truncateBuffer(slice.length - (foundSeparator + 1));

        scope line = cast(const(char)[]) receiveBuffer_[][0 .. foundSeparator];
        tracef("receive: %s", line);

        auto json = parseJSON(line);
        scope sender = new Sender(closer);
        auto id = json["id"];
        if (id.isNull)
        {
            rpcHandler_.onReceiveMessage(json["method"].str, json["params"].array, sender);
            return;
        }

        auto error = json["error"];
        if (error.isNull)
        {
            rpcHandler_.onResponseMessage(cast(int) id.integer, json["result"], sender);
        }
        else
        {
            rpcHandler_.onErrorResponseMessage(cast(int) id.integer, error, sender);
        }
    }

    override void onError(scope string errorText, scope TCPCloser closer)
    {
        tracef("error: %s", errorText);

        scope sender = new Sender(closer);
        rpcHandler_.onError(errorText, sender);
    }

    override void onIdle(scope TCPCloser closer)
    {
        scope sender = new Sender(closer);
        rpcHandler_.onIdle(sender);
    }

private:
    enum JSON_SEPARATOR = '\n';

    Appender!(ubyte[]) sendBuffer_;
    Appender!(ubyte[]) receiveBuffer_;
    RPCHandler rpcHandler_;

    final class Sender : RPCSender 
    {
        this(TCPCloser closer) @nogc nothrow pure @safe scope
            in (closer)
        {
            this.closer_ = closer;
        }
    
        override void send(int id, string method, scope const(JSONValue)[] params)
        {
            sendMessage(id, method, params);
        }

        override void close()
        {
            closer_.close();
        }

    private:
        TCPCloser closer_;
    }

    void sendMessage(int id, string method, scope const(JSONValue)[] params)
    {
        JSONValue json;
        json["method"] = method;
        json["id"] = id;
        json["params"].array = [];
        foreach (ref e; params)
        {
            json["params"] ~= e;
        }

        scope jsonString = json.toString;
        tracef("send: %s", jsonString);

        sendBuffer_ ~= jsonString.representation;
        sendBuffer_ ~= '\n';
    }
}

void truncateBuffer(E)(ref Appender!E buffer, size_t restSize)
{
    copy(buffer[][$ - restSize .. $], buffer[][0 .. restSize]);
    buffer.shrinkTo(restSize);
}

///
unittest
{
    import std.array : appender;
    auto buffer = appender!(char[])();
    buffer ~= "test";

    buffer.truncateBuffer(3);
    assert(buffer[] == "est");

    buffer.truncateBuffer(2);
    assert(buffer[] == "st");

    buffer.truncateBuffer(0);
    assert(buffer[] == "");
}

