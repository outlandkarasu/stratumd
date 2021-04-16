module stratumd.methods;

import std.json : JSONValue, toJSON;
import std.typecons : Nullable, nullable;

/**
Stratum authorize method.
*/
struct StratumAuthorize
{
    enum method = "mining.authorize";
    alias Result = StratumBooleanResult;

    int id;
    string username;
    string password;

    string toJSON() const
    {
        auto json = createMethodJSON(id, method);
        json["params"] = [username, password];
        return json.toJSON();
    }
}

///
unittest
{
    auto authorize = StratumAuthorize(1, "testname", "testword");
    assert(authorize.toJSON ==
        `{"id":1,"method":"mining.authorize",`
        ~ `"params":["testname","testword"]}`);
}

/**
Stratum subscribe method.
*/
struct StratumSubscribe
{
    enum method = "mining.subscribe";

    int id;
    string userAgent;

    string toJSON() const
    {
        auto json = createMethodJSON(id, method);
        json["params"] = [userAgent];
        return json.toJSON();
    }

    struct Result
    {
        int id;
        string extranonce1;
        int extranonce2Size;

        static Result parse()(auto ref const(JSONValue) json)
        {
            immutable id = cast(int) json["id"].integer;
            auto result = json["result"].array;
            return Result(id, result[1].str, cast(int) result[2].integer);
        }
    }
}

///
unittest
{
    auto subscribe = StratumSubscribe(1, "test-agent");
    assert(subscribe.toJSON ==
        `{"id":1,"method":"mining.subscribe",`
        ~ `"params":["test-agent"]}`);
}

///
unittest
{
    import std.json : parseJSON;

    auto json = parseJSON(
        `{"id":1,"error":null,"result":[[],"nonce1",4]}`);
    immutable result = StratumSubscribe.Result.parse(json);
    assert(result.id == 1);
    assert(result.extranonce1 == "nonce1");
    assert(result.extranonce2Size == 4);
}

/**
Stratum submit method.
*/
struct StratumSubmit
{
    enum method = "mining.submit";
    alias Result = StratumBooleanResult;

    int id;
    string workerName;
    string jobID;
    string extraNonce2;
    string ntime;
    string nonce;

    string toJSON() const
    {
        auto json = createMethodJSON(id, method);
        json["params"] = [workerName, jobID, extraNonce2, ntime, nonce];
        return json.toJSON();
    }
}

///
unittest
{
    auto authorize = StratumSubmit(
        1, "test-worker", "test-job", "exnonce2", "abcdef", "ghqr");
    assert(authorize.toJSON ==
        `{"id":1,"method":"mining.submit",`
        ~ `"params":["test-worker","test-job","exnonce2","abcdef","ghqr"]}`);
}

/**
Stratum notify method.
*/
struct StratumNotify
{
    enum method = "mining.notify";

    string jobID;
    string prevHash;
    string coinb1;
    string coinb2;
    string merkleBranch1;
    string merkleBranch2;
    string blockVersion;
    string nbits;
    string ntime;
    bool cleanJobs;

    static StratumNotify parse()(const(JSONValue)[] params)
    {
        auto markleBranches = params[4].array;
        return StratumNotify(
            params[0].str,
            params[1].str,
            params[2].str,
            params[3].str,
            markleBranches[0].str,
            markleBranches[1].str,
            params[5].str,
            params[6].str,
            params[7].str,
            params[8].boolean);
    }
}

///
unittest
{
    import std.json : parseJSON;

    auto json = parseJSON(
        `{"id":1,"method":"mining.notify",`
        ~ `"params":["job-id","prev-hash","coinb1","coinb2",`
        ~ `["mb1","mb2"],"bversion","1234","5678",true]}`);
    immutable result = StratumNotify.parse(json["params"].array);
    assert(result.jobID == "job-id");
    assert(result.prevHash == "prev-hash");
    assert(result.coinb1 == "coinb1");
    assert(result.coinb2 == "coinb2");
    assert(result.merkleBranch1 == "mb1");
    assert(result.merkleBranch2 == "mb2");
    assert(result.blockVersion == "bversion");
    assert(result.nbits == "1234");
    assert(result.ntime == "5678");
    assert(result.cleanJobs == true);
}

/**
Stratum set_difficulty method.
*/
struct StratumSetDifficulty
{
    enum method = "mining.set_difficulty";

    int difficulty;

    static StratumSetDifficulty parse()(const(JSONValue)[] params)
    {
        return StratumSetDifficulty(cast(int) params[0].integer);
    }
}

///
unittest
{
    import std.json : parseJSON;

    auto json = parseJSON(`{"id":1,"params":[4]}`);
    immutable result = StratumSetDifficulty.parse(json["params"].array);
    assert(result.difficulty == 4);
}

/**
Stratum set extranonce.
*/
struct StratumSetExtranonce
{
    enum method = "mining.set_extranonce";

    string extranonce1;
    int extranonce2Size;

    static StratumSetExtranonce parse()(const(JSONValue)[] params)
    {
        return StratumSetExtranonce(params[0].str, cast(int) params[1].integer);
    }
}

///
unittest
{
    import std.json : parseJSON;

    auto json = parseJSON(`{"id":1,"params":["nonce1",8]}`);
    immutable result = StratumSetExtranonce.parse(json["params"].array);
    assert(result.extranonce1 == "nonce1");
    assert(result.extranonce2Size == 8);
}

/**
Stratum reconnect.
*/
struct StratumReconnect
{
    enum method = "client.reconnect";

    struct Result
    {
        int id;
    }

    static StratumRecoonect parse()(const(JSONValue)[] params)
    {
        return StratumReconnect.init;
    }
}

struct StratumBooleanResult
{
    int id;
    bool result;

    static StratumBooleanResult parse()(auto ref const(JSONValue) json)
    {
        immutable id = cast(int) json["id"].integer;
        immutable result = json["result"].boolean;
        return StratumBooleanResult(id, result);
    }
}

///
unittest
{
    import std.json : parseJSON;

    auto json = parseJSON(`{"id":1,"error":null,"result":true}`);
    immutable result = StratumBooleanResult.parse(json);
    assert(result.id == 1);
    assert(result.result == true);
}

private:

JSONValue createMethodJSON(int id, string method)
{
    auto json = JSONValue(["id": id]);
    json["method"] = method;
    return json;
}

