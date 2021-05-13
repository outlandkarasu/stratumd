module stratumd.connection;

import std.string : format;
import std.algorithm : map, filter;
import std.array : array;
import std.experimental.logger : tracef, warningf, errorf;
import std.exception : assumeWontThrow;
import std.json : JSONValue;

import stratumd.tcp_connection : TCPCloser;
import stratumd.rpc_connection :
    RPCSender,
    RPCHandler,
    openRPCConnection;
import stratumd.job :
    JobNotification,
    JobSubmit;

/**
Stratum request callback.
*/
struct StratumCallback
{
    /**
    On success request.
    */
    void delegate(scope StratumSender sender) onSuccess;

    /**
    On error request.
    */
    void delegate(scope StratumSender sender) onError;

    /**
    On cancel request.
    */
    void delegate() onCancel;
    
private:

    void onSuccessIfExists(scope StratumSender sender)
    {
        if (onSuccess)
        {
            onSuccess(sender);
        }
    }

    void onErrorIfExists(scope StratumSender sender)
    {
        if (onError)
        {
            onError(sender);
        }
    }

    void onCancelIfExists()
    {
        if (onCancel)
        {
            onCancel();
        }
    }
}

/**
Stratum sender.
*/
interface StratumSender : TCPCloser
{
    /**
    Send authorize request.
    */
    void authorize(string username, string password, StratumCallback callback);

    /**
    Send subscribe request.
    */
    void subscribe(string userAgent, StratumCallback callback);

    /**
    Submit job.
    */
    void submit(scope ref const(JobSubmit) jobSubmit, StratumCallback callback);
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

    ~this() nothrow scope
    {
        foreach (callback; callbacks_.byValue)
        {
            try
            {
                callback.onCancelIfExists();
            }
            catch (Throwable e)
            {
                assumeWontThrow(errorf("callback error: %s", e));
            }
        }
    }

    override void onReceiveMessage(string method, scope const(JSONValue)[] params, scope RPCSender sender)
    {
        switch (method)
        {
            case "mining.set_difficulty":
                onReceiveSetDifficulty(params, sender);
                break;
            case "mining.set_extranonce":
                onReceiveSetExtranonce(params, sender);
                break;
            case "mining.notify":
                onReceiveNotify(params, sender);
                break;
            case "client.reconnect":
                onReceiveReconnect(sender);
                break;
            default:
                warningf("unknown method: %s (%s)", method, params);
                break;
        }
    }

    override void onResponseMessage(int id, scope ref const(JSONValue) result, scope RPCSender sender)
    {
        auto callback = id in callbacks_;
        if (!callback)
        {
            return;
        }

        callbacks_.remove(id);

        scope stratumSender = new Sender(sender);
        callback.onSuccessIfExists(stratumSender);
    }

    override void onErrorResponseMessage(int id, scope ref const(JSONValue) error, scope RPCSender sender)
    {
        auto callback = id in callbacks_;
        if (!callback)
        {
            return;
        }

        callbacks_.remove(id);

        scope stratumSender = new Sender(sender);
        callback.onErrorIfExists(stratumSender);
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
    int currentID_;
    StratumCallback[int] callbacks_;

    final class Sender : StratumSender
    {
        this(RPCSender rpcSender) @nogc nothrow pure @safe scope
            in (rpcSender)
        {
            this.rpcSender_ = rpcSender;
        }

        override void authorize(string username, string password, StratumCallback callback)
        {
            sendAuthorize(username, password, callback, rpcSender_);
        }

        override void subscribe(string userAgent, StratumCallback callback)
        {
            sendSubscribe(userAgent, callback, rpcSender_);
        }

        override void submit(scope ref const(JobSubmit) jobSubmit, StratumCallback callback)
        {
            sendSubmit(jobSubmit, callback, rpcSender_);
        }

        override void close()
        {
            rpcSender_.close();
        }

    private:
        RPCSender rpcSender_;
    }

    void sendAuthorize(string username, string password, StratumCallback callback, scope RPCSender sender)
    {
        auto params = [JSONValue(username), JSONValue(password)];
        sendMessage("mining.authorize", params, callback, sender);
    }

    void sendSubscribe(string userAgent, StratumCallback callback, scope RPCSender sender)
    {
        auto params = [JSONValue(userAgent)];
        sendMessage("mining.submit", params, callback, sender);
    }

    void sendSubmit(scope ref const(JobSubmit) jobSubmit, StratumCallback callback, scope RPCSender sender)
    {
        auto params = [
            JSONValue(jobSubmit.workerName),
            JSONValue(jobSubmit.jobID),
            JSONValue(jobSubmit.extranonce2),
            JSONValue(jobSubmit.ntime),
            JSONValue(jobSubmit.nonce),
        ];
        sendMessage("mining.submit", params, callback, sender);
    }

    void sendMessage(string method, scope const(JSONValue)[] params, StratumCallback callback, scope RPCSender sender)
    {
        immutable currentID = currentID_;
        ++currentID_;

        scope(failure) callback.onCancelIfExists();
        sender.send(currentID, method, params);
        callbacks_[currentID] = callback;
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
        handler_.onSetExtranonce(
            params[0].str, cast(int) params[1].integer);
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

