module stratumd.connection;

import core.time : msecs;
import std.algorithm : countUntil, copy, map;
import std.array : Appender, appender, array;
import std.json : JSONValue, parseJSON, toJSON;
import std.string : representation;
import std.experimental.logger : errorf, warningf, infof, info;
import std.typecons : Typedef, Nullable, nullable;

import concurrency = std.concurrency;

import stratumd.tcp_connection :
    TCPHandler,
    TCPSender,
    TCPCloser,
    openTCPConnection;
import stratumd.methods :
    StratumSubscribe,
    StratumAuthorize,
    StratumReconnect,
    StratumErrorResult;

/**
Open stratum connection.

Params:
    hostname = stratum hostname.
    port = stratum host port number.
    parent = parent thread ID.
*/
void openStratumConnection(string hostname, ushort port, concurrency.Tid parent)
{
    scope handler = new StratumHandler(parent);
    openTCPConnection(hostname, port, handler);
    info("exit stratum connection.");
}

private:

final class StratumHandler : TCPHandler
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
            scope(exit) receiveBuffer_.truncateBuffer(slice.length - (foundSeparator + 1));

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
        if (terminated_)
        {
            return;
        }

        try
        {
            concurrency.receiveTimeout(
                1.msecs,
                (StratumAuthorize m) => sendMethod(m),
                (StratumSubscribe m) => sendMethod(m),
                (StratumReconnect m) => closeConnection(m, closer));
        }
        catch (concurrency.OwnerTerminated e)
        {
            infof("owner terminated: %s", e.message);
            terminated_ = true;
            closer.close();
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

            auto error = "error" in json;
            if (error && !error.isNull)
            {
                onJSONResultError(json);
                return;
            }

            if(handler)
            {
                (*handler)(json);
                return;
            }
        }

        // unknown.
        warningf("unrecognized message: %s", data);
    }

    private void onJSONResultError(const(JSONValue) json)
    {
        errorf("result error: %s", json);
        onResult(StratumErrorResult.parse(json));
    }

    private void onResult(T)(T result)
    {
        infof("onResult: %s", result);
        concurrency.send(threadID_, result);
    }

    private void closeConnection(scope ref const(StratumReconnect) message, scope TCPCloser closer)
    {
        infof("close connection: %s", message);
        closer.close();
        onResult(StratumReconnect.Result(message.id));
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