module stratumd.client;

import core.time : seconds, msecs, Duration;
import std.experimental.logger : tracef, errorf;
import std.concurrency :
    thisTid,
    Tid,
    spawnLinked,
    send,
    OwnerTerminated,
    receiveTimeout;
import std.exception : basicExceptionCtors;
import std.typecons : Nullable, nullable;

import stratumd.rpc_connection : MessageID;
import stratumd.stratum_connection : 
    openStratumConnection,
    StratumSender,
    StratumHandler,
    StratumMethod;
import stratumd.job : Job, JobResult;

/**
Stratum related error.
*/
final class StratumClientException : Exception
{
    mixin basicExceptionCtors;
}

/**
Stratum client.
*/
final class StratumClient
{
    /**
    Close if connected.
    */
    ~this()
    {
        close();
    }

    /**
    Connect to host.
    */
    void connect(string hostname, ushort port)
    {
        if (connectionTid_ != Tid.init)
        {
            throw new StratumClientException("Already connected");
        }

        connectionTid_ = spawnLinked(&connectionThread, hostname, port, thisTid);
        if (!receiveTimeout(responseTimeout, (Connected r) {}))
        {
            close();
            throw new StratumClientException("connection timed out");
        }
    }

    /**
    Authorize worker.
    */
    void authorize(string username, string password)
    {
        connectionTid_.send(Authorizing(username, password));
        waitResponse!Authorized();
    }

    /**
    Subscribe jobs.
    */
    void subscribe(string userAgent)
    {
        connectionTid_.send(Subscribing(userAgent));
        waitResponse!Subscribed();
    }

    /**
    Wait new job.
    */
    Nullable!Job waitNewJob()
    {
        typeof(return) job;
        receiveTimeout(responseTimeout, (JobNotify notify) { job = notify.job; });
        return job;
    }

    /**
    Submit job result.
    */
    void submit(JobResult jobResult)
    {
        connectionTid_.send(Submitting(jobResult));
        waitResponse!Submitted();
    }

    /**
    Close connection.
    */
    void close()
    {
        if (connectionTid_ != Tid.init)
        {
            connectionTid_.send(Closing());
            connectionTid_ = Tid.init;
        }
    }

private:

    static immutable Duration requestWaitTimeout = 10.msecs;
    static immutable Duration responseTimeout = 60.seconds;

    struct Closing {}
    struct Connected {}

    struct Authorizing
    {
        string username;
        string password;
    }

    struct Authorized { bool result; }

    struct Subscribing { string userAgent; }
    struct Subscribed { bool result; }

    struct Submitting
    {
        JobResult jobResult;
    }

    struct Submitted { bool result; }

    struct JobNotify { Job job; }

    Tid connectionTid_;

    static class Handler : StratumHandler
    {
        this(Tid parentTid) @nogc nothrow pure @safe scope
        {
            this.parentTid_ = parentTid;
        }

        override void onNotify(scope ref const(Job) job, scope StratumSender sender)
        {
            parentTid_.send(JobNotify(job));
        }

        override void onError(scope string errorText, scope StratumSender sender)
        {
            errorf("TCP error: %s", errorText);
            sender.close();
        }

        override void onIdle(scope StratumSender sender)
        {
            if (!connected_)
            {
                connected_ = true;
                sendAndCheck(Connected(), sender);
            }

            while (waitRequest(sender)) {}
        }

        override void onResponse(MessageID id, StratumMethod method, scope StratumSender sender)
        {
            tracef("success: %s %s", id, method);
            translateResponse(method, true, sender);
        }

        override void onErrorResponse(MessageID id, StratumMethod method, scope StratumSender sender)
        {
            errorf("error: %s %s", id, method);
            translateResponse(method, false, sender);
        }

    private:
        Tid parentTid_;
        bool connected_;

        void translateResponse(StratumMethod method, bool result, scope StratumSender sender) scope
        {
            switch (method)
            {
                case StratumMethod.authorize:
                    sendAndCheck(Authorized(result), sender);
                    break;
                case StratumMethod.submit:
                    sendAndCheck(Submitted(result), sender);
                    break;
                case StratumMethod.subscribe:
                    sendAndCheck(Subscribed(result), sender);
                    break;
                default:
                    break;
            }
        }

        void sendAndCheck(M)(M message, scope StratumSender sender) scope
        {
            try
            {
                parentTid_.send(message);
            }
            catch (OwnerTerminated e)
            {
                tracef("Owner terminated. closing...");
                sender.close();
            }
        }

        bool waitRequest(scope StratumSender sender)
        {
            return receiveTimeout(
                requestWaitTimeout,
                (Authorizing request)
                {
                    sender.authorize(request.username, request.password);
                },
                (Submitting request)
                {
                    sender.submit(request.jobResult);
                },
                (Subscribing request)
                {
                    sender.subscribe(request.userAgent);
                });
        }
    }

    static void connectionThread(string hostname, ushort port, Tid parentTid)
    {
        scope handler = new Handler(parentTid);
        openStratumConnection(hostname, port, handler);
    }

    void waitResponse(R)()
    {
        bool result = false;
        if (!receiveTimeout(responseTimeout, (R r) { result = r.result; }))
        {
            throw new StratumClientException("response timed out");
        }

        if (!result)
        {
            throw new StratumClientException("request error");
        }
    }
}

