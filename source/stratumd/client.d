module stratumd.client;

import core.time : msecs, Duration;
import core.bitop : bswap;
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
    StratumSuggestDifficulty,
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
    Initialize by parameters.

    Params:
        params = client parameters.
    */
    this()(auto ref const(StratumClientParams) params) @nogc nothrow pure @safe scope
    {
        this.params_ = params;
    }

    /**
    Connect stratum host.
    */
    void connect() scope
    {
        if (threadID_ != Tid.init)
        {
            throw new StratumException("already connected.");
        }

        threadID_ = spawnLinked(
            &openStratumConnection,
            params_.hostname,
            params_.port,
            thisTid);
        messageID_ = 0;
    }

    /**
    Subscribe job.
    */
    void subscribe()
    {
        ++messageID_;
        auto subscribeResult = enforceCallAPI!(StratumSubscribe.Result)(
            StratumSubscribe(messageID_, params_.workerName));
        jobBuilder_ = StratumJobBuilder(
            subscribeResult.extranonce1,
            subscribeResult.extranonce2Size);

        // clear jobs.
        currentJob_ = currentJob_.init;
        jobs_.clear();
    }

    /**
    Authorize worker.
    */
    void authorize()
    {
        ++messageID_;
        enforceCallAPI!(StratumAuthorize.Result)(
            StratumAuthorize(messageID_, params_.workerName, params_.password));
    }

    /**
    Receive server method.

    Params:
        timeout = timeout duration.
    */
    void doReceiveServerMethod(Duration timeout)
    {
        while(receiveServerMethod(timeout)) {}
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

    /**
    Submit job result.

    Params:
        jobResult = job result.
    Returns:
        true if submitted.
    */
    bool submit()(auto scope ref const(StratumJobResult) jobResult)
    {
        auto job = jobResult.jobID in jobs_;
        if (jobResult.empty || !job)
        {
            return false;
        }

        ++messageID_;
        callAPI!(StratumSubmit.Result)(StratumSubmit(
            messageID_,
            params_.workerName,
            jobResult.jobID,
            format("%0*x", job.extranonce2Size * 2, jobResult.extranonce2),
            format("%08x", bswap(jobResult.ntime)),
            format("%08x", bswap(jobResult.nonce))));

        return true;
    }

    /**
    Suggest difficulty.

    Params:
        difficulty = suggest difficulty.
    */
    void suggestDifficulty(double difficulty)
    {
        ++messageID_;
        threadID_.send(StratumSuggestDifficulty(messageID_, difficulty));
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

    /**
    Returns:
        true if job notified.
    */
    @property bool jobExists() const @nogc nothrow pure @safe scope
    {
        return jobs_.length > 0;
    }

    /**
    Check job ID is exists.

    Params:
        jobID = check job ID.
    Returns:
        true if job notified.
    */
    bool hasJob(string jobID) const @nogc nothrow pure @safe scope
    {
        return (jobID in jobs_) ? true : false;
    }

private:
    StratumClientParams params_;
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

