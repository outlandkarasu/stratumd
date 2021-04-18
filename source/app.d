import std.stdio;

import core.time : seconds;
import std.datetime : Clock;
import std.experimental.logger : errorf, info, infof;
import std.process : environment;
import std.conv : to;

import stratumd.client : StratumClientParams, StratumClient;

void main()
{
    immutable StratumClientParams params = {
        hostname: environment.get("STRATUMD_HOSTNAME"),
        port: environment.get("STRATUMD_PORT").to!ushort,
        workerName: environment.get("STRATUMD_WORKER_NAME"),
        password: environment.get("STRATUMD_PASSWORD")
    };

    scope client = new StratumClient();
    client.connect(params);
    writeln(client.buildCurrentJob(1));
    client.close();
}

