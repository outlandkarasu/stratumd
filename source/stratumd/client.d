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
    StratumAuthorize,
    StratumNotify,
    StratumSetDifficulty,
    StratumSetExtranonce,
    StratumSubscribe,
    StratumSubscribeResult,
    StratumSubmit,
    StratumReconnect;

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

    concurrency.send(connectionThreadID, MethodCallID(1), StratumSubscribe("test"));
    concurrency.receive((MethodCallID id, StratumSubscribeResult result) {
        import std.stdio : writeln;
        writeln(id, result);
    });
}

private:

void startConnection(string hostname, ushort port, concurrency.Tid parent)
{
    scope handler = new StratumClient(parent);
    openTCPConnection(hostname, port, handler);
}

enum StratumMethod
{
    miningAuthorize,
    miningSubscribe,
    miningSubmit,
    miningNotify,
    miningSetDifficulty,
    miningSetExtranonce,
    clientReconnect,
}

string methodToString(StratumMethod method) @nogc nothrow pure @safe
{
    final switch (method)
    {
    case StratumMethod.miningAuthorize:
        return "mining.authorize";
    case StratumMethod.miningSubscribe:
        return "mining.subscribe";
    case StratumMethod.miningSubmit:
        return "mining.submit";
    case StratumMethod.miningNotify:
        return "mining.notify";
    case StratumMethod.miningSetDifficulty:
        return "mining.set_difficulty";
    case StratumMethod.miningSetExtranonce:
        return "mining.set_extranonce";
    case StratumMethod.clientReconnect:
        return "client.reconnect";
    }
}

Nullable!StratumMethod stringToMethod(scope string method)
{
    switch (method)
    {
    case "mining.authorize":
        return StratumMethod.miningAuthorize.nullable;
    case "mining.subscribe":
        return StratumMethod.miningSubscribe.nullable;
    case "mining.submit":
        return StratumMethod.miningSubmit.nullable;
    case "mining.notify":
        return StratumMethod.miningNotify.nullable;
    case "mining.set_difficulty":
        return StratumMethod.miningSetDifficulty.nullable;
    case "mining.set_extranonce":
        return StratumMethod.miningSetExtranonce.nullable;
    case "client.reconnect":
        return StratumMethod.clientReconnect.nullable;
    default:
        return typeof(return).init;
    }
}

alias MethodCallID = Typedef!(int, int.init, "MethodCallID");

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
    void sendMethod(T...)(int id, StratumMethod method, T args)
    {
        auto call = JSONValue(["id": id]);
        call["method"] = method.methodToString;
        infof("send: %s", call);
        this.sendBuffer_ ~= call.toJSON().representation;
        this.sendBuffer_ ~= '\n';
        this.callingMethods_[id] = method;
    }

    override void onSendable(scope TCPSender sender)
    {
        if (sendBuffer_[].length > 0)
        {
            const(void)[] data = sendBuffer_[];
            infof("send: %s", cast(const(char)[]) sendBuffer_[]);
            sender.send(data);
            sendBuffer_.truncateBuffer(data.length);
            infof("sent: %s", cast(const(char)[]) sendBuffer_[]);
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
                    &sendAuthorize,
                    &sendSubscribe,
                    &sendSubmit);
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

    Appender!(ubyte[]) sendBuffer_;
    Appender!(ubyte[]) receiveBuffer_;
    StratumMethod[int] callingMethods_;
    concurrency.Tid threadID_;
    bool terminated_;

    void parseJSONMessage(scope const(char)[] data)
    {
        JSONValue json = parseJSON(data);
        auto method = "method" in json;
        if (method)
        {
            onJSONMethod(method.str, json["params"].array);
            return;
        }

        auto result = "result" in json;
        if (result)
        {
            immutable id = cast(int) json["id"].integer;
            if ("error" in json)
            {
                // handle error.
                onJSONResultError(id, data);
                return;
            }
            else
            {
                onJSONResult(id, *result);
                return;
            }
        }

        // unknown.
        warningf("unrecognized message: %s", data);
    }

    private void onJSONMethod(scope string method, const(JSONValue)[] params)
    {
        immutable stratumMethod = method.stringToMethod;
        if (stratumMethod.isNull)
        {
            warningf("unknown method: %s", method);
            return;
        }

        switch(stratumMethod.get)
        {
        case StratumMethod.miningNotify:
            receiveNotify(params);
            break;
        case StratumMethod.miningSetDifficulty:
            break;
        case StratumMethod.miningSetExtranonce:
            break;
        case StratumMethod.clientReconnect:
            break;
        default:
            warningf("unexpected method: %s", stratumMethod.get);
            break;
        }
    }

    private void onJSONResultError(int id, scope const(char)[] errorResponse)
    {
        errorf("result error[%d]: %s", id, errorResponse);
    }

    private void onJSONResult(int id, JSONValue result)
    {
        auto method = id in callingMethods_;
        if (method)
        {
            callingMethods_.remove(id);
        }
        else
        {
            warningf("unknown message: [%d] %s", id, result);
        }
    }

    private void sendAuthorize(MethodCallID id, StratumAuthorize authorize)
    {
        sendMethod(cast(int) id, StratumMethod.miningAuthorize, authorize.username, authorize.password);
    }

    private void sendSubscribe(MethodCallID id, StratumSubscribe subscribe)
    {
        sendMethod(cast(int) id, StratumMethod.miningSubscribe, subscribe.userAgent);
    }

    private void sendSubmit(MethodCallID id, StratumSubmit submit)
    {
        sendMethod(
            cast(int) id,
            StratumMethod.miningSubmit,
            submit.workerName,
            submit.jobID,
            submit.extraNonce2,
            submit.ntime,
            submit.nonce);
    }

    private void receiveNotify(const(JSONValue)[] params)
    {
        auto notify = StratumNotify(
            params[0].str,
            params[1].str,
            params[2].str,
            params[3].str,
            cast(shared string[]) params[4].array.map!((e) => e.str).array,
            params[5].str,
            params[6].str,
            params[7].str,
            params[8].boolean);
        concurrency.send(threadID_, notify);
    }

    private void receiveSetDifficulty(JSONValue[] params)
    {
        auto setDifficulty = StratumSetDifficulty(cast(int) params[0].integer);
        concurrency.send(threadID_, setDifficulty);
    }

    private void receiveSetExtranonce(JSONValue[] params)
    {
        auto setExtranonce = StratumSetExtranonce(
            params[0].str, cast(int) params[1].integer);
        concurrency.send(threadID_, setExtranonce);
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
