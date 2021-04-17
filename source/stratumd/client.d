module stratumd.client;

import core.time : msecs;
import std.conv : to;
import std.concurrency :
    send, spawnLinked, thisTid, Tid, receiveTimeout;
import std.variant : Algebraic;
import std.typecons : Nullable, nullable;

import stratumd.connection : openStratumConnection;
import stratumd.methods :
    StratumAuthorize,
    StratumNotify,
    StratumSubscribe,
    StratumErrorResult,
    StratumReconnect;
import stratumd.exception : StratumException;

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
Stratum job request.
*/
struct StratumJob
{
    string jobID;
    string header;
    string extranonce1;
    int extranonce2Size;
    double difficulty;
}

/**
Stratum job response.
*/
struct StratumJobResult
{
    string jobID;
    string ntime;
    string nonce;
    string extranonce2;
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
        difficulty_ = 1.0;
        auto subscribeResult = enforceCallAPI!(StratumSubscribe.Result)(StratumSubscribe(messageID_));
        extranonce1_ = subscribeResult.extranonce1;
        extranonce2Size_ = subscribeResult.extranonce2Size;

        ++messageID_;
        enforceCallAPI!(StratumAuthorize.Result)(StratumAuthorize(messageID_, params.workerName, params.password));

        ++messageID_;
        threadID_.send(StratumSubscribe(messageID_, params.workerName));
        auto notify = enforceReceiveAPI!StratumNotify(messageID_);
        jobs_[notify.jobID] = StratumJob(
            notify.jobID,
            "",
            extranonce1_,
            extranonce2Size_,
            difficulty_);
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
    string extranonce1_;
    int extranonce2Size_;
    double difficulty_;
    StratumJob[string] jobs_;

    Result!T callAPI(T, R)(R request)
    {
        threadID_.send(request);
        return receiveAPI!T(request.id);
    }

    T enforceCallAPI(T, R)(R request)
    {
        threadID_.send(request);
        return enforceReceiveAPI!T(request.id);
    }

    T enforceReceiveAPI(T)(int id)
    {
        auto result = receiveAPI!T(id);
        if (!result.error.isNull)
        {
            throw new StratumException(result.to!string);
        }

        return result.result.get;
    }

    Result!T receiveAPI(T)(int id)
    {
        Result!T result;
        immutable received = receiveTimeout(
            10000.msecs,
            (T r) { result = Result!T(r); },
            (StratumErrorResult r) { result = Result!T(r); });
        if (!received)
        {
            result = Result!T(StratumErrorResult(id, "timeout"));
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

