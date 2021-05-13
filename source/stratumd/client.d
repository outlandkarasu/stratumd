module stratumd.client;

import std.experimental.logger : tracef, errorf;
import std.concurrency :
    thisTid,
    Tid,
    spawnLinked,
    send,
    OwnerTerminated;
import std.exception :
    basicExceptionCtors;

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
    Connect to host.
    */
    void connect(string hostname, ushort port)
    {
        if (connectionTid_ != Tid.init)
        {
            throw new StratumClientException("Already connected");
        }

        connectionTid_ = spawnLinked(&connectionThread, hostname, port);
    }

private:

    struct Connected {}
    struct Authorized { bool result; }
    struct Subscribed { bool result; }
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
    }

    static void connectionThread(string hostname, ushort port)
    {
        openStratumConnection(hostname, port, null);
    }
}

