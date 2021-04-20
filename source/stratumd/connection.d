module stratumd.connection;

import core.time : msecs;
import std.algorithm : countUntil, copy, map;
import std.array : Appender, appender, array;
import std.json : JSONValue, parseJSON, toJSON;
import std.meta : AliasSeq;
import std.string : representation;
import std.experimental.logger : errorf, warningf, infof, info, tracef, trace;
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
    StratumSubmit,
    StratumSuggestDifficulty,
    StratumReconnect,
    StratumNotify,
    StratumSetExtranonce,
    StratumSetDifficulty,
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
    try
    {
        scope handler = new StratumHandler(parent);
        openTCPConnection(hostname, port, handler);
    }
    catch (Throwable e)
    {
        errorf("connection error: %s", e);
    }

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
        tracef("send: %s", message);
        this.sendBuffer_ ~= message.toJSON.representation;
        this.sendBuffer_ ~= '\n';
        this.resultHandlers_[message.id]
            = (ref const(JSONValue) json) => onReceiveMessage(T.Result.parse(json));
    }

    /**
    Send method without result.

    Params:
        T = parameter type.
        id = method call ID.
        method = method name.
        args = method arguments;
    */
    void sendMethodWithoutResult(T)(auto ref const(T) message)
    {
        auto sendBytes = message.toJSON.representation;
        tracef("send: %s", cast(const(char)[]) sendBytes);
        this.sendBuffer_ ~= sendBytes;
        this.sendBuffer_ ~= '\n';
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
            tracef("receive: %s", line);
            parseJSONMessage(line, closer);
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
                (StratumSubmit m) => sendMethod(m),
                (StratumSuggestDifficulty m) => sendMethodWithoutResult(m),
                (StratumReconnect m) {
                    info("close from client");
                    closeConnection(m, closer);
                });
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

    void parseJSONMessage(scope const(char)[] data, scope TCPCloser closer)
    {
        const json = parseJSON(data);
        auto method = "method" in json;
        if (method)
        {
            onReceiveMethod(method.str, json, closer);
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

    private void onReceiveMethod(scope string method, const(JSONValue) json, scope TCPCloser closer)
    {
        infof("onReceiveMethod: %s", method);

        auto params = json["params"].array;
        if (method == StratumReconnect.method)
        {
            info("reconnect from host");
            closeConnection(StratumReconnect.parse(params), closer);
            return;
        }

        static foreach (M; AliasSeq!(StratumNotify, StratumSetDifficulty, StratumSetExtranonce))
        {
            if (method == M.method)
            {
                onReceiveMessage(M.parse(params));
                return;
            }
        }
    }

    private void onJSONResultError(const(JSONValue) json)
    {
        errorf("result error: %s", json);
        onReceiveMessage(StratumErrorResult.parse(json));
    }

    private void onReceiveMessage(T)(T message)
    {
        concurrency.send(threadID_, message);
    }

    private void closeConnection()(auto scope ref const(StratumReconnect) message, scope TCPCloser closer)
    {
        infof("close connection: %s", message);
        closer.close();
        onReceiveMessage(StratumReconnect.Result(message.id));
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

