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

