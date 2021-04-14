import std.stdio;

import stratumd.tcp_stream : openTCPStream;
import core.thread : Thread;
import core.time : seconds;

void main()
{
    scope stream = openTCPStream("www.google.com", 443, (data) => writefln("%s", data), (error) => writefln("error: %s", error));
    stream.send("test");
    Thread.sleep(5.seconds);
}
