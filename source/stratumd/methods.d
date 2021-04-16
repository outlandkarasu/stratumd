module stratumd.methods;

import std.json : JSONValue, toJSON;
import std.typecons : Nullable, nullable;

/**
Stratum authorize method.
*/
struct StratumAuthorize
{
    enum method = "mining.authorize";

    string username;
    string password;

    struct Result
    {
        int id;
        bool result;

        static Nullable!Result parse()(auto ref const(JSONValue) json)
        {
            if (json.getMethod() != method)
            {
                return typeof(return).init;
            }

            immutable id = cast(int) json["id"].integer;
            immutable result = json["result"].boolean;
            return Result(id, result).nullable;
        }
    }

    string toJSON(int id) const
    {
        auto json = createMethodJSON(id, method);
        json["params"] = [username, password];
        return json.toJSON();
    }
}

///
unittest
{
    auto authorize = StratumAuthorize("testname", "testword");
    assert(authorize.toJSON(1) ==
        `{"id":1,"method":"mining.authorize",`
        ~ `"params":["testname","testword"]}`);
}

///
unittest
{
    import std.json : parseJSON;

    auto json = parseJSON(`{"id":1,"method":"mining.authorize","error":null,"result":true}`);
    immutable result = StratumAuthorize.Result.parse(json);
    assert(!result.isNull);
    assert(result.get.id == 1);
    assert(result.get.result == true);

    json = parseJSON(`{"id":1,"method":"mining.invalid","error":null,"result":true}`);
    assert(StratumAuthorize.Result.parse(json).isNull);
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

Nullable!string getMethod()(auto ref const(JSONValue) json)
{
    auto method = "method" in json;
    return method ? method.str.nullable : typeof(return).init;
}

