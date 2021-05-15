module stratumd.job;

import std.string : indexOf;
import std.algorithm : joiner;
import std.range : chunks, enumerate;
import std.format : format;
import std.typecons : No;
import std.ascii : lowerHexDigits, LetterCase;
import std.array : appender, array;
import std.digest : toHexString, Order;
import std.digest.sha : sha256Of;
import std.bigint : BigInt, toHex;
import std.exception : assumeUnique, assumeWontThrow;

/**
Dificulty1 value.
*/
immutable difficulty1 = BigInt("0x00000000FFFF0000000000000000000000000000000000000000000000000000");
//immutable difficulty1 = BigInt("0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");

/**
Job notification.
*/
struct JobNotification
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

/**
Job submit content.
*/
struct JobSubmit
{
    string workerName;
    string jobID;
    string ntime;
    string nonce;
    string extranonce2;

    /**
    Construct from JobResult.
    */
    static JobSubmit fromResult()(
        auto scope ref const(JobResult) result) nothrow pure @safe
    {
        JobSubmit submit = {
            workerName: result.workerName,
            jobID: result.jobID,
            ntime: assumeWontThrow(format("%08x", result.ntime)),
            nonce: assumeWontThrow(format("%08x", result.nonce)),
            extranonce2: assumeWontThrow(format("%0*x", result.extranonce2Size * 2, result.extranonce2)),
        };
        return submit;
    }
}

///
nothrow pure @safe unittest
{
    immutable submit = JobSubmit.fromResult(
        JobResult(
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
Stratum job request.
*/
struct Job
{
    string jobID;
    string header;
    uint[8] target;
    uint extranonce2;
}

/**
Stratum job result.
*/
struct JobResult
{
    string workerName;
    string jobID;
    uint ntime;
    uint nonce;
    uint extranonce2;
    uint extranonce2Size;
}

/**
Job builder.
*/
struct JobBuilder
{
    string extranonce1;
    uint extranonce2;
    uint extranonce2Size;
    double difficulty = 1.0;

    Job build()(auto scope ref const(JobNotification) notify) pure @safe const
    {
        auto buffer = appender!(ubyte[])();
        buffer ~= notify.coinb1.hexToBytes;
        buffer ~= extranonce1.hexToBytes;

        foreach (i; 0 .. extranonce2Size)
        {
            immutable shift = 8 * (extranonce2Size - 1 - i);
            buffer ~= cast(ubyte)((extranonce2 >> shift) & 0xff);
        }

        buffer ~= notify.coinb2.hexToBytes;

        auto merkleRoot = sha256Of(sha256Of(buffer[]));
        foreach (branch; notify.merkleBranch)
        {
            buffer.clear();
            buffer ~= merkleRoot[];
            buffer ~= branch.hexToBytes;
            merkleRoot = sha256Of(sha256Of(buffer[]));
        }

        auto header = appender!string();
        header ~= notify.blockVersion.hexReverse;
        header ~= notify.prevHash;
        header ~= merkleRoot.toHexString!(LetterCase.lower, Order.increasing)[];
        header ~= notify.ntime.hexReverse;
        header ~= notify.nbits.hexReverse;
        header ~= "00000000"; // nonce
        
        return Job(
            notify.jobID,
            header[],
            calculateTarget(difficulty),
            extranonce2);
    }

    /**
    Set up next job.
    */
    void completeJob() @nogc nothrow pure @safe scope
    {
        ++extranonce2;
    }

    /**
    clean current job.
    */
    void cleanJob() @nogc nothrow pure @safe scope
    {
        extranonce2 = 0;
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

    // extranonce1: "2a010000"
    // extranonce2: "00434104"
    auto builder = JobBuilder(extranonce1, extranonce2, 4, 1);
    auto job = builder.build(JobNotification(
        "job-id",
        hexReverse("00000000000008a3a41b85b8b29ad444def299fee21793cd8b9e567eab02cd81"),
        "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0804f2b9441a022a01ffffffff01403415",
        "d879d5ef8b70cf0a33925101b64429ad7eb370da8ad0b05c9cd60922c363a1eada85bcc2843b7378e226735048786c790b30b28438d22acfade24ef047b5f865ac00000000",
        [ tx1, tx23, ],
        "00000001",
        "1a44b9f2",
        "4dd7f5c7",
        false));
    assert(job.extranonce2 == extranonce2);
    assert(job.header[0 .. $ - 8] == expectedHeaderAndNonce[0 .. $ - 8]);
    assert(job.header[$ - 8 .. $] == "00000000");
    assert(job.target == [0, 0, 0, 0, 0, 0, 0xFFFF0000, 0]);
    string coinbase = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0804f2b9441a022a01ffffffff01403415"
        ~ "2a010000" ~ "00434104"
        ~ "d879d5ef8b70cf0a33925101b64429ad7eb370da8ad0b05c9cd60922c363a1eada85bcc2843b7378e226735048786c790b30b28438d22acfade24ef047b5f865ac00000000";
    assert(sha256Of(sha256Of(coinbase.hexToBytes)).toHexString!(LetterCase.lower, Order.decreasing)
            == "51d37bdd871c9e1f4d5541be67a6ab625e32028744d7d4609d0c37747b40cd2d");
}

immutable(ubyte)[] hexToBytes(scope string hex) nothrow pure @safe
{
    auto buffer = appender!(immutable(ubyte)[])();
    ubyte value = 0;
    foreach (i, c; hex)
    {
        immutable found = lowerHexDigits.indexOf(c, No.caseSensitive);
        immutable ubyte octet = cast(ubyte)((found < 0) ? 0 : found);
        if (i & 0x1)
        {
            value |= octet;
            buffer ~= value;
        }
        else
        {
            value = cast(ubyte)(octet << 4);
        }
    }

    return buffer[];
}

///
nothrow pure @safe unittest
{
    assert("01".hexToBytes == [ubyte(0x01)]);
    assert("01020304".hexToBytes == [ubyte(0x01), 0x02, 0x03, 0x04]);
    assert("12345678abcdef".hexToBytes == [ubyte(0x12), 0x34, 0x56, 0x78, 0xab, 0xcd, 0xef]);
    assert("ABCDEF12345678".hexToBytes == [ubyte(0xab), 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78]);
}

immutable(ubyte)[] hexToBytesReverse(scope string hex) nothrow pure @safe
{
    auto buffer = new ubyte[](hex.length >> 1);
    ubyte value = 0;
    foreach (i, c; hex)
    {
        immutable found = lowerHexDigits.indexOf(c, No.caseSensitive);
        immutable ubyte octet = cast(ubyte)((found < 0) ? 0 : found);
        if (i & 0x1)
        {
            value |= octet;
            buffer[(buffer.length - 1) - (i >> 1)] = value;
        }
        else
        {
            value = cast(ubyte)(octet << 4);
        }
    }

    return (() @trusted => assumeUnique(buffer[]))();
}

///
nothrow pure @safe unittest
{
    assert("01".hexToBytesReverse == [ubyte(0x01)]);
    assert("01020304".hexToBytesReverse == [ubyte(0x04), 0x03, 0x02, 0x01]);
    assert("12345678abcdef".hexToBytesReverse == [ubyte(0xef), 0xcd, 0xab, 0x78, 0x56, 0x34, 0x12]);
    assert("ABCDEF12345678".hexToBytesReverse == [ubyte(0x78), 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab]);
}

string hexReverse(scope const(char)[] value) nothrow pure @safe
    in (value.length % 2 == 0)
{
    auto buffer = new char[](value.length);
    for (size_t i = 0; i < value.length; i += 2)
    {
        buffer[$ - 2 - i] = value[i];
        buffer[$ - 1 - i] = value[i + 1];
    }
    return (() @trusted => assumeUnique(buffer))();
}

///
nothrow pure @safe unittest
{
    assert("".hexReverse == "");
    assert("12".hexReverse == "12");
    assert("1234".hexReverse == "3412");
    assert("123456".hexReverse == "563412");
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

