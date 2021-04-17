module stratumd.job;

/**
Stratum job request.
*/
struct StratumJob
{
    string jobID;
    string header;
    string extranonce1;
    int extranonce2Size;
    double difficulty;
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
    int extranonce2Size;
    double difficulty;

    StratumJob build()(auto scope ref const(StratumNotify) notify) @nogc nothrow pure @safe const
    {
        return StratumJob.init;
    }
}
