module stratumd.client;

import core.time : msecs;
import std.concurrency :
    send, spawnLinked, thisTid, Tid, receiveTimeout;
import std.variant : Algebraic;
import std.typecons : Nullable, nullable;

import stratumd.connection : openStratumConnection;
import stratumd.methods :
    StratumAuthorize,
    StratumSubscribe,
    StratumErrorResult,
    StratumReconnect;

/**
Stratum connection parameters.
*/
struct StratumClientParams
{
    string hostname;
    ushort port;
    string workerName;
    string password;
}

/**
Stratum client.
*/
final class StratumClient
{
    /**
    Connect stratum host.

    Params:
        params = connection parameters.
    */
    void connect()(auto ref const(StratumClientParams) params) scope
    {
        threadID_ = spawnLinked(&openStratumConnection, params.hostname, params.port, thisTid);

        messageID_ = 1;
        callAPI!(StratumSubscribe.Result)(StratumSubscribe(messageID_));
        ++messageID_;
        callAPI!(StratumAuthorize.Result)(StratumAuthorize(messageID_, params.workerName, params.password));
    }

    /**
    Close connection.
    */
    void close()
    {
        ++messageID_;
        callAPI!(StratumReconnect.Result)(StratumReconnect(messageID_));
        threadID_ = Tid.init;
    }

private:
    Tid threadID_;
    int messageID_;

    Result!T callAPI(T, R)(R request)
    {
        Result!T result;
        threadID_.send(request);
        immutable received = receiveTimeout(
            10000.msecs,
            (T r) { result = Result!T(r); },
            (StratumErrorResult r) { result = Result!T(r); });
        if (!received)
        {
            result = Result!T(StratumErrorResult(request.id, "timeout"));
        }

        return result;
    }
}

private:

struct Result(T)
{
    this()(auto ref const(T) result) scope
    {
        this.value_ = typeof(this.value_)(result);
    }

    this()(auto ref const(StratumErrorResult) error) scope
    {
        this.value_ = typeof(this.value_)(error);
    }

    @property const
    {
        Nullable!(const(T)) result()
        {
            auto p = value_.peek!(const(T));
            return p ? (*p).nullable : typeof(return).init;
        }

        Nullable!(const(StratumErrorResult)) error()
        {
            auto p = value_.peek!(const(StratumErrorResult));
            return p ? (*p).nullable : typeof(return).init;
        }
    }

private:
    Algebraic!(const(T), const(StratumErrorResult)) value_;
}

///
unittest
{
    import stratumd.methods : StratumAuthorize;
    immutable result = Result!(StratumAuthorize.Result)(StratumAuthorize.Result(1, true));
    assert(!result.result.isNull);
    assert(result.error.isNull);
    assert(result.result.get() == StratumAuthorize.Result(1, true));

    immutable error = Result!(StratumAuthorize.Result)(StratumErrorResult(1, "[]"));
    assert(error.result.isNull);
    assert(!error.error.isNull);
    assert(error.error.get() == StratumErrorResult(1, "[]"));
}

