module stratumd.client;

import core.time : msecs;
import std.algorithm : countUntil, copy, map;
import std.array : Appender, appender, array;
import std.json : JSONValue, parseJSON, toJSON;
import std.string : representation;
import std.experimental.logger : errorf, warningf, infof;
import std.typecons : Typedef, Nullable, nullable;

import concurrency = std.concurrency;

import stratumd.tcp_connection :
    TCPHandler,
    TCPSender,
    TCPCloser,
    openTCPConnection;
import stratumd.methods :
    StratumAuthorize;

/**
Open stratum connection.

Params:
    hostname = target host name.
    port = target port no.
    handler = TCP event handler.
*/
void openStratumConnection(scope const(char)[] hostname, ushort port)
{
    auto connectionThreadID = concurrency.spawnLinked(
        &startConnection, hostname.idup, port, concurrency.thisTid);
}

private:

void startConnection(string hostname, ushort port, concurrency.Tid parent)
{
    scope handler = new StratumClient(parent);
    openTCPConnection(hostname, port, handler);
}

final class StratumClient : TCPHandler
{
    this(concurrency.Tid threadID) @nogc nothrow pure @safe scope
    {
        this.threadID_ = threadID;
    }

    /**
    Send method.

    Params:
        T = parameter type.
        id = method call ID.
        method = method name.
        args = method arguments;
    */
    void sendMethod(T)(auto ref const(T) message)
    {
        infof("send: %s", message);
        this.sendBuffer_ ~= message.toJSON.representation;
        this.sendBuffer_ ~= '\n';
        this.resultHandlers_[message.id]
            = (ref const(JSONValue) json) => onResult(T.Result.parse(json));
    }

    override void onSendable(scope TCPSender sender)
    {
        if (sendBuffer_[].length > 0)
        {
            const(void)[] data = sendBuffer_[];
            sender.send(data);
            sendBuffer_.truncateBuffer(data.length);
        }
    }

    override void onReceive(scope const(void)[] data, scope TCPCloser closer)
    {
        auto receiveBytes = cast(const(ubyte)[]) data;
        receiveBuffer_ ~= receiveBytes;
        scope slice = receiveBuffer_[];
        immutable foundSeparator = slice.countUntil(JSON_SEPARATOR);
        if (foundSeparator >= 0)
        {
            scope(exit) receiveBuffer_.truncateBuffer(foundSeparator);

            scope line = cast(const(char)[]) receiveBuffer_[][0 .. foundSeparator];
            infof("receive: %s", line);
            parseJSONMessage(line);
        }
    }

    override void onError(scope string errorText, scope TCPCloser closer)
    {
        errorf("TCP connection error: %s", errorText);
    }

    override void onIdle(scope TCPCloser closer)
    {
        if (!terminated_)
        {
            try
            {
                concurrency.receiveTimeout(
                    1.msecs,
                    (StratumAuthorize m) => sendMethod(m));
            }
            catch (concurrency.OwnerTerminated e)
            {
                infof("owner terminated: %s", e);
                terminated_ = true;
                closer.close();
            }
        }
    }

private:
    enum JSON_SEPARATOR = '\n';

    alias ResultHandler = void delegate(ref const(JSONValue) json);

    Appender!(ubyte[]) sendBuffer_;
    Appender!(ubyte[]) receiveBuffer_;
    ResultHandler[int] resultHandlers_;
    concurrency.Tid threadID_;
    bool terminated_;

    void parseJSONMessage(scope const(char)[] data)
    {
        const json = parseJSON(data);
        auto method = "method" in json;
        if (method)
        {
            return;
        }

        auto result = "result" in json;
        if (result)
        {
            immutable id = cast(int) json["id"].integer;
            auto handler = id in resultHandlers_;
            resultHandlers_.remove(id);

            if ("error" in json)
            {
                // handle error.
                onJSONResultError(id, data);
                return;
            }
            else if(handler)
            {
                (*handler)(json);
            }
        }

        // unknown.
        warningf("unrecognized message: %s", data);
    }

    private void onJSONResultError(int id, scope const(char)[] errorResponse)
    {
        errorf("result error[%d]: %s", id, errorResponse);
    }

    private void onResult(T)(auto ref const(T) result)
    {
        concurrency.send(threadID_, result);
    }
}

void truncateBuffer(E)(ref Appender!E buffer, size_t truncateSize)
{
    copy(buffer[][truncateSize .. $], buffer[][0 .. $ - truncateSize]);
    buffer.shrinkTo(buffer[].length - truncateSize);
}

///
unittest
{
    import std.array : appender;
    auto buffer = appender!(char[])();
    buffer ~= "test";
    buffer.truncateBuffer(2);
    assert(buffer[] == "st", buffer[]);
}
