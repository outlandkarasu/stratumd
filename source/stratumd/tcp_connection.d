module stratumd.tcp_connection;

import core.time : msecs;
import std.exception : basicExceptionCtors;
import std.socket : InternetAddress, Socket, TcpSocket, SocketSet, SocketShutdown;

/**
Close connection operator.
*/
interface TCPCloser
{
    /**
    Close connection.
    */
    void close();
}

/**
Send data operator.
*/
interface TCPSender : TCPCloser
{
    /**
    Send data.

    Params:
        data = send data. After send, truncated sent length.
    */
    void send(scope ref const(void)[] data);
}

/**
TCP connection event handler.
*/
interface TCPHandler
{
    /**
    Callback on sendable.
    */
    void onSendable(scope TCPSender sender);

    /**
    Callback on receive data.
    */
    void onReceive(scope const(void)[] data, scope TCPCloser closer);

    /**
    Callback on error.
    */
    void onError(scope string errorText, scope TCPCloser closer);

    /**
    Callback on idle time.
    */
    void onIdle(scope TCPCloser closer);
}

/**
Open connection.

Params:
    hostname = target host name.
    port = target port no.
    handler = TCP event handler.
*/
void openTCPConnection(scope const(char)[] hostname, ushort port, scope TCPHandler handler)
{
    bool isClose = false;
    scope socket = new TcpSocket();
    socket.connect(new InternetAddress(hostname, port));
    scope(exit) socket.close();

    scope operations = new class TCPSender
    {
        void send(scope ref const(void)[] data)
        {
            immutable sent = socket.send(data);
            if (sent == Socket.ERROR)
            {
                handler.onError(socket.getErrorText(), this);
            }
            else
            {
                data = data[sent .. $];
            }
        }

        void close()
        {
            socket.shutdown(SocketShutdown.SEND);
        }
    };

    scope receiveBuffer = new ubyte[](8192);
    scope receiveSet = new SocketSet(1);
    scope sendSet = new SocketSet(1);
    scope errorSet = new SocketSet(1);
    for (;;)
    {
        receiveSet.reset();
        receiveSet.add(socket);

        errorSet.reset();
        errorSet.add(socket);

        sendSet.reset();
        sendSet.add(socket);

        if (Socket.select(receiveSet, sendSet, errorSet, 10.msecs) <= 0)
        {
            continue;
        }

        if (receiveSet.isSet(socket))
        {
            immutable receivedSize = socket.receive(receiveBuffer);
            if (receivedSize == 0)
            {
                // closed.
                break;
            }
            else if (receivedSize == Socket.ERROR)
            {
                handler.onError(socket.getErrorText(), operations);
                continue;
            }

            handler.onReceive(receiveBuffer[0 .. receivedSize], operations);
        }

        if (sendSet.isSet(socket))
        {
            handler.onSendable(operations);
        }

        if (errorSet.isSet(socket))
        {
            handler.onError(socket.getErrorText(), operations);
        }
    }
}

