module stratumd.job;

import std.string : indexOf;
import std.typecons : No;
import std.ascii : lowerHexDigits;
import std.array : appender;
import std.digest : toHexString;
import std.digest.sha : sha256Of;

/**
Stratum job request.
*/
struct StratumJob
{
    string jobID;
    string header;
    ubyte[32] difficulty;
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
Job builder.
*/
struct StratumJobBuilder
{
    string extranonce1;
    ulong extranonce2;
    int extranonce2Size;
    double difficulty;

    StratumJob build()(auto scope ref const(StratumNotify) notify) @nogc nothrow pure @safe const
    {
        immutable coinbase = (
            notify.coinb1
            ~ extranonce1
            ~ format("%0*x", extranonce2Size * 2, extranonce2)
            ~ notify.coinb2
            ).hexToBytes;

        auto markleRoot = sha256Of(sha256Of(coinbase));
        auto buffer = appender!(ubyte[])();
        foreach (branch; notify.markleBranch)
        {
            buffer.clear();
            buffer ~= markleRoot[];
            buffer ~= branch.hexToBytes;
            markleRoot = sha256Of(sha256Of(buffer[]));
        }

        immutable header =
            notify.blockVersion
            ~ notify.prevHash
            ~ markleRoot.toHexString
            ~ notify.ntime
            ~ notify.nbits
            ~ "00000000"; // nonce
        return StratumJob(notify.jobID, header);
    }
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

