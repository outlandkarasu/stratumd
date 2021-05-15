module stratumd.btc.job;

import std.ascii : LetterCase;
import std.algorithm : map;
import std.array : appender, array;
import std.digest : toHexString, Order;
import std.format : format;
import std.digest.sha : sha256Of;
import std.bigint : BigInt;
import std.exception : assumeWontThrow;
import std.json : JSONValue;

import stratumd.hex :
    hexToBytes,
    hexToBytesReverse,
    hexReverse;

/**
BTC job request.
*/
struct BTCJob
{
    string jobID;
    string header;
    uint[8] target;
    uint extranonce2;
    uint extranonce2Size;
}

/**
BTC job result.
*/
struct BTCJobResult
{
    string workerName;
    string jobID;
    uint ntime;
    uint nonce;
    uint extranonce2;
    uint extranonce2Size;
}

/**
BTC job builder.
*/
struct BTCJobBuilder
{
    alias Job = BTCJob;
    alias JobResult = BTCJobResult;

    void receiveNotify(scope const(JSONValue)[] params)
    {
        auto jobID = params[0].str;
        if (notification_.jobID != jobID)
        {
            extranonce2_ = 0;
        }

        notification_ = BTCJobNotification(
            jobID,
            params[1].str,
            params[2].str,
            params[3].str,
            params[4].array.map!((e) => e.str).array,
            params[5].str,
            params[6].str,
            params[7].str,
            params[8].boolean);
    }

    void receiveSubscribeResponse(scope ref const(JSONValue) result)
    {
        updateExtranonce(result[1].str, result[2].get!int);
    }

    void receiveSetExtranonce(scope const(JSONValue)[] params)
    {
        updateExtranonce(params[0].str, params[1].get!int);
    }

    void receiveSetDifficulty(scope const(JSONValue)[] params) pure @safe
    {
        difficulty_ = params[0].get!double;
    }

    BTCJob build() pure @safe const
    {
        auto buffer = appender!(ubyte[])();
        buffer ~= notification_.coinb1.hexToBytes;
        buffer ~= extranonce1_.hexToBytes;

        foreach (i; 0 .. extranonce2Size_)
        {
            immutable shift = 8 * (extranonce2Size_ - 1 - i);
            buffer ~= cast(ubyte)((extranonce2_ >> shift) & 0xff);
        }

        buffer ~= notification_.coinb2.hexToBytes;

        auto merkleRoot = sha256Of(sha256Of(buffer[]));
        foreach (branch; notification_.merkleBranch)
        {
            buffer.clear();
            buffer ~= merkleRoot[];
            buffer ~= branch.hexToBytes;
            merkleRoot = sha256Of(sha256Of(buffer[]));
        }

        auto header = appender!string();
        header ~= notification_.blockVersion.hexReverse;
        header ~= notification_.prevHash;
        header ~= merkleRoot.toHexString!(LetterCase.lower, Order.increasing)[];
        header ~= notification_.ntime.hexReverse;
        header ~= notification_.nbits.hexReverse;
        header ~= "00000000"; // nonce
        
        return BTCJob(
            notification_.jobID,
            header[],
            calculateTarget(difficulty_),
            extranonce2_,
            extranonce2Size_);
    }

    /**
    Set up next job.
    */
    void completeJob(string jobID) @nogc nothrow pure @safe scope
    {
        if (jobID == notification_.jobID)
        {
            ++extranonce2_;
        }
    }

    /**
    clean current job.
    */
    void cleanJob() @nogc nothrow pure @safe scope
    {
        extranonce2_ = 0;
    }

    @property const @nogc nothrow pure @safe scope
    {
        string jobID() { return notification_.jobID; }
        bool cleanJobs() { return notification_.cleanJobs; }
        string extranonce1() { return extranonce1_; }
        uint extranonce2() { return extranonce2_; }
        uint extranonce2Size() { return extranonce2Size_; }
        double difficulty() { return difficulty_; }
    }

    @property @nogc nothrow pure @safe scope
    {
        void extranonce2(uint value) { extranonce2_ = value; }
        void difficulty(double value) { difficulty_ = value; }
    }

    static const(JSONValue)[] resultToJSONParams(scope ref const(JobResult) result)
    {
        return BTCJobSubmit.fromResult(result).toJSONParams;
    }

private:
    BTCJobNotification notification_;
    string extranonce1_;
    uint extranonce2_;
    uint extranonce2Size_;
    double difficulty_ = 1.0;

    void updateExtranonce(string extranonce1, uint extranonce2Size)
    {
        extranonce1_ = extranonce1;
        extranonce2_ = 0;
        extranonce2Size_ = extranonce2Size;
    }
}

///
unittest
{
    import std.stdio : writefln;
    import std.conv : to;

    // example block: 00000000000000001e8d6829a8a21adc5d38d0a473b144b6765798e61f98bd1d (125552)
    string tx1 = hexReverse("60c25dda8d41f8d3d7d5c6249e2ea1b05a25bf7ae2ad6d904b512b31f997e1a1");
    string tx2 = hexReverse("01f314cdd8566d3e5dbdd97de2d9fbfbfd6873e916a00d48758282cbb81a45b9");
    string tx3 = hexReverse("b519286a1040da6ad83c783eb2872659eaf57b1bec088e614776ffe7dc8f6d01");
    string tx23 = sha256Of(sha256Of(tx2.hexToBytes ~ tx3.hexToBytes)).toHexString!(LetterCase.lower, Order.increasing).idup;
    string expectedHeaderAndNonce = "0100000081cd02ab7e569e8bcd9317e2fe99f2de44d49ab2b8851ba4a308000000000000e320b6c2fffc8d750423db8b1eb942ae710e951ed797f7affc8892b0f1fc122bc7f5d74df2b9441a42a14695";
    string extranonce1 = "2a010000";
    immutable extranonce2 = 0x434104;
    immutable extranonce2Size = 4;

    // extranonce1: "2a010000"
    // extranonce2: "00434104"
    auto builder = BTCJobBuilder();
    builder.receiveSubscribeResponse(JSONValue([
        JSONValue(""),
        JSONValue(extranonce1),
        JSONValue(extranonce2Size),
    ]));
    assert(builder.extranonce1 == extranonce1);
    assert(builder.extranonce2Size == extranonce2Size);

    builder.receiveSetDifficulty([JSONValue(1)]);

    builder.receiveNotify([
        JSONValue("job-id"),
        JSONValue(hexReverse("00000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd81")),
        JSONValue("01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0804f2b9441a022a01ffffffff01403415"),
        JSONValue("d879d5ef8b70cf0a33925101b64429ad7eb370da8ad0b05c9cd60922c363a1eada85bcc2843b7378e226735048786c790b30b28438d22acfade24ef047b5f865ac00000000"),
        JSONValue([ tx1, tx23, ]),
        JSONValue("00000001"),
        JSONValue("1a44b9f2"),
        JSONValue("4dd7f5c7"),
        JSONValue(false),
    ]);
    builder.extranonce2 = extranonce2;

    auto job = builder.build();
    assert(job.extranonce2 == extranonce2);
    assert(job.extranonce2Size == extranonce2Size);
    assert(job.header[0 .. $ - 8] == expectedHeaderAndNonce[0 .. $ - 8]);
    assert(job.header[$ - 8 .. $] == "00000000");
    assert(job.target == [0, 0, 0, 0, 0, 0, 0xFFFF0000, 0]);
    string coinbase = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0804f2b9441a022a01ffffffff01403415"
        ~ "2a010000" ~ "00434104"
        ~ "d879d5ef8b70cf0a33925101b64429ad7eb370da8ad0b05c9cd60922c363a1eada85bcc2843b7378e226735048786c790b30b28438d22acfade24ef047b5f865ac00000000";
    assert(sha256Of(sha256Of(coinbase.hexToBytes)).toHexString!(LetterCase.lower, Order.decreasing)
            == "51d37bdd871c9e1f4d5541be67a6ab625e32028744d7d4609d0c37747b40cd2d");
}

private:

/**
BTC Job submit content.
*/
struct BTCJobSubmit
{
    string workerName;
    string jobID;
    string ntime;
    string nonce;
    string extranonce2;

    /**
    Construct from JobResult.
    */
    static BTCJobSubmit fromResult()(
        auto scope ref const(BTCJobResult) result) nothrow pure @safe
    {
        BTCJobSubmit submit = {
            workerName: result.workerName,
            jobID: result.jobID,
            ntime: assumeWontThrow(format("%08x", result.ntime)),
            nonce: assumeWontThrow(format("%08x", result.nonce)),
            extranonce2: assumeWontThrow(format("%0*x", result.extranonce2Size * 2, result.extranonce2)),
        };
        return submit;
    }

    /**
    Result to JSON params.
    */
    const(JSONValue)[] toJSONParams()
    {
        return [
            JSONValue(workerName),
            JSONValue(jobID),
            JSONValue(extranonce2),
            JSONValue(ntime),
            JSONValue(nonce),
        ];
    }
}

///
nothrow pure @safe unittest
{
    immutable submit = BTCJobSubmit.fromResult(
        BTCJobResult(
            "test-worker",
            "test-job-id",
            0x3456789,
            0xABCDEF,
            0x1234,
            3));
    assert(submit.workerName == "test-worker");
    assert(submit.jobID == "test-job-id");
    assert(submit.ntime == "03456789");
    assert(submit.nonce == "00abcdef");
    assert(submit.extranonce2 == "001234");
}

/**
Dificulty1 value.
*/
immutable difficulty1 = BigInt("0x00000000FFFF0000000000000000000000000000000000000000000000000000");
//private immutable difficulty1 = BigInt("0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");

/**
BTC Job notification.
*/
struct BTCJobNotification
{
    string jobID;
    string prevHash;
    string coinb1;
    string coinb2;
    string[] merkleBranch;
    string blockVersion;
    string nbits;
    string ntime;
    bool cleanJobs;
}

uint[8] calculateTarget(double difficulty) nothrow pure @safe
{
    enum ulong scale = 10 ^^ 16;
    BigInt result = difficulty1;
    result *= scale;
    result /= cast(ulong)(difficulty * scale);

    uint[8] resultWords;
    size_t lastNonZeroIndex = 0;
    foreach(i; 0 .. result.uintLength)
    {
        immutable word = result.getDigit!uint(i);
        resultWords[i] = word;
        if (word > 0 && i > 0)
        {
            resultWords[i - 1] = 0;
        }
    }

    return resultWords;
}

///
@safe unittest
{
    import std.algorithm : map;
    import std.string : format;
    import std.conv : to;
    import std.stdio : writeln;
    assert(calculateTarget(1.0) == [0, 0, 0, 0, 0, 0, 0xffff0000, 0]);
    //assert(calculateTarget(16307.669773817162) == [0, 0, 0, 0, 0, 0, 0x404cb, 0]);
}

