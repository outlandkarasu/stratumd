/**
TCP socket stream module.
*/
module stratumd.tcp_stream;

import core.time : msecs;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.algorithm : copy, move;
import std.array : Appender, appender;
import std.concurrency : Generator, yield, Tid;
import std.exception : basicExceptionCtors;
import std.socket :
    Socket,
    TcpSocket,
    InternetAddress,
    SocketSet,
    Address,
    SocketException,
    SocketShutdown;
import std.typecons : RefCounted, refCounted;

struct TCPStream
{
    /**
    Send data.

    Params:
        data = send data.
    */
    void send(scope const(void)[] data)
    {
        payload_.thread_.send(data);
    }

private:

    struct Payload
    {
        @disable this(this);

        TCPStreamThread thread_;

        ~this() nothrow
        {
            try
            {
                if (thread_)
                {
                    thread_.close();
                    thread_ = null;
                }
            }
            catch (Throwable e)
            {
                // ignore error.
            }
        }
    }

    this(TCPStreamThread thread)
        in (thread)
    {
        this.payload_ = Payload(thread);
    }

    RefCounted!Payload payload_;
}

/**
On receive handler.
*/
alias OnTCPReceive = void delegate(scope const(void)[] data);

/**
On error handler.
*/
alias OnTCPError = void delegate(scope string errorText);

/**
Open a TCP stream.

Params:
    info = address info.
    onReceive = on receive handler.
    onError = on error handler.
Returns:
    new TCP stream.
*/
TCPStream openTCPStream(scope const(char)[] hostname, ushort port, OnTCPReceive onReceive, OnTCPError onError)
{
    auto address = new InternetAddress(hostname, port);
    auto thread = new TCPStreamThread(address, onReceive, onError);
    thread.start();
    return TCPStream(thread);
}

private:

final class SocketClosedException : SocketException
{
    mixin basicExceptionCtors;
}

final class TCPStreamThread
{
    this(Address address, OnTCPReceive onReceive, OnTCPError onError)
        in (address)
        in (onReceive)
        in (onError)
    {
        this.socket_ = new TcpSocket();
        this.address_ = address;
        this.socket_.blocking = false;
        this.onReceive_ = onReceive;
        this.onError_ = onError;
        this.sendBuffer_ = appender!(ubyte[])();
        this.sendBufferMutex_ = new shared Mutex();
    }

    void close()
    {
        isClose_ = true;
        if (thread_)
        {
            thread_.join();
            thread_ = null;
        }
    }

    void send(scope const(void)[] data)
    {
        if (!thread_)
        {
            throw new SocketClosedException("Socket is already closed.");
        }

        sendBufferMutex_.lock_nothrow();
        scope(exit) sendBufferMutex_.unlock_nothrow();

        sendBuffer_ ~= cast(const(ubyte)[]) data;
    }

    void start()
    {
        this.thread_ = new Thread(&mainLoop);
        this.thread_.isDaemon = true;
        this.thread_.start();
    }

    void mainLoop()
    {
        socket_.connect(address_);
        scope(exit)
        {
            socket_.shutdown(SocketShutdown.BOTH);
        }

        scope receiveBuffer = new ubyte[](8192);
        scope receiveSet = new SocketSet(1);
        scope sendSet = new SocketSet(1);
        scope errorSet = new SocketSet(1);
        size_t receivedSize = 0;
        while(!isClose_ || sendBuffer_[].length > 0)
        {
            receiveSet.reset();
            receiveSet.add(socket_);

            errorSet.reset();
            errorSet.add(socket_);

            sendSet.reset();
            if (sendBuffer_[].length > 0)
            {
                sendSet.add(socket_);
            }

            if (Socket.select(receiveSet, sendSet, errorSet, 1.msecs) <= 0)
            {
                continue;
            }

            if (receiveSet.isSet(socket_))
            {
                receivedSize = socket_.receive(receiveBuffer);
                if (receivedSize == 0)
                {
                    // closed.
                    break;
                }

                onReceive_(receiveBuffer[0 .. receivedSize]);
            }

            if (sendBuffer_[].length > 0 && sendSet.isSet(socket_))
            {
                sendBufferMutex_.lock_nothrow();
                scope(exit) sendBufferMutex_.unlock_nothrow();

                immutable sentSize = socket_.send(sendBuffer_[]);
                copy(sendBuffer_[][0 .. $ - sentSize], sendBuffer_[][sentSize .. $]);
                sendBuffer_.shrinkTo(sendBuffer_[].length - sentSize);
            }

            if (errorSet.isSet(socket_))
            {
                onError_(socket_.getErrorText());
            }
        }

        socket_.shutdown(SocketShutdown.SEND);
        while(receivedSize > 0)
        {
            receivedSize = socket_.receive(receiveBuffer);
            if (receivedSize > 0)
            {
                onReceive_(receiveBuffer[0 .. receivedSize]);
            }
        }
    }

    TcpSocket socket_;
    Thread thread_;
    Address address_;
    Appender!(ubyte[]) sendBuffer_;
    shared Mutex sendBufferMutex_;
    OnTCPReceive onReceive_;
    OnTCPError onError_;
    bool isClose_;
}

