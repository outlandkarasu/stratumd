module stratumd.job;

import std.string : indexOf;
import std.format : format;
import std.typecons : No;
import std.ascii : lowerHexDigits, LetterCase;
import std.array : appender;
import std.digest : toHexString, Order;
import std.digest.sha : sha256Of;
import std.bigint : BigInt, toHex;
import std.exception : assumeUnique;

import stratumd.methods : StratumNotify;

/**
Dificulty1 value.
*/
//immutable difficulty1 = BigInt("0x00000000FFFF0000000000000000000000000000000000000000000000000000");
immutable difficulty1 = BigInt("0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");

/**
Stratum job request.
*/
struct StratumJob
{
    string jobID;
    string header;
    uint[8] target;
    uint extranonce2;
}

/**
Stratum job response.
*/
struct StratumJobResult
{
    string jobID;
    uint ntime;
    uint nonce;
    uint extranonce2;
}

/**
Job builder.
*/
struct StratumJobBuilder
{
    string extranonce1;
    int extranonce2Size;
    double difficulty = 1.0;

    StratumJob build()(auto scope ref const(StratumNotify) notify, uint extranonce2) pure @safe const
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

        auto header =
            notify.blockVersion
            ~ notify.prevHash
            ~ merkleRoot.toHexString!(LetterCase.lower, Order.decreasing)
            ~ notify.ntime
            ~ notify.nbits
            ~ "00000000"; // nonce
        return StratumJob(
            notify.jobID,
            header.idup,
            calculateTarget(difficulty),
            extranonce2);
    }
}

///
unittest
{

    auto builder = StratumJobBuilder("08000002", 4, 1);
    auto job = builder.build(StratumNotify(
        "job-id",
        "81cd02ab7e569e8bcd9317e2fe99f2de44d49ab2b8851ba4a308000000000000",
        "",
        "",
        [],
        "01000000",
        "f2b9441a",
        "c7f5d74d",
        false), 0);
}

private:

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
    assert(calculateTarget(1.0) == [0, 0, 0, 0, 0, 0, 0xffffffff, 0]);
    assert(calculateTarget(16307.669773817162) == [0, 0, 0, 0, 0, 0, 0x404cb, 0]);
}

