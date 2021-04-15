module stratumd.methods;

/**
Stratum authorize method.
*/
struct StratumAuthorize
{
    string username;
    string password;
}

/**
Stratum authorize result.
*/
struct StratumAuthorizeResult
{
    bool result;
}

/**
Stratum subscribe method.
*/
struct StratumSubscribe
{
    string userAgent;
}

/**
Stratum subscribe result.
*/
struct StratumSubscribeResult
{
    string extranonce1;
    int extranonce2Size;
}

/**
Stratum submit method.
*/
struct StratumSubmit
{
    string workerName;
    string jobID;
    string extraNonce2;
    string ntime;
    string nonce;
}

/**
Stratum submit result.
*/
struct StratumSubmitResult
{
    bool result;
}

/**
Stratum notify method.
*/
struct StratumNotify
{
    string jobID;
    string prevHash;
    string coinb1;
    string coinb2;
    string[] merkleBranch;
    string blockVersion;
    string nbits;
    string ntime;
    bool cleanJobs;
}

/**
Stratum set_difficulty method.
*/
struct StratumSetDifficulty
{
    int difficulty;
}

