module stratumd.methods;

import std.json : JSONValue, toJSON;

/**
Stratum authorize method.
*/
struct StratumAuthorize
{
    enum method = "mining.authorize";

    int id;
    string username;
    string password;

    struct Result
    {
        int id;
        bool result;

        static Result parse()(auto ref const(JSONValue) json)
        {
            immutable id = cast(int) json["id"].integer;
            immutable result = json["result"].boolean;
            return Result(id, result);
        }
    }

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

///
unittest
{
    import std.json : parseJSON;

    auto json = parseJSON(`{"id":1,"error":null,"result":true}`);
    immutable result = StratumAuthorize.Result.parse(json);
    assert(result.id == 1);
    assert(result.result == true);
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
    shared string[] merkleBranch;
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

/**
Stratum set extranonce.
*/
struct StratumSetExtranonce
{
    string extranonce1;
    int extranonce2Size;
}

/**
Stratum reconnect.
*/
struct StratumReconnect
{
}

/**
Stratum reconnect result.
*/
struct StratumReconnectResult
{
}

private:

JSONValue createMethodJSON(int id, string method)
{
    auto json = JSONValue(["id": id]);
    json["method"] = method;
    return json;
}

