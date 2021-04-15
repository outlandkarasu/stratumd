import std.stdio;

import stratumd.tcp_stream : openTCPStream;
import core.thread : Thread;
import core.time : seconds;

void main()
{
    scope stream = openTCPStream("sha256.usa-west.nicehash.com", 3334, (data) => writefln("%s", data), (error) => writefln("error: %s", error));
    stream.send("{\"id\": 1, \"method\": \"mining.subscribe\", \"params\": []}\n");
    Thread.sleep(5.seconds);
}
