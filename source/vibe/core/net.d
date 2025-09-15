/**
	TCP/UDP connection and server handling.

	Copyright: © 2012-2016 Sönke Ludwig
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.net;

import core.stdc.string;
import core.sys.posix.poll;
import std.exception : enforce;
import std.format : format;
import std.functional : toDelegate;
import std.socket;
import vibe.core.log;
import vibe.core.core;
import vibe.core.stream;
import vibe.internal.async;
import core.time : Duration;

import photon;

extern(C) const(char)* strerror(int errc);

@safe:

/**
	Resolves the given host name/IP address string.

	This routine converts a string to a `NetworkAddress`. If the string is an IP
	address, no network traffic will be generated and the routine will not block.
	If it is not, a DNS query will be issued, unless forbidden by the `use_dns`
	parameter, in which case the query is guaranteed not to block.

	Params:
		host = The string to resolve, either an IP address or a hostname
	    family = The desired address family to return. By default, returns
		    the family that `host` is in. If a value is specified, this routine
			will throw if the value found for `host` doesn't match this parameter.
		use_dns = Whether to use the DNS if `host` is not an IP address.
			If `false` and `host` is not an IP, this routine will throw.
			Defaults to `true`.
		timeout = If `use_dns` is `true`, the `Duration` to use as timeout
			for the DNS lookup.

	Throws:
		In case of lookup failure, if `family` doesn't match `host`,
		or if `use_dns` is `false` but `host` is not an IP.
		See the parameter description for more details.

	Returns:
		A valid `NetworkAddress` matching `host`.
*/
NetworkAddress resolveHost(string host, AddressFamily family = AddressFamily.UNSPEC, bool use_dns = true, Duration timeout = Duration.max)
{
	return resolveHost(host, cast(ushort)family, use_dns, timeout);
}

/// ditto
NetworkAddress resolveHost(string host, ushort family, bool use_dns = true, Duration timeout = Duration.max)
{
	import std.socket : parseAddress;
	version (Windows) import core.sys.windows.winsock2 : sockaddr_in, sockaddr_in6;
	else import core.sys.posix.netinet.in_ : sockaddr_in, sockaddr_in6;

	enforce(host.length > 0, "Host name must not be empty.");
	// Fast path: If it looks like an IP address, we don't need to resolve it
	if (isMaybeIPAddress(host)) {
		auto addr = parseAddress(host);
		enforce(family == AddressFamily.UNSPEC || addr.addressFamily == family);
		NetworkAddress ret;
		ret.family = addr.addressFamily;
		switch (addr.addressFamily) with(AddressFamily) {
			default: throw new Exception("Unsupported address family");
			case INET: *ret.sockAddrInet4 = () @trusted { return *cast(sockaddr_in*)addr.name; } (); break;
			case INET6: *ret.sockAddrInet6 = () @trusted { return *cast(sockaddr_in6*)addr.name; } (); break;
		}
		return ret;
	}

	// Otherwise we need to do a DNS lookup
	enforce(use_dns, "Malformed IP address string.");
	NetworkAddress res;
	bool success = false;
	foreach (addr; getAddress(host)) {
		if (family != AddressFamily.UNSPEC && addr.addressFamily != family) continue;
		try res = NetworkAddress(addr);
		catch (Exception e) { logDiagnostic("Failed to store address from DNS lookup: %s", e.msg); }
		success = true;
		break;
	}

	enforce(success, "Failed to lookup host '"~host~"'.");
	return res;
}


/**
	Starts listening on the specified port.

	'connection_callback' will be called for each client that connects to the
	server socket. Each new connection gets its own fiber. The stream parameter
	then allows to perform blocking I/O on the client socket.

	The address parameter can be used to specify the network
	interface on which the server socket is supposed to listen for connections.
	By default, all IPv4 and IPv6 interfaces will be used.
*/
TCPListener[] listenTCP(ushort port, TCPConnectionDelegate connection_callback, TCPListenOptions options = TCPListenOptions.defaults)
{
	TCPListener[] ret;
	try ret ~= listenTCP(port, connection_callback, "::", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"::\": %s", e.msg);
	try ret ~= listenTCP(port, connection_callback, "0.0.0.0", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"0.0.0.0\": %s", e.msg);
	enforce(ret.length > 0, format("Failed to listen on all interfaces on port %s", port));
	return ret;
}
/// ditto
TCPListener listenTCP(ushort port, TCPConnectionDelegate connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults)
{
	auto addr = resolveHost(address);
	addr.port = port;
	SocketOption sopts;
	if (options & TCPListenOptions.reuseAddress)
		sopts |= SocketOption.REUSEADDR;
	if (options & TCPListenOptions.reusePort)
		sopts |= SocketOption.REUSEPORT;
	Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, sopts, true);
    server.bind(new InternetAddress(addr.toAddressString(), addr.port));
    server.listen(1000);
	go({
		for (;;) {
			auto s = server.accept();
			auto conn = TCPConnection(s, addr);
			runTask(connection_callback, conn);
		}
	});
	return TCPListener(server);
}

/// Compatibility overload - use an `@safe nothrow` callback instead.
deprecated("Use a @safe nothrow callback instead.")
TCPListener[] listenTCP(ushort port, void delegate(TCPConnection) connection_callback, TCPListenOptions options = TCPListenOptions.defaults)
{
	TCPListener[] ret;
	try ret ~= listenTCP(port, connection_callback, "::", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"::\": %s", e.msg);
	try ret ~= listenTCP(port, connection_callback, "0.0.0.0", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"0.0.0.0\": %s", e.msg);
	enforce(ret.length > 0, format("Failed to listen on all interfaces on port %s", port));
	return ret;
}
/// ditto
deprecated("Use a @safe nothrow callback instead.")
TCPListener listenTCP(ushort port, void delegate(TCPConnection) connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults)
{
	return listenTCP(port, (conn) @trusted nothrow {
		try connection_callback(conn);
		catch (Exception e) {
			e.logException("Handling of connection failed");
			conn.close();
		}
	}, address, options);
}

/**
	Starts listening on the specified port.

	This function is the same as listenTCP but takes a function callback instead of a delegate.
*/
TCPListener[] listenTCP_s(ushort port, TCPConnectionFunction connection_callback, TCPListenOptions options = TCPListenOptions.defaults) @trusted
{
	return listenTCP(port, toDelegate(connection_callback), options);
}
/// ditto
TCPListener listenTCP_s(ushort port, TCPConnectionFunction connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults) @trusted
{
	return listenTCP(port, toDelegate(connection_callback), address, options);
}

/**
	Establishes a connection to the given host/port.
*/
TCPConnection connectTCP(string host, ushort port, string bind_interface = null,
	ushort bind_port = 0, Duration timeout = Duration.max)
{
	NetworkAddress addr = resolveHost(host);
	addr.port = port;
	if (addr.family != AddressFamily.UNIX)
		addr.port = port;

	NetworkAddress bind_address;
	if (bind_interface.length) bind_address = resolveHost(bind_interface, addr.family);
	else {
		bind_address.family = addr.family;
		if (bind_address.family == AddressFamily.INET) bind_address.sockAddrInet4.sin_addr.s_addr = 0;
		else if (bind_address.family != AddressFamily.UNIX) bind_address.sockAddrInet6.sin6_addr.s6_addr[] = 0;
	}
	if (addr.family != AddressFamily.UNIX)
		bind_address.port = bind_port;

	return connectTCP(addr, bind_address, timeout);
}
/// ditto
TCPConnection connectTCP(NetworkAddress addr, NetworkAddress bind_address = anyAddress,
	Duration timeout = Duration.max)
{
	import std.conv : to;
	if (bind_address.family == AddressFamily.UNSPEC) {
		bind_address.family = addr.family;
		if (bind_address.family == AddressFamily.INET) bind_address.sockAddrInet4.sin_addr.s_addr = 0;
		else if (bind_address.family != AddressFamily.UNIX) bind_address.sockAddrInet6.sin6_addr.s6_addr[] = 0;
		if (bind_address.family != AddressFamily.UNIX)
			bind_address.port = 0;
	}
	enforce(addr.family == bind_address.family, "Destination address and bind address have different address families.");

	return () @trusted { // scope
		Socket sock = new Socket(bind_address.address.addressFamily, SocketType.STREAM);
		sock.bind(bind_address.address);
		sock.connect(addr.address);
		return TCPConnection(sock, addr);
	} ();
}


/** Creates a streaming socket connection from an existing stream socket.
*/
TCPConnection createStreamConnection(Socket socket)
{
	return TCPConnection(socket, NetworkAddress(socket.remoteAddress));
}

/+
/**
	Creates a bound UDP socket suitable for sending and receiving packets.
*/
UDPConnection listenUDP(ref NetworkAddress addr, UDPListenOptions options = UDPListenOptions.none)
{
	return UDPConnection(addr, options);
}
/// ditto
UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0",
	UDPListenOptions options = UDPListenOptions.none)
{
	auto addr = resolveHost(bind_address, AddressFamily.UNSPEC, false);
	addr.port = port;
	return UDPConnection(addr, options);
}
+/
NetworkAddress anyAddress()
{
	NetworkAddress ret;
	ret.family = AddressFamily.UNSPEC;
	return ret;
}


/// Callback invoked for incoming TCP connections.
@safe nothrow alias TCPConnectionDelegate = void delegate(TCPConnection stream);
/// ditto
@safe nothrow alias TCPConnectionFunction = void function(TCPConnection stream);


/**
	Represents a network/socket address.
*/
struct NetworkAddress {
	import std.algorithm.comparison : max;
	import std.socket : Address;

	version (Windows) import core.sys.windows.winsock2;
	else import core.sys.posix.netinet.in_;

	version(Posix) import core.sys.posix.sys.un : sockaddr_un;

	@safe:

	private Address address;
	private union {
		sockaddr addr;
		version (Posix) sockaddr_un addr_unix;
		sockaddr_in addr_ip4;
		sockaddr_in6 addr_ip6;
	}

	enum socklen_t sockAddrMaxLen = max(addr.sizeof, addr_ip6.sizeof);


	this(scope const(Address) addr)
		@trusted
	{
		address = cast()addr;
		assert(addr !is null);
		switch (addr.addressFamily) {
			default: throw new Exception("Unsupported address family.");
			case AddressFamily.INET:
				this.family = AddressFamily.INET;
				assert(addr.nameLen >= sockaddr_in.sizeof);
				*this.sockAddrInet4 = *cast(sockaddr_in*)addr.name;
				break;
			case AddressFamily.INET6:
				this.family = AddressFamily.INET6;
				assert(addr.nameLen >= sockaddr_in6.sizeof);
				*this.sockAddrInet6 = *cast(sockaddr_in6*)addr.name;
				break;
			version (Posix) {
				case AddressFamily.UNIX:
					this.family = AddressFamily.UNIX;
					assert(addr.nameLen >= sockaddr_un.sizeof);
					*this.sockAddrUnix = *cast(sockaddr_un*)addr.name;
					break;
			}
		}
	}

	/** Family of the socket address.
	*/
	@property ushort family() const pure nothrow { return addr.sa_family; }
	/// ditto
	@property void family(AddressFamily val) pure nothrow { addr.sa_family = cast(ubyte)val; }
	/// ditto
	@property void family(ushort val) pure nothrow { addr.sa_family = cast(ubyte)val; }

	/** The port in host byte order.
	*/
	@property ushort port()
	const pure nothrow {
		ushort nport;
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: nport = addr_ip4.sin_port; break;
			case AF_INET6: nport = addr_ip6.sin6_port; break;
		}
		return () @trusted { return ntoh(nport); } ();
	}
	/// ditto
	@property void port(ushort val)
	pure nothrow {
		auto nport = () @trusted { return hton(val); } ();
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: addr_ip4.sin_port = nport; break;
			case AF_INET6: addr_ip6.sin6_port = nport; break;
		}
	}

	/** A pointer to a sockaddr struct suitable for passing to socket functions.
	*/
	@property inout(sockaddr)* sockAddr() inout return pure nothrow { return &addr; }

	/** Size of the sockaddr struct that is returned by sockAddr().
	*/
	@property socklen_t sockAddrLen()
	const pure nothrow {
		switch (this.family) {
			default: assert(false, "sockAddrLen() called for invalid address family.");
			case AF_INET: return addr_ip4.sizeof;
			case AF_INET6: return addr_ip6.sizeof;
			version (Posix) {
				case AF_UNIX: return addr_unix.sizeof;
			}
		}
	}

	@property inout(sockaddr_in)* sockAddrInet4() inout return pure nothrow
		in { assert (family == AF_INET); }
		do { return &addr_ip4; }

	@property inout(sockaddr_in6)* sockAddrInet6() inout return pure nothrow
		in { assert (family == AF_INET6); }
		do { return &addr_ip6; }

	version (Posix) {
		@property inout(sockaddr_un)* sockAddrUnix() inout return pure nothrow
			in { assert (family == AddressFamily.UNIX); }
			do { return &addr_unix; }
	}

	/** Returns a string representation of the IP address
	*/
	string toAddressString()
	const nothrow {
		import std.array : appender;
		auto ret = appender!string();
		ret.reserve(40);
		toAddressString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toAddressString(scope void delegate(const(char)[]) @safe sink)
	const nothrow {
		scope (failure) assert(false);

		switch (this.family) {
			default: assert(false, "toAddressString() called for invalid address family.");
			case AF_UNSPEC:
				sink("<UNSPEC>");
				break;
			case AF_INET: {
				ubyte[4] ip = () @trusted { return (cast(ubyte*)&addr_ip4.sin_addr.s_addr)[0 .. 4]; } ();
				writeV4(sink, ip);
				} break;
			case AF_INET6: {
				ubyte[16] ip = addr_ip6.sin6_addr.s6_addr;
				writeV6(sink, ip);
				} break;
			version (Posix) {
				case AddressFamily.UNIX:
					import std.traits : hasMember;
					import std.string : fromStringz;
					static if (hasMember!(sockaddr_un, "sun_len"))
						sink(() @trusted { return cast(char[])addr_unix.sun_path[0..addr_unix.sun_len]; } ());
					else
						sink(() @trusted { return (cast(char*)addr_unix.sun_path.ptr).fromStringz; } ());
					break;
			}
		}
	}

	/** Returns a full string representation of the address, including the port number.
	*/
	string toString()
	const nothrow {
		import std.array : appender;
		auto ret = appender!string();
		toString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toString(scope void delegate(const(char)[]) @safe sink)
	const nothrow {
		import std.format : formattedWrite;
		try {
			switch (this.family) {
				default: assert(false, "toString() called for invalid address family.");
				case AF_UNSPEC:
					sink("<UNSPEC>");
					break;
				case AF_INET:
					toAddressString(sink);
					// NOTE: (DMD 2.101.2) FormatSpec.writeUpToNextSpec doesn't forward 'sink' as scope
					() @trusted { sink.formattedWrite(":%s", port); } ();
					break;
				case AF_INET6:
					sink("[");
					toAddressString(sink);
					// NOTE: (DMD 2.101.2) FormatSpec.writeUpToNextSpec doesn't forward 'sink' as scope
					() @trusted { sink.formattedWrite("]:%s", port); } ();
					break;
				case AddressFamily.UNIX:
					toAddressString(sink);
					break;
			}
		} catch (Exception e) {
			assert(false, "Unexpected exception: "~e.msg);
		}
	}

	unittest {
		void test(string ip, string expected = null) @trusted {
			if(expected is null) expected = ip;
			auto w_dns = () @trusted { return resolveHost(ip, AF_UNSPEC, true); } ();
			auto no_dns = () @trusted { return resolveHost(ip, AF_UNSPEC, false); } ();
			assert(no_dns == w_dns);
			auto res = no_dns.toAddressString();
			assert(res == expected,
				   "IP "~ip~" yielded wrong string representation: "~res~", expected: "~expected);
		}
		test("1.2.3.4");
		test("102:304:506:708:90a:b0c:d0e:f10");
		test("1:0:1::1");
		test("1::1:0:0:1");
		test("::1");
		test("::2");
		test("::0.0.0.1", "::1");
		test("::0.0.0.2", "::2");
		test("::ffff:0.0.0.1");
		test("::ffff:0.0.0.2");
		test("2001:db8::1:0:0:1");
		test("2001:db8:0:1::");
		test("2001:db8::");
		test("::1:1", "::0.1.0.1");
		test("::ffff:0:1", "::ffff:0.0.0.1");
		test("::ffff:1", "::255.255.0.1");
	}
}

private void writeV4(scope void delegate(const(char)[]) @safe sink, const scope ubyte[4] ip) @trusted {
	import std.format : formattedWrite;

	// NOTE: (DMD 2.101.2) FormatSpec.writeUpToNextSpec doesn't forward 'sink' as scope
	sink.formattedWrite("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
}

private void writeV6(scope void delegate(const(char)[]) @safe sink, const scope ubyte[16] ip) @safe {
	// Preprocess:
	// Copy the input (bytewise) array into a wordwise array.
	// Find the longest run of 0x00's in ip[] for :: shorthanding.

	ushort[8] native = void;
	static struct ZeroesSegment { byte base = -1; byte len; }
	ZeroesSegment best, cur;

	for(ubyte i=0; i<16; i+=2)
	{
		const ubyte[2] dummy = ip[i .. i+2];
		const ubyte d = i/2;
		native[d] = bigEndianToNative!ushort(dummy);

		if(native[d] == 0)
		{
			if(cur.base == -1) // found first zero segment
			{
				cur.base = d;
				cur.len = 1;
			}
			else
				cur.len++;
		}
		else
		{
			if(cur.base != -1) // end of zeroes segment
			{
				// zeroes wasn't found before or we found longer zeroes segment
				if(best.base == -1 || cur.len > best.len)
					best = cur;

				cur.base = -1;
			}
		}

		// checks zero segments at the address end
		if(cur.base != -1)
		{
			if (best.base == -1 || cur.len > best.len)
				best = cur;
		}

		// cancel results if found segment too short
		if (best.len < 2)
			best.base = -1;
	}

	// Format the result:
	foreach(const ubyte i; 0 .. 8)
	{
		if(best.base != -1)
		{
			// Are we inside the best run of 0x00's?
			if(i >= best.base && i < best.base + best.len)
			{
				// We should sink only one :: for zeroes segment of any size
				if(i == best.base || i == 7) // ...or is a trailing run of 0x00's
					sink(":"); // another one ":" will be added as delimiter

				continue;
			}
		}

		if(i > 0) sink(":");

		// Special case for encapsulated IPv4
		if(i == 6 && best.base == 0)
		{
			if(
				best.len == 6 || // ::xxx.xxx.xxx.xxx
				(best.len == 5 && native[5] == 0xffff) // ::ffff:xxx.xxx.xxx.xxx
			)
			{
				sink.writeV4(ip[12 .. 16]);
				break;
			}
		}

		import std.format : formattedWrite;
		() @trusted { sink.formattedWrite("%x", native[i]); } ();
	}
}

/**
	Represents a single TCP connection.
*/
struct TCPConnection {
	@safe:

	import core.time : seconds;
	import vibe.internal.array : BatchBuffer;
	//static assert(isConnectionStream!TCPConnection);

	static struct Context {
		BatchBuffer!ubyte readBuffer;
		bool tcpNoDelay = false;
		bool keepAlive = false;
		Duration readTimeout = Duration.max;
		string remoteAddressString;
		int refCount = 1;
	}

	private {
		Socket m_socket;
		Context* m_context;
	}

	private this(Socket socket, scope NetworkAddress remote_address)
	nothrow {
		import std.exception : enforce;
		m_socket = socket;
		m_context = new Context;
		m_context.remoteAddressString = remote_address.toAddressString;
		m_context.readBuffer.capacity = 4096;
	}

	this(this)
	scope nothrow {
		if (m_socket !is null)
			m_context.refCount++;
	}

	~this()
	scope nothrow {
		if (m_socket !is null && m_context) {
			if (--m_context.refCount == 0) close();
		}
	}

	@property int fd() const nothrow { return cast(int)m_socket.handle; }

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket !is null; }

	@property void tcpNoDelay(bool enabled) nothrow { 
		int32_t opt = enabled;
		try {
			m_socket.setOption(SocketOptionLevel.SOCKET, SocketOption.TCP_NODELAY, opt);
		} catch (Exception t) { assert(false, "Failed to set tcp nodelay option"); }
	}
	@property bool tcpNoDelay() const nothrow @trusted {
		int32_t result;
		try {
			(cast()m_socket).getOption(SocketOptionLevel.SOCKET, SocketOption.TCP_NODELAY, result);
		} catch (Exception t) { assert(false, "Failed to get tcp nodelay option"); }
		return result != 0; 
	}
	@property void keepAlive(bool enabled) nothrow {
		try {
			m_socket.setKeepAlive(60, 5);
		} catch(Exception t){ assert(false, "Failed to set keep alive"); }
		m_context.keepAlive = enabled;
	}
	@property bool keepAlive() const nothrow { return m_context.keepAlive; }
	@property void readTimeout(Duration duration) { m_context.readTimeout = duration; }
	@property Duration readTimeout() const nothrow { return m_context.readTimeout; }
	@property string peerAddress() const nothrow { return this.remoteAddress.toString(); }
	@property NetworkAddress localAddress() const nothrow @trusted {
		try {
			return NetworkAddress((cast()m_socket).localAddress);
		} catch(Exception t) { assert(false, "Failed to get local address"); }
	}
	@property NetworkAddress remoteAddress() const nothrow @trusted {
		try {
			return NetworkAddress((cast()m_socket).remoteAddress);
		} catch(Exception t) { assert(false, "Failed to get remote address"); }
	}
	@property bool connected()
	const nothrow {
		if (m_socket is null) return false;
		return true; // TODO: connection status, seriously?
	}
	@property bool empty() { return leastSize == 0; }

	@property ulong leastSize()
	{
		if (!m_context) return 0;

		auto res = waitForDataEx(m_context.readTimeout);
		if (res == WaitForDataStatus.timeout)
			throw new ReadTimeoutException("Read operation timed out");

		return m_context.readBuffer.length;
	}

	@property bool dataAvailableForRead() { return waitForData(0.seconds); }

	void close()
	nothrow {
		//logInfo("close %s", cast(int)m_fd);
		if (m_socket !is null) {
			m_socket.shutdown(SocketShutdown.BOTH);
			m_socket.close();
			m_socket = null;
			m_context = null;
		}
	}

	bool waitForData(Duration timeout = Duration.max)
	{
		return waitForDataEx(timeout) == WaitForDataStatus.dataAvailable;
	}

	WaitForDataStatus waitForDataEx(Duration timeout = Duration.max)
	{
		if (!m_context) return WaitForDataStatus.noMoreData;
		if (m_context.readBuffer.length > 0) return WaitForDataStatus.dataAvailable;
		auto mode = timeout <= 0.seconds ? IOMode.immediate : IOMode.once;

		bool cancelled;
		size_t nbytes;

		
		m_socket.receive(m_context.readBuffer.peekDst());
		
		logTrace("Socket %s, read %s", m_socket, nbytes);

		assert(m_context.readBuffer.length == 0);
		m_context.readBuffer.putN(nbytes);

		return m_context.readBuffer.length > 0 ? WaitForDataStatus.dataAvailable : WaitForDataStatus.noMoreData;
	}


	/** Waits asynchronously for new data to arrive.

		This function can be used to detach the `TCPConnection` from a
		running task while waiting for data, so that the associated memory
		resources are available for other operations.

		Note that `read_ready_callback` may be called from outside of a
		task, so no blocking operations may be performed. Instead, an existing
		task should be notified, or a new one started with `runTask`.

		Params:
			read_ready_callback = A callback taking a `bool` parameter that
				signals the read-readiness of the connection
			timeout = Optional timeout to limit the maximum wait time

		Returns:
			If the read readiness can be determined immediately, it will be
			returned as `WaitForDataAsyncStatus.dataAvailable` or
			`WaitForDataAsyncStatus.noModeData` and the callback will not be
			invoked. Otherwise `WaitForDataAsyncStatus.waiting` is returned
			and the callback will be invoked once the status can be
			determined or the specified timeout is reached.
	*/
	WaitForDataAsyncStatus waitForDataAsync(CALLABLE)(CALLABLE read_ready_callback, Duration timeout = Duration.max) @trusted
		if (is(typeof(() @safe { read_ready_callback(true); } ())))
	{
		pollfd fd;
		fd.fd = m_socket.handle;
		fd.events = POLLIN;
		auto res = poll(&fd, 1, 0); // quick check
		if (res > 0) {
			auto nbytes = m_socket.receive(m_context.readBuffer.peekDst());
			m_context.readBuffer.putN(nbytes);
			return WaitForDataAsyncStatus.dataAvailable;
		}
		else {
			runTask((CALLABLE callback){
				try {
					pollfd fd;
					fd.fd = m_socket.handle;
					fd.events = POLLIN;
					auto res = poll(&fd, 1, cast(int)timeout.total!"msecs");
					if (res == 0)  {
						callback(false);
					}
					else {
						auto nbytes = m_socket.receive(m_context.readBuffer.peekDst());
						m_context.readBuffer.putN(nbytes);
						callback(true);
					}
				} catch (Exception e) { assert(false, e.msg); }
			}, read_ready_callback);
		}
		return WaitForDataAsyncStatus.waiting;
	}

	const(ubyte)[] peek() { return m_context ? m_context.readBuffer.peek() : null; }

	void skip(ulong count)
	{
		import std.algorithm.comparison : min;

		m_context.readTimeout.loopWithTimeout!((remaining) {
			waitForData(remaining);
			auto n = min(count, m_context.readBuffer.length);
			m_context.readBuffer.popFrontN(n);
			count -= n;
			return count == 0;
		}, ReadTimeoutException);
	}

	size_t read(scope ubyte[] dst, IOMode mode)
	{
		mixin(tracer);
		import std.algorithm.comparison : min;
		if (!dst.length) return 0;
		if (m_context.readBuffer.length >= dst.length) {
			m_context.readBuffer.read(dst);
			return dst.length;
		}
		size_t nbytes = 0;
		m_context.readTimeout.loopWithTimeout!((remaining) {
			if (m_context.readBuffer.length == 0) {
				if (mode == IOMode.immediate || (mode == IOMode.once && nbytes > 0))
					return true;
				auto ret = waitForDataEx(remaining);
				if (ret == WaitForDataStatus.timeout) {
					// should throw ReadTimeoutException
					return false;
				} else if (ret == WaitForDataStatus.noMoreData) {
					// MayBe client/server close the connect;
					throw new Exception("Reached end of stream while reading data.");
				}
			}
			assert(m_context.readBuffer.length > 0);
			auto l = min(dst.length, m_context.readBuffer.length);
			m_context.readBuffer.read(dst[0 .. l]);
			dst = dst[l .. $];
			nbytes += l;
			return dst.length == 0;
		}, ReadTimeoutException)("Read Operation timed out.");
		return nbytes;
	}

	void read(scope ubyte[] dst) { auto r = read(dst, IOMode.all); assert(r == dst.length); }

	size_t write(scope const(ubyte)[] bytes, IOMode mode) @trusted
	{
		mixin(tracer);
		if (bytes.length == 0) return 0;

		auto res = m_socket.send(bytes);
		if (res == Socket.ERROR) {
			auto p = strerror(errno);
			throw new Exception(cast(string)p[0..strlen(p)]);
		}
		return res;
	}

	void write(scope const(ubyte)[] bytes) { auto r = write(bytes, IOMode.all); assert(r == bytes.length); }
	void write(scope const(char)[] bytes) { write(cast(const(ubyte)[])bytes); }
	void write(InputStream stream) { write(stream, 0); }

	void flush() {
		mixin(tracer);
	}
	void finalize() {}
	void write(InputStream)(InputStream stream, ulong nbytes = 0) if (isInputStream!InputStream) { writeDefault(stream, nbytes); }

	private void writeDefault(InputStream)(InputStream stream, ulong nbytes = 0)
		if (isInputStream!InputStream)
	{
		import std.algorithm.comparison : min;
		import vibe.container.internal.utilallocator : theAllocator, makeArray, dispose;

		scope buffer = () @trusted { return cast(ubyte[]) theAllocator.allocate(64*1024); }();
		scope (exit) () @trusted { theAllocator.dispose(buffer); }();

		//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
		if( nbytes == 0 ){
			while( !stream.empty ){
				size_t chunk = min(stream.leastSize, buffer.length);
				assert(chunk > 0, "leastSize returned zero for non-empty stream.");
				//logTrace("read pipe chunk %d", chunk);
				stream.read(buffer[0 .. chunk]);
				write(buffer[0 .. chunk]);
			}
		} else {
			while( nbytes > 0 ){
				size_t chunk = min(nbytes, buffer.length);
				//logTrace("read pipe chunk %d", chunk);
				stream.read(buffer[0 .. chunk]);
				write(buffer[0 .. chunk]);
				nbytes -= chunk;
			}
		}
	}
}

/** Represents possible return values for
	TCPConnection.waitForDataAsync.
*/
enum WaitForDataAsyncStatus {
	noMoreData,
	dataAvailable,
	waiting,
}

enum WaitForDataStatus {
	dataAvailable,
	noMoreData,
	timeout
}

unittest { // test compilation of callback with scoped destruction
	static struct CB {
		~this() {}
		this(this) {}
		void opCall(bool) {}
	}

	void test() {
		TCPConnection c;
		CB cb;
		c.waitForDataAsync(cb);
	}
}


mixin validateConnectionStream!TCPConnection;

private void loopWithTimeout(alias LoopBody, ExceptionType = Exception)(Duration timeout,
	immutable string timeoutMsg = "Operation timed out.")
{
	import core.time : seconds, MonoTime;

	MonoTime now;
	if (timeout != Duration.max)
		now = MonoTime.currTime();

	do {
		if (LoopBody(timeout))
			return;

		if (timeout != Duration.max) {
			auto prev = now;
			now = MonoTime.currTime();
			if (now > prev) timeout -= now - prev;
		}
	} while (timeout > 0.seconds);

	throw new ExceptionType(timeoutMsg);
}


/**
	Represents a listening TCP socket.
*/
struct TCPListener {
	// FIXME: copying may lead to dangling FDs - this somehow needs to employ reference counting without breaking
	//        the previous behavior of keeping the socket alive when the listener isn't stored. At the same time,
	//        stopListening() needs to keep working.
	private {
		Socket m_socket;
	}

	this(Socket socket)
	{
		m_socket = socket;
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket !is null; }

	/// The local address at which TCP connections are accepted.
	@property NetworkAddress bindAddress()
	{
		return NetworkAddress(m_socket.localAddress);;
	}

	/// Stops listening and closes the socket.
	void stopListening()
	{
		if (m_socket !is null) {
			m_socket.close();
			m_socket = null;
		}
	}
}

/+
/**
	Represents a bound and possibly 'connected' UDP socket.
*/
struct UDPConnection {
	static struct Context {
		bool canBroadcast;
	}

	private {
		DatagramSocketFD m_socket;
		Context* m_context;
	}

	private this(ref NetworkAddress bind_address, UDPListenOptions options)
	{
		DatagramCreateOptions copts;
		if (options & UDPListenOptions.reuseAddress) copts |= DatagramCreateOptions.reuseAddress;
		if (options & UDPListenOptions.reusePort) copts |= DatagramCreateOptions.reusePort;

		scope baddr = new RefAddress(bind_address.sockAddr, bind_address.sockAddrLen);
		m_socket = eventDriver.sockets.createDatagramSocket(baddr, null, copts);
		enforce(m_socket != DatagramSocketFD.invalid, "Failed to create datagram socket.");
		m_context = () @trusted { return &eventDriver.sockets.userData!Context(m_socket); } ();
		m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
	}


	this(this)
	scope nothrow {
		if (m_socket != DatagramSocketFD.invalid)
			eventDriver.sockets.addRef(m_socket);
	}

	~this()
	scope nothrow {
		if (m_socket != DatagramSocketFD.invalid)
			releaseHandle!"sockets"(m_socket, m_context.driver);
	}

	@property int fd() const nothrow { return cast(int)m_socket; }

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket != DatagramSocketFD.invalid; }

	/** Returns the address to which the UDP socket is bound.
	*/
	@property string bindAddress() const { return localAddress.toString(); }

	/** Determines if the socket is allowed to send to broadcast addresses.
	*/
	@property bool canBroadcast() const { return m_context.canBroadcast; }
	/// ditto
	@property void canBroadcast(bool val) { enforce(eventDriver.sockets.setBroadcast(m_socket, val), "Failed to set UDP broadcast flag."); m_context.canBroadcast = val; }

	/// The local/bind address of the underlying socket.
	@property NetworkAddress localAddress() const nothrow {
		NetworkAddress naddr;
		scope addr = new RefAddress(naddr.sockAddr, naddr.sockAddrMaxLen);
		try {
			enforce(eventDriver.sockets.getLocalAddress(m_socket, addr), "Failed to query socket address.");
		} catch (Exception e) { logWarn("Failed to get local address for TCP connection: %s", e.msg); }
		return naddr;
	}

	/** Set IP multicast loopback mode.

		This is on by default. All packets send will also loopback if enabled.
		Useful if more than one application is running on same host and both need each other's packets.
	*/
	@property void multicastLoopback(bool loop)
	{
		enforce(eventDriver.sockets.setOption(m_socket, DatagramSocketOption.multicastLoopback, loop),
			"Failed to set multicast loopback mode.");
	}

	/** Become a member of an IP multicast group.

		The multiaddr parameter should be in the range 239.0.0.0-239.255.255.255.
		See https://www.iana.org/assignments/multicast-addresses/multicast-addresses.xml#multicast-addresses-12
		and https://www.iana.org/assignments/ipv6-multicast-addresses/ipv6-multicast-addresses.xhtml
	*/
	void addMembership(ref NetworkAddress multiaddr, uint interface_index = 0)
	{
		scope addr = new RefAddress(multiaddr.sockAddr, multiaddr.sockAddrMaxLen);
		enforce(eventDriver.sockets.joinMulticastGroup(m_socket, addr, interface_index),
			"Failed to add multicast membership.");
	}

	/** Stops listening for datagrams and frees all resources.
	*/
	void close()
	{
		if (m_socket != DatagramSocketFD.invalid) {
			releaseHandle!"sockets"(m_socket, m_context.driver);
			m_socket = DatagramSocketFD.init;
			m_context = null;
		}
	}

	/** Locks the UDP connection to a certain peer.

		Once connected, the UDPConnection can only communicate with the specified peer.
		Otherwise communication with any reachable peer is possible.
	*/
	void connect(string host, ushort port)
	{
		auto address = resolveHost(host);
		address.port = port;
		connect(address);
	}
	/// ditto
	void connect(NetworkAddress address)
	{
		scope addr = new RefAddress(address.sockAddr, address.sockAddrLen);
		eventDriver.sockets.setTargetAddress(m_socket, addr);
	}

	/** Sends a single packet.

		If peer_address is given, the packet is send to that address. Otherwise the packet
		will be sent to the address specified by a call to connect().
	*/
	void send(scope const(ubyte)[] data, scope const NetworkAddress* peer_address = null)
	{
		scope addrc = new RefAddress;
		if (peer_address)
			addrc.set(() @trusted { return (cast(NetworkAddress*)peer_address).sockAddr; } (), peer_address.sockAddrLen);

		IOStatus status;
		size_t nbytes;
		bool cancelled;

		alias waitable = Waitable!(DatagramIOCallback,
			cb => eventDriver.sockets.send(m_socket, () @trusted { return data; } (),
				IOMode.once, peer_address ? () @trusted { return addrc; } () : null, cb),
			(cb) { cancelled = true; eventDriver.sockets.cancelSend(m_socket); },
			(DatagramSocketFD, IOStatus status_, size_t nbytes_, scope RefAddress addr)
			{
				status = status_;
				nbytes = nbytes_;
			}
		);

		asyncAwaitAny!(true, waitable);

		enforce(!cancelled && status == IOStatus.ok, "Failed to send packet.");
		enforce(nbytes == data.length, "Packet was only sent partially.");
	}

	/** Receives a single packet.

		If a buffer is given, it must be large enough to hold the full packet.

		The timeout overload will throw an Exception if no data arrives before the
		specified duration has elapsed.
	*/
	ubyte[] recv(return scope ubyte[] buf = null, scope NetworkAddress* peer_address = null)
	{
		return recv(Duration.max, buf, peer_address);
	}
	/// ditto
	ubyte[] recv(Duration timeout, return scope ubyte[] buf = null, scope NetworkAddress* peer_address = null)
	{
		import std.socket : Address;
		if (buf.length == 0) buf = new ubyte[65536];

		IOStatus status;
		size_t nbytes;
		bool cancelled;

		alias waitable = Waitable!(DatagramIOCallback,
			cb => eventDriver.sockets.receive(m_socket, () @trusted { return buf; } (), IOMode.once, cb),
			(cb) { cancelled = true; eventDriver.sockets.cancelReceive(m_socket); },
			(DatagramSocketFD, IOStatus status_, size_t nbytes_, scope RefAddress addr)
			{
				status = status_;
				nbytes = nbytes_;
				if (status_ == IOStatus.ok && peer_address) {
					try *peer_address = NetworkAddress(addr);
					catch (Exception e) logWarn("Failed to store datagram source address: %s", e.msg);
				}
			}
		);

		asyncAwaitAny!(true, waitable)(timeout);
		enforce(!cancelled, "Receive timeout.");
		enforce(status == IOStatus.ok, "Failed to receive packet.");
		return buf[0 .. nbytes];
	}
}
+/

/**
	Flags to control the behavior of listenTCP.
*/
enum TCPListenOptions {
	/// Don't enable any particular option
	none = 0,
	/// Deprecated: causes incoming connections to be distributed across the thread pool
	distribute = 1<<0,
	/// Disables automatic closing of the connection when the connection callback exits
	disableAutoClose = 1<<1,
	/** Enable port reuse on linux kernel version >=3.9, do nothing on other OS
		Does not affect libasync driver because it is always enabled by libasync.
	*/
	reusePort = 1<<2,
	/// Enable address reuse
	reuseAddress = 1<<3,
	/// Enable IP transparent socket option
	/// Does nothing on other OS than Linux
	ipTransparent = 1<<4,
	///
	defaults = reuseAddress
}


/** Flags to control the behavior of `listenUDP`
*/
enum UDPListenOptions {
	/// No options
	none = 0,
	/// Enable address reuse
	reuseAddress = 1 << 0,
	/// Enable port reuse
	reusePort = 1 << 1
}

private pure nothrow {
	import std.bitmanip;

	ushort ntoh(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}

	ushort hton(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}
}

private enum tracer = "";


/// Thrown by TCPConnection read-alike operations when timeout is reached.
class ReadTimeoutException: Exception
{
	@safe pure nothrow @nogc:
	this(string message, Throwable next, string file =__FILE__, size_t line = __LINE__)
	{
		super(message, next, file, line);
	}

    this(string message, string file =__FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(message, file, line, next);
	}
}


// check whether the given name is not a valid host name, but may instead
// be a valid IP address. This is used as a quick check to avoid
// unnecessary address parsing or DNS queries
private bool isMaybeIPAddress(in char[] name)
{
	import std.algorithm.searching : all, canFind;
	import std.ascii : isDigit;

	// could be an IPv6 address, but ':' is invalid in host names
	if (name.canFind(':')) return true;

	// an IPv4 address is at least 7 characters (0.0.0.0)
	if (name.length < 7) return false;

	// no valid TLD consists of only digits
	return name.canFind('.') && name.all!(ch => ch.isDigit || ch == '.');
}

unittest {
	assert(isMaybeIPAddress("0.0.0.0"));
	assert(isMaybeIPAddress("::1"));
	assert(isMaybeIPAddress("aabb::1f"));
	assert(!isMaybeIPAddress("example.com"));
	assert(!isMaybeIPAddress("12.com"));
	assert(!isMaybeIPAddress("1.1.1.t12"));
}
