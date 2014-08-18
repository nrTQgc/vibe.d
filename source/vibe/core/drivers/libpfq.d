module vibe.core.drivers.libpfq;

version(VibeLibeventDriver) version(PFQDriver)
{

	import vibe.core.drivers.libevent2;
	import vibe.core.driver;
	debug import std.stdio;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;


	class PFQDriver : Libevent2Driver {
		this(DriverCore core)
		{
			super(core);
			debug writeln("PFQDriver");
		}

		override UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0"){
			debug writeln("PFQDriver - listenUDP");
			return super.listenUDP(port, bind_address);
		}

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
		void connect(string host, ushort port);
		/// ditto
		void connect(NetworkAddress address);
		
		/** Sends a single packet.

		If peer_address is given, the packet is send to that address. Otherwise the packet
		will be sent to the address specified by a call to connect().
	    */
		void send(in ubyte[] data, in NetworkAddress* peer_address = null);
		
		/** Receives a single packet.

		If a buffer is given, it must be large enough to hold the full packet.

		The timeout overload will throw an Exception if no data arrives before the
		specified duration has elapsed.
	    */
		ubyte[] recv(ubyte[] buf = null, NetworkAddress* peer_address = null);
		/// ditto
		ubyte[] recv(Duration timeout, ubyte[] buf = null, NetworkAddress* peer_address = null);
	}
	

}

