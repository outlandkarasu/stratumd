module stratumd.connection;

import std.string : format;
import std.algorithm : map, filter;
import std.array : array;
import std.experimental.logger : tracef, warningf, errorf;
import std.exception : assumeWontThrow;
import std.json : JSONValue;
import std.typecons : Nullable, nullable;
import std.traits : EnumMembers;

import stratumd.tcp_connection : TCPCloser;
import stratumd.rpc_connection :
    RPCSender,
    RPCHandler,
    openRPCConnection,
    MessageID;
import stratumd.job :
    JobNotification,
    JobSubmit;

/**
Stratum method.
*/
enum StratumMethod
{
    setDifficulty,
    setExtranonce,
    notify,
    reconnect,
    subscribe,
    submit,
    authorize,
}

/**
Stratum sender.
*/
interface StratumSender : TCPCloser
{
    /**
    Send authorize request.
    */
    MessageID authorize(string username, string password);

    /**
    Send subscribe request.
    */
    MessageID subscribe(string userAgent);

    /**
    Submit job.
    */
    MessageID submit(scope ref const(JobSubmit) jobSubmit);
}

/**
Stratum handler.
*/
interface StratumHandler
{
    /**
    Callback on set difficulty.
    */
    void onSetDifficulty(double difficulty);

    /**
    Callback on extra nonce.
    */
    void onSetExtranonce(string extranonce1, int extranonce2Size);

    /**
    Callback on notify.
    */
    void onNotify(scope ref const(JobNotification) jobNotification);

    /**
    Callback on error.
    */
    void onError(scope string errorText, scope StratumSender sender);

    /**
    Callback on idle time.
    */
    void onIdle(scope StratumSender sender);

    /**
    Callback on response.
    */
    void onResponse(MessageID id, StratumMethod method, scope StratumSender sender);

    /**
    Callback on error response.
    */
    void onErrorResponse(MessageID id, StratumMethod method, scope StratumSender sender);
}

/**
Open Stratum connection.
*/
void openStratumConnection(string hostname, ushort port, scope StratumHandler handler)
{
    scope stratumStack = new StratumStack(handler);
    openRPCConnection(hostname, port, stratumStack);
}

private:

final class StratumStack : RPCHandler
{
    this(StratumHandler handler) @nogc nothrow pure @safe scope
        in (handler)
    {
        this.handler_ = handler;
    }

    override void onReceiveMessage(string method, scope const(JSONValue)[] params, scope RPCSender sender)
    {
        immutable stratumMethod = method.toStratumMethod;
        if (stratumMethod.isNull)
        {
            warningf("unknown method: %s (%s)", method, params);
            return;
        }

        switch (stratumMethod.get)
        {
            case StratumMethod.setDifficulty:
                onReceiveSetDifficulty(params, sender);
                break;
            case StratumMethod.setExtranonce:
                onReceiveSetExtranonce(params, sender);
                break;
            case StratumMethod.notify:
                onReceiveNotify(params, sender);
                break;
            case StratumMethod.reconnect:
                onReceiveReconnect(sender);
                break;
            default:
                warningf("unknown method: %s (%s)", method, params);
                break;
        }
    }

    override void onResponseMessage(MessageID id, scope ref const(JSONValue) result, scope RPCSender sender)
    {
        auto method = id in sentMethods_;
        if (!method)
        {
            return;
        }

        sentMethods_.remove(id);

        scope stratumSender = new Sender(sender);
        handler_.onResponse(id, *method, stratumSender);
    }

    override void onErrorResponseMessage(MessageID id, scope ref const(JSONValue) error, scope RPCSender sender)
    {
        auto method = id in sentMethods_;
        if (!method)
        {
            return;
        }

        sentMethods_.remove(id);

        scope stratumSender = new Sender(sender);
        handler_.onErrorResponse(id, *method, stratumSender);
    }

    override void onError(scope string errorText, scope RPCSender sender)
    {
        scope stratumSender = new Sender(sender);
        handler_.onError(errorText, stratumSender);
    }

    override void onIdle(scope RPCSender sender)
    {
        scope stratumSender = new Sender(sender);
        handler_.onIdle(stratumSender);
    }

private:
    StratumHandler handler_;
    MessageID currentID_;
    StratumMethod[MessageID] sentMethods_;

    final class Sender : StratumSender
    {
        this(RPCSender rpcSender) @nogc nothrow pure @safe scope
            in (rpcSender)
        {
            this.rpcSender_ = rpcSender;
        }

        override MessageID authorize(string username, string password)
        {
            auto params = [JSONValue(username), JSONValue(password)];
            return sendMessage(StratumMethod.authorize, params, rpcSender_);
        }

        override MessageID subscribe(string userAgent)
        {
            auto params = [JSONValue(userAgent)];
            return sendMessage(StratumMethod.subscribe, params, rpcSender_);
        }

        override MessageID submit(scope ref const(JobSubmit) jobSubmit)
        {
            auto params = [
                JSONValue(jobSubmit.workerName),
                JSONValue(jobSubmit.jobID),
                JSONValue(jobSubmit.extranonce2),
                JSONValue(jobSubmit.ntime),
                JSONValue(jobSubmit.nonce),
            ];
            return sendMessage(StratumMethod.submit, params, rpcSender_);
        }

        override void close()
        {
            rpcSender_.close();
        }

    private:
        RPCSender rpcSender_;
    }

    MessageID sendMessage(StratumMethod method, scope const(JSONValue)[] params, scope RPCSender sender)
    {
        immutable currentID = currentID_;
        ++currentID_;

        sender.send(currentID, method.toString, params);
        sentMethods_[currentID] = method;
        return currentID;
    }

    void onReceiveNotify(scope const(JSONValue)[] params, scope RPCSender sender)
    {
        auto notification = JobNotification(
            params[0].str,
            params[1].str,
            params[2].str,
            params[3].str,
            params[4].array.map!((e) => e.str).array,
            params[5].str,
            params[6].str,
            params[7].str,
            params[8].boolean);
        handler_.onNotify(notification);
    }

    void onReceiveSetExtranonce(scope const(JSONValue)[] params, scope RPCSender sender)
    {
        handler_.onSetExtranonce(params[0].str, cast(int) params[1].integer);
    }

    void onReceiveSetDifficulty(scope const(JSONValue)[] params, scope RPCSender sender)
    {
        handler_.onSetDifficulty(params[0].floating);
    }

    void onReceiveReconnect(scope RPCSender sender)
    {
        tracef("reconnect from host");
        sender.close();
    }
}

string toString(StratumMethod method)
{
    final switch (method)
    {
        case StratumMethod.setDifficulty:
            return "mining.set_difficulty";
        case StratumMethod.setExtranonce:
            return "mining.set_extranonce";
        case StratumMethod.notify:
            return "mining.notify";
        case StratumMethod.reconnect:
            return "client.reconnect";
        case StratumMethod.subscribe:
            return "mining.subscribe";
        case StratumMethod.submit:
            return "mining.submit";
        case StratumMethod.authorize:
            return "mining.authorize";
    }
}

Nullable!StratumMethod toStratumMethod(string method)
{
    static foreach (e; EnumMembers!StratumMethod)
    {
        if (method == e.toString)
        {
            return nullable(e);
        }
    }

    return typeof(return).init;
}

