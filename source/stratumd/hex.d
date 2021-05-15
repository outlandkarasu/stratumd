module stratumd.hex;

import std.array : appender, array;
import std.ascii : lowerHexDigits;
import std.exception : assumeUnique;
import std.string : indexOf;
import std.typecons : No;

/**
Hex string to bytes.
*/
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

/**
Hex string to reverse bytes.
*/
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

/**
reverse hex string.
*/
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

