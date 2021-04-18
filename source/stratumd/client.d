module stratumd.client;

import core.time : msecs, Duration;
import std.format : format;
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
    StratumSubmit,
    StratumErrorResult,
    StratumReconnect,
    StratumSetDifficulty,
    StratumSetExtranonce;
import stratumd.exception : StratumException;
import stratumd.job :
    StratumJob,
    StratumJobBuilder,
    StratumJobResult;

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
        workerName_ = params.workerName;
        threadID_ = spawnLinked(&openStratumConnection, params.hostname, params.port, thisTid);

        // subscribe job.
        messageID_ = 1;
        auto subscribeResult = enforceCallAPI!(StratumSubscribe.Result)(StratumSubscribe(messageID_, params.workerName));
        jobBuilder_ = StratumJobBuilder(
            subscribeResult.extranonce1,
            subscribeResult.extranonce2Size);

        // authorize.
        ++messageID_;
        enforceCallAPI!(StratumAuthorize.Result)(StratumAuthorize(messageID_, params.workerName, params.password));

        // receive first job.
        currentJob_ = currentJob_.init;
        jobs_.clear();
        while(jobs_.length == 0)
        {
            receiveServerMethod(10000.msecs);
        }
    }

    /**
    Receive server method.
    */
    void doReceiveServerMethod()
    {
        while(receiveServerMethod(1.msecs)) {}
    }

    /**
    Build current job.

    Params:
        extranonce2 = extranonce2 value.
    Returns:
        current job.
    */
    StratumJob buildCurrentJob(uint extranonce2)
    {
        return jobBuilder_.build(currentJob_, extranonce2);
    }

    void submit()(auto scope ref const(StratumJobResult) jobResult)
    {
        auto job = jobResult.jobID in jobs_;
        if (!job)
        {
            return;
        }

        ++messageID_;
        callAPI!(StratumSubmit.Result)(StratumSubmit(
            messageID_,
            workerName_,
            jobResult.jobID,
            format("%0*x", job.extranonce2Size * 2, jobResult.extranonce2),
            format("%08x", jobResult.ntime),
            format("%08x", jobResult.nonce)));
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
    string workerName_;
    Tid threadID_;
    int messageID_;
    StratumJobBuilder jobBuilder_;
    StratumNotify currentJob_;
    JobInfo[string] jobs_;

    struct JobInfo
    {
        string extranonce1;
        uint extranonce2Size;
    }

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
        while (result.empty)
        {
            immutable received = receiveTimeout(
                10000.msecs,
                (T r) { result = Result!T(r); },
                (StratumErrorResult r) { result = Result!T(r); },
                &onNotify,
                &onSetDifficulty,
                &onSetExtranonce);
            if (!received)
            {
                result = Result!T(StratumErrorResult(id, "timeout"));
            }
        }

        return result;
    }

    bool receiveServerMethod(Duration timeout)
    {
        return receiveTimeout(
            timeout,
            &onNotify,
            &onSetDifficulty,
            &onSetExtranonce);
    }

    void onNotify(StratumNotify notify)
    {
        if (notify.cleanJobs)
        {
            jobs_.clear();
        }

        currentJob_ = notify;
        jobs_[notify.jobID] = JobInfo(
            jobBuilder_.extranonce1, jobBuilder_.extranonce2Size);
    }

    void onSetDifficulty(StratumSetDifficulty setDifficulty)
    {
        jobBuilder_.difficulty = setDifficulty.difficulty;
    }

    void onSetExtranonce(StratumSetExtranonce setExtranonce)
    {
        jobBuilder_.extranonce1 = setExtranonce.extranonce1;
        jobBuilder_.extranonce2Size = setExtranonce.extranonce2Size;
    }
}

private:

struct Result(T)
{
    this()(T result) scope
    {
        this.value_ = typeof(this.value_)(result);
    }

    this()(StratumErrorResult error) scope
    {
        this.value_ = typeof(this.value_)(error);
    }

    @property
    {
        Nullable!T result()
        {
            auto p = value_.peek!T;
            return p ? (*p).nullable : typeof(return).init;
        }

        Nullable!StratumErrorResult error()
        {
            auto p = value_.peek!StratumErrorResult;
            return p ? (*p).nullable : typeof(return).init;
        }

        bool empty() const pure nothrow
        {
            return !value_.hasValue;
        }
    }

private:
    Algebraic!(T, StratumErrorResult) value_;
}

///
unittest
{
    import stratumd.methods : StratumAuthorize;
    auto result = Result!(StratumAuthorize.Result)(StratumAuthorize.Result(1, true));
    assert(!result.empty);
    assert(!result.result.isNull);
    assert(result.error.isNull);
    assert(result.result.get() == StratumAuthorize.Result(1, true));

    auto error = Result!(StratumAuthorize.Result)(StratumErrorResult(1, "[]"));
    assert(!error.empty);
    assert(error.result.isNull);
    assert(!error.error.isNull);
    assert(error.error.get() == StratumErrorResult(1, "[]"));

    auto empty = Result!(StratumAuthorize.Result)();
    assert(empty.empty);
    assert(empty.result.isNull);
    assert(empty.error.isNull);

}

