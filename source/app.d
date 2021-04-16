import std.stdio;

import core.time : seconds;
import std.datetime : Clock;
import std.experimental.logger : errorf, info, infof;

import stratumd.client : openStratumConnection;

void main()
{
    immutable startTime = Clock.currTime();
    openStratumConnection("sha256.usa-west.nicehash.com", 3334);
}
