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
	import core.stdc.string;
	import vibe.core.drivers.pfq.network;
	import vibe.core.drivers.pfq.linux_net;
import core.thread;
import vibe.core.drivers.pfq.ip;
import std.exception;


	bool pfq_active = false;
	IpNetwork ipNetwork;

	pfq_t *p;
	pfq_iterator_t it, it_e;
	pfq_net_queue nq;
	NetworkAddress[] sockets;

	//--------------------
	//
	enum dev = "eth0";
	enum udp_tx_batch_size = 1;
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

		NetworkConf conf = new LinuxNetworkConf();
		ipNetwork = new DefaultIpNetwork(conf.getConfig());
	}

	class PFQDriver : Libevent2Driver {
		private{
			DriverCore core;
		}
		this(DriverCore core)
		{
			super(core);
			this.core = core;
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
			NetworkAddress bind_address;
			NetworkAddress dest_address;

			bool m_canBroadcast = false;
			ubyte[] buffer = new ubyte[2048];
		}


		this(ushort port, string address = "0.0.0.0"){

			import std.range;
			//todo what about situation: 0.0.0.0:port & 192.168.1.1:port
			bind_address = resolveHost(address, AF_INET, false);
			bind_address.port = port;
			auto tmpSockets = sockets.assumeSorted!cmpNetworkAddress;
			socketEnforce(!tmpSockets.contains(bind_address), "Error enabling socket address reuse on listening socket");
			sockets ~= bind_address;
			sockets.sort!((a,b) => a.toAddressString>b.toAddressString);
		}
		/** Returns the address to which the UDP socket is bound.
	    */
		@property string bindAddress() const{
			return bind_address.toAddressString;
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
			return bind_address;
		}
		
		/** Locks the UDP connection to a certain peer.

		Once connected, the UDPConnection can only communicate with the specified peer.
		Otherwise communication with any reachable peer is possible.
	    */
		void connect(string host, ushort port){
			auto address = resolveHost(host, AF_INET, false);
			address.port = port;
			connect(address);
		}
		/// ditto
		void connect(NetworkAddress address){
			dest_address = address;
		}
		
		/** Sends a single packet.

		If peer_address is given, the packet is send to that address. Otherwise the packet
		will be sent to the address specified by a call to connect().
	    */
		void send(in ubyte[] data, in NetworkAddress* peer_address = null){
			auto tmp = ipNetwork.getPayloadUdp(buffer);
			memcpy(tmp.ptr, data.ptr, data.length); 
			auto dest = peer_address is null? cast(const(NetworkAddress*))&dest_address: peer_address;
			ubyte[] pck = ipNetwork.fillUdpPacket(buffer, data.length, 
			                                      ip_v4(bind_address.sockAddrInet4.sin_addr.s_addr, true), bind_address.port, 
			                                      ip_v4(dest.sockAddrInet4.sin_addr.s_addr, true), dest.port);
			int rs;
			debug foreach(b; pck) writef("%x ", b);
			do{
				rs = pfq_send(p, pck.ptr, pck.length);//udp_tx_batch_size
				Thread.yield();
			}while(rs==0);
			debug{
				char* x = pfq_error(p);
				if(x !is null) writefln("pfq_send: %s", to!string(x)); else writefln("pfq_send: ok");
			}
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

