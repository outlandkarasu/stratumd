import std.stdio;

import core.time : seconds;
import std.datetime : Clock;
import std.experimental.logger : errorf, info, infof;

import stratumd.tcp_connection :
    openTCPConnection,
    TCPHandler,
    TCPCloser,
    TCPSender;

void main()
{
    immutable startTime = Clock.currTime();
    const(void)[] sendData = "{\"id\": 1, \"method\": \"mining.subscribe\", \"params\": []}\n";

    scope handler = new class TCPHandler
    {
        void onSendable(scope TCPSender sender)
        {
            if (sendData.length > 0)
            {
                infof("send data: %s", cast(const(char)[]) sendData);
                sender.send(sendData);
            }
        }

        void onReceive(scope const(void)[] data, scope TCPCloser closer)
        {
            infof("receive: %s", cast(const(char)[]) data);
        }

        void onError(scope string errorText, scope TCPCloser closer)
        {
            errorf("TCP connection error: %s", errorText);
        }

        void onIdle(scope TCPCloser closer)
        {
            if (Clock.currTime() - startTime > 5.seconds)
            {
                closer.close();
            }
        }
    };

    openTCPConnection("sha256.usa-west.nicehash.com", 3334, handler);

    info("close connection");
}

