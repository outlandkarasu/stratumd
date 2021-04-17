import std.stdio;

import core.time : seconds;
import std.datetime : Clock;
import std.experimental.logger : errorf, info, infof;

import stratumd.client : StratumClientParams, StratumClient;

void main()
{
    scope client = new StratumClient();
    immutable StratumClientParams params = {
        hostname: "sha256.usa-west.nicehash.com",
        port: 3334,
        workerName: "test-worker",
        password: "test-password"
    };
    client.connect(params);
    client.close();
}

