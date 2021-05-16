module stratumd.eth.job;

import std.ascii : LetterCase;
import std.algorithm : map;
import std.array : appender, array;
import std.bigint : BigInt;
import std.digest : toHexString, Order;
import std.format : format;
import std.exception : assumeWontThrow;
import std.json : JSONValue;

import stratumd.hex :
    hexToBytes,
    hexToBytesReverse,
    hexReverse;

/**
ETH job request.
*/
struct ETHJob
{
    string jobID;
    string header;
    string seed;
    ubyte[32] target;
    ulong extranonce;
    uint nonceBytes;
}

/**
ETH job result.
*/
struct ETHJobResult
{
    string workerName;
    string jobID;
    ulong nonce;
    uint nonceBytes;
}

/**
ETH job builder.
*/
struct ETHJobBuilder
{
    alias Job = ETHJob;
    alias JobResult = ETHJobResult;

    void receiveNotify(scope const(JSONValue)[] params) pure @safe scope
    {
        jobID_ = params[0].str;
        seed_ = params[1].str;
        header_ = params[2].str;
        cleanJobs_ = params[3].boolean;
    }

    ///
    pure @safe unittest
    {
        ETHJobBuilder builder;
        builder.receiveNotify([
            JSONValue("test-job-id"),
            JSONValue("012345678"),
            JSONValue("abcdefabc"),
            JSONValue(true),
        ]);
        assert(builder.jobID == "test-job-id");
        assert(builder.cleanJobs);
    }

    void receiveSubscribeResponse(scope ref const(JSONValue) result) pure @safe scope
    {
        updateExtranonce(result[1].str);
    }

    ///
    pure @safe unittest
    {
        ETHJobBuilder builder;
        auto subscribeResponse = JSONValue([
            JSONValue(),
            JSONValue("123456"),
        ]);
        builder.receiveSubscribeResponse(subscribeResponse);
        assert(builder.nonceBytes == 5);
        assert(builder.extranonce == 0x1234560000000000);
    }

    void receiveSetExtranonce(scope const(JSONValue)[] params) pure @safe scope
    {
        updateExtranonce(params[0].str);
    }

    ///
    pure @safe unittest
    {
        ETHJobBuilder builder;
        builder.receiveSetExtranonce([JSONValue("abcdef1234")]);
        assert(builder.nonceBytes == 3);
        assert(builder.extranonce == 0xabcdef1234000000);
    }

    void receiveSetDifficulty(scope const(JSONValue)[] params) pure @safe scope
    {
        difficulty_ = params[0].get!double;
    }

    ///
    pure @safe unittest
    {
        import std.math : isClose;

        ETHJobBuilder builder;
        builder.receiveSetDifficulty([JSONValue(128)]);
        assert(builder.difficulty.isClose(128.0));
    }

    ETHJob build() pure @safe scope const
    {
        return ETHJob(
            jobID_,
            header_,
            seed_,
            calculateTarget(difficulty_),
            extranonce_,
            nonceBytes_);
    }

    ///
    pure @safe unittest
    {
        import std.conv : hexString;

        ETHJobBuilder builder;

        auto subscribeResponse = JSONValue([
            JSONValue(),
            JSONValue("123456"),
        ]);
        builder.receiveSubscribeResponse(subscribeResponse);
        builder.receiveSetDifficulty([JSONValue(4.0)]);

        builder.receiveNotify([
            JSONValue("test-job-id"),
            JSONValue("012345678"),
            JSONValue("abcdefabc"),
            JSONValue(true),
        ]);
        assert(builder.jobID == "test-job-id");

        immutable job = builder.build();
        assert(job.extranonce == 0x1234560000000000);
        assert(job.nonceBytes == 5);
        assert(job.target[] == hexString!"4000000000000000000000000000000000000000000000000000000000000000");
        assert(job.seed == "012345678");
        assert(job.header == "abcdefabc");
    }

    /**
    Set up next job.
    */
    void completeJob(string jobID) @nogc nothrow pure @safe scope
    {
        // do nothing.
    }

    /**
    clean current job.
    */
    void cleanJob() @nogc nothrow pure @safe scope
    {
        extranonce_ = 0;
        nonceBytes_ = 0;
    }

    @property const @nogc nothrow pure @safe scope
    {
        string jobID() { return jobID_; }
        bool cleanJobs() { return cleanJobs_; }
        ulong extranonce() { return extranonce_; }
        uint nonceBytes() { return nonceBytes_; }
        double difficulty() { return difficulty_; }
    }

    @property @nogc nothrow pure @safe scope
    {
        void extranonce(ulong value) { extranonce_ = value; }
        void difficulty(double value) { difficulty_ = value; }
    }

    static const(JSONValue)[] resultToJSONParams(scope ref const(JobResult) result)
    {
        immutable nonce = format("%0*x", ulong.sizeof * 2, result.nonce);
        return [
            JSONValue(result.workerName),
            JSONValue(result.jobID),
            JSONValue(nonce[$ - (result.nonceBytes * 2) .. $]),
        ];
    }

private:
    string jobID_;
    string header_;
    string seed_;
    bool cleanJobs_;
    ulong extranonce_;
    uint nonceBytes_;
    double difficulty_ = 1.0;

    void updateExtranonce(string extranonce) nothrow pure @safe scope
    {
        immutable bytes = hexToBytes(extranonce);

        ulong n;
        foreach (i, b; bytes)
        {
            n |= ulong(b) << ((ulong.sizeof - (i + 1)) * 8);
        }

        extranonce_ = n;
        nonceBytes_ = cast(uint)(ulong.sizeof - bytes.length);
    }
}

private:

immutable difficulty1 = BigInt(2) ^^ 256;

/**
Calculate target bytes.
*/
ubyte[32] calculateTarget(double difficulty) nothrow pure @safe
{
    enum ulong scale = 10 ^^ 16;
    BigInt result = difficulty1;
    result *= scale;
    result /= cast(ulong)(difficulty * scale);

    typeof(return) bytes;
    foreach (i; 0 .. result.ulongLength)
    {
        immutable w = result.getDigit!ulong(i);
        foreach (j; 0 .. ulong.sizeof)
        {
            bytes[(bytes.length - 1) - (i * ulong.sizeof + j)] = cast(ubyte)((w >> (j * 8)) & 0xff);
        }
    }
    return bytes;
}

///
@safe unittest
{
    import std.conv : hexString;

    assert(calculateTarget(2.0)[] == hexString!"8000000000000000000000000000000000000000000000000000000000000000");
}

