module stratumd.exception;

import std.exception : basicExceptionCtors;

/**
Stratum related exception.
*/
class StratumException : Exception
{
    mixin basicExceptionCtors;
}

