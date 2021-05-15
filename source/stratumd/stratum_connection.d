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
import stratumd.job :
    Job,
    JobNotification,
    JobResult,
    JobSubmit,
    JobBuilder;

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
    Submit and complete job if alived.
    */
    Nullable!MessageID submitAndCompleteJob(scope ref const(JobResult) jobResult);

    /**
    complete job.
    */
    void completeJob(string jobID);
}

/**
Stratum handler.
*/
interface StratumHandler
{
    /**
    Callback on job notify.
    */
    void onNotify(scope ref const(Job) job, scope StratumSender sender);

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
            updateExtranonce(result[1].str, cast(uint) result[2].integer);
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

    StratumHandler handler_;
    bool[string] jobs_;
    JobNotification currentJob_;
    JobBuilder jobBuilder_;

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

        override Nullable!MessageID submitAndCompleteJob(scope ref const(JobResult) jobResult)
        {
            if (!(jobResult.jobID in jobs_))
            {
                warningf("jobID: %s is expired.", jobResult.jobID);
                return typeof(return).init;
            }

            auto params = resultToParams(jobResult);
            tracef("submit: %s", params);
            auto result = nullable(sendMessage(StratumMethod.submit, params, rpcSender_));

            completeJob(jobResult.jobID);
            return result;
        }

        override void completeJob(string jobID)
        {
            if (currentJob_.jobID == jobID)
            {
                ++jobBuilder_.extranonce2;
                notifyCurrentJob(this);
            }
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
        auto notification = parseNotification(params);
        if (notification.cleanJobs)
        {
            jobs_.clear();
        }
        jobs_[notification.jobID] = true;

        if (currentJob_.jobID != notification.jobID)
        {
            jobBuilder_.extranonce2 = 0;
        }
        currentJob_ = notification;

        scope stratumSender = new Sender(sender);
        notifyCurrentJob(stratumSender);
    }

    void onReceiveSetExtranonce(scope const(JSONValue)[] params, scope RPCSender sender)
    {
        updateExtranonce(params[0].str, params[1].get!uint);
    }

    void onReceiveSetDifficulty(scope const(JSONValue)[] params, scope RPCSender sender)
    {
        jobBuilder_.difficulty = params[0].get!double;
        tracef("set difficulty: %s", jobBuilder_.difficulty);
    }

    void onReceiveReconnect(scope RPCSender sender)
    {
        tracef("reconnect from host");
        sender.close();
    }

    void updateExtranonce(string extranonce1, uint extranonce2Size)
    {
        tracef("update extra nonce: %s, %s", extranonce1, extranonce2Size);
        jobBuilder_.extranonce1 = extranonce1;
        jobBuilder_.extranonce2 = 0;
        jobBuilder_.extranonce2Size = extranonce2Size;
    }

    void notifyCurrentJob(scope StratumSender sender)
    {
        immutable job = jobBuilder_.build(currentJob_);
        tracef("notify current job: %s", job);
        handler_.onNotify(job, sender);
    }

    static JobNotification parseNotification(scope const(JSONValue)[] params)
    {
        return JobNotification(
            params[0].str,
            params[1].str,
            params[2].str,
            params[3].str,
            params[4].array.map!((e) => e.str).array,
            params[5].str,
            params[6].str,
            params[7].str,
            params[8].boolean);
    }

    static const(JSONValue)[] resultToParams(return scope ref const(JobResult) result)
    {
        auto jobSubmit = JobSubmit.fromResult(result);
        return [
            JSONValue(jobSubmit.workerName),
            JSONValue(jobSubmit.jobID),
            JSONValue(jobSubmit.extranonce2),
            JSONValue(jobSubmit.ntime),
            JSONValue(jobSubmit.nonce),
        ];
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

