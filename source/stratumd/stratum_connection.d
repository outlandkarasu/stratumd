module stratumd.stratum_connection;

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

Params:
    JobBuilder = job builder.
*/
interface StratumSender(JobBuilder) : TCPCloser
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
    Submit and complete job if alived.
    */
    Nullable!MessageID submitAndCompleteJob(scope ref const(JobBuilder.JobResult) jobResult);

    /**
    complete job.
    */
    void completeJob(string jobID);
}

/**
Stratum handler.

Params:
    JobBuilder = job builder.
*/
interface StratumHandler(JobBuilder)
{
    alias Sender = StratumSender!JobBuilder;

    /**
    Callback on job notify.
    */
    void onNotify(scope ref const(JobBuilder.Job) job, scope Sender sender);

    /**
    Callback on error.
    */
    void onError(scope string errorText, scope Sender sender);

    /**
    Callback on idle time.
    */
    void onIdle(scope Sender sender);

    /**
    Callback on response.
    */
    void onResponse(MessageID id, StratumMethod method, scope Sender sender);

    /**
    Callback on error response.
    */
    void onErrorResponse(MessageID id, StratumMethod method, scope Sender sender);
}

/**
Open Stratum connection.
*/
void openStratumConnection(JobBuilder)(string hostname, ushort port, scope StratumHandler!JobBuilder handler)
{
    scope stratumStack = new StratumStack!JobBuilder(handler);
    openRPCConnection(hostname, port, stratumStack);
}

private:

final class StratumStack(JobBuilder) : RPCHandler
{
    this(StratumHandler!JobBuilder handler) @nogc nothrow pure @safe scope
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
                onReceiveSetDifficulty(params);
                break;
            case StratumMethod.setExtranonce:
                onReceiveSetExtranonce(params);
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

    override void onResponseMessage(MessageID id, string method, scope ref const(JSONValue) result, scope RPCSender sender)
    {
        auto stratumMethod = method.toStratumMethod;
        if (stratumMethod.isNull)
        {
            warningf("unknown method: %s", method);
            return;
        }

        if (stratumMethod == StratumMethod.subscribe)
        {
            onReceiveSubscribeResponse(result);
        }

        scope stratumSender = new Sender(sender);
        handler_.onResponse(id, stratumMethod.get, stratumSender);
    }

    override void onErrorResponseMessage(MessageID id, string method, scope ref const(JSONValue) error, scope RPCSender sender)
    {
        auto stratumMethod = method.toStratumMethod;
        if (stratumMethod.isNull)
        {
            warningf("unknown method: %s", method);
            return;
        }

        scope stratumSender = new Sender(sender);
        handler_.onErrorResponse(id, stratumMethod.get, stratumSender);
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

    StratumHandler!JobBuilder handler_;
    bool[string] jobs_;
    JobBuilder jobBuilder_;

    final class Sender : StratumSender!JobBuilder
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

        override Nullable!MessageID submitAndCompleteJob(scope ref const(JobBuilder.JobResult) jobResult)
        {
            if (!(jobResult.jobID in jobs_))
            {
                warningf("jobID: %s is expired.", jobResult.jobID);
                return typeof(return).init;
            }

            auto params = JobBuilder.resultToJSONParams(jobResult);
            tracef("submit: %s", params);
            auto result = nullable(sendMessage(StratumMethod.submit, params, rpcSender_));

            completeJob(jobResult.jobID);
            return result;
        }

        override void completeJob(string jobID)
        {
            jobBuilder_.completeJob(jobID);
            notifyCurrentJob(this);
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
        return sender.send(method.toString, params);
    }

    void onReceiveNotify(scope const(JSONValue)[] params, scope RPCSender sender)
    {
        jobBuilder_.receiveNotify(params);

        if (jobBuilder_.cleanJobs)
        {
            jobs_.clear();
        }
        jobs_[jobBuilder_.jobID] = true;

        scope stratumSender = new Sender(sender);
        notifyCurrentJob(stratumSender);
    }

    void onReceiveReconnect(scope RPCSender sender)
    {
        tracef("reconnect from host");
        sender.close();
    }

    void onReceiveSubscribeResponse(scope ref const(JSONValue) result)
    {
        jobBuilder_.receiveSubscribeResponse(result);
    }

    void onReceiveSetExtranonce(scope const(JSONValue)[] params)
    {
        jobBuilder_.receiveSetExtranonce(params);
    }

    void onReceiveSetDifficulty(scope const(JSONValue)[] params)
    {
        jobBuilder_.receiveSetDifficulty(params);
    }

    void notifyCurrentJob(scope StratumSender!JobBuilder sender)
    {
        immutable job = jobBuilder_.build();
        tracef("notify current job: %s", job);
        handler_.onNotify(job, sender);
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

