import std.stdio;

import core.time : seconds;
import std.datetime : Clock, stdTimeToUnixTime;
import std.experimental.logger : errorf, info, infof;
import std.process : environment;
import std.conv : to;

import stratumd.client : StratumClientParams, StratumClient;
import stratumd.job : StratumJobResult;

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
    immutable job = client.buildCurrentJob(1);
    writeln(job);

    immutable StratumJobResult jobResult = {
        jobID: job.jobID,
        ntime: cast(uint) Clock.currTime().stdTime.stdTimeToUnixTime,
        nonce: 0x12345678,
        extranonce2: 1,
    };
    client.submit(jobResult);
    client.close();
}

