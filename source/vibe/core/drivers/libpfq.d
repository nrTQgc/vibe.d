module vibe.core.drivers.libpfq;

version(VibeLibeventDriver) version(PFQDriver)
{

	import vibe.core.drivers.libevent2;
	import vibe.core.driver;
	debug import std.stdio;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.time;
	import std.conv;
	import deimos.event2.bufferevent;
	import deimos.event2.dns;
	import deimos.event2.event;
	import deimos.event2.thread;
	import deimos.event2.util;
	import vibe.internal.pfq;
	import vibe.core.drivers.utils;

	bool pfq_active = false;

	pfq_t *p;
	pfq_iterator_t it, it_e;
	pfq_net_queue nq;
	NetworkAddress[] sockets;

	//--------------------
	//
	enum dev = "eth0";
	enum udp_tx_batch_size = 10;
	//--------------------

	static this(){
		p = pfq_open(64, 4096);

		if (p == null) {
			debug writefln("error: %s", pfq_error(p));
		} else if (pfq_enable(p) < 0) {
			debug writefln ("error: %s", pfq_error(p));
		} else if (pfq_bind(p, dev.ptr, Q_ANY_QUEUE) < 0) {
			debug writefln("error: %s", pfq_error(p));
		} else if (pfq_timestamp_enable(p, 1) < 0) {
			debug writefln("error: %s", pfq_error(p));
		} else{
			pfq_active = true;

			debug writefln("reading from %s...", dev);
		}
	}

	class PFQDriver : Libevent2Driver {
		this(DriverCore core)
		{
			super(core);
			debug writeln("PFQDriver");
		}

		override UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0"){
			debug writefln("PFQDriver - listenUDP, PFQ: %s", pfq_active);
			return pfq_active ? new PFQUDPConnection(port, bind_address) : super.listenUDP(port, bind_address);
		}

	}

	bool cmpNetworkAddress(NetworkAddress a, NetworkAddress b){
		return a.toAddressString>b.toAddressString;
	}

	/**
	Represents a bound and possibly 'connected' UDP socket.
    */
	class PFQUDPConnection : UDPConnection {
		private {
			NetworkAddress m_bindAddress;
			string m_bindAddressString;
			bool m_canBroadcast = false;

		}

		this(NetworkAddress bind_addr){
			import std.range;
			//todo what about situation: 0.0.0.0:port & 192.168.1.1:port
			auto tmpSockets = sockets.assumeSorted!cmpNetworkAddress;
			socketEnforce(tmpSockets.contains!cmpNetworkAddress(bind_addr), "Error enabling socket address reuse on listening socket");
			sockets ~= bind_addr;
			sockets.sort!(a.toAddressString>b.toAddressString);

			m_bindAddress = bind_addr;
			char buf[64];
			void* ptr;
			if( bind_addr.family == AF_INET ) ptr = &bind_addr.sockAddrInet4.sin_addr;
			else ptr = &bind_addr.sockAddrInet6.sin6_addr;
			evutil_inet_ntop(bind_addr.family, ptr, buf.ptr, buf.length);
			m_bindAddressString = to!string(buf.ptr);
		}
		/** Returns the address to which the UDP socket is bound.
	    */
		@property string bindAddress() const{
			return m_bindAddressString;
		}
		
		/** Determines if the socket is allowed to send to broadcast addresses.
	    */
		@property bool canBroadcast() const{
			return m_canBroadcast;
		}
		/// ditto
		@property void canBroadcast(bool val){
			m_canBroadcast = val;
		}
		
		/// The local/bind address of the underlying socket.
		@property NetworkAddress localAddress() const{
			return m_bindAddress;
		}
		
		/** Locks the UDP connection to a certain peer.

		Once connected, the UDPConnection can only communicate with the specified peer.
		Otherwise communication with any reachable peer is possible.
	    */
		void connect(string host, ushort port){
			NetworkAddress addr = m_driver.resolveHost(host, m_ctx.local_addr.family);
			addr.port = port;
			connect(addr);
		}
		/// ditto
		void connect(NetworkAddress address){
			//todo
		}
		
		/** Sends a single packet.

		If peer_address is given, the packet is send to that address. Otherwise the packet
		will be sent to the address specified by a call to connect().
	    */
		void send(in ubyte[] data, in NetworkAddress* peer_address = null){
			ubyte[] pck = [];//todo
			auto rs = pfq_send_async(p, pck.ptr, pck.length, udp_tx_batch_size);
			debug writefln("pfq_send_async: %s", rs);
		}
		
		/** Receives a single packet.

		If a buffer is given, it must be large enough to hold the full packet.

		The timeout overload will throw an Exception if no data arrives before the
		specified duration has elapsed.
	    */
		ubyte[] recv(ubyte[] buf = null, NetworkAddress* peer_address = null){
			//todo
			return [];
		}

		/// ditto
		ubyte[] recv(Duration timeout, ubyte[] buf = null, NetworkAddress* peer_address = null){
			//todo
			return [];
		}

	}
	

}

