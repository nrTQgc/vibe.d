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
	enum dev = "eth0\0";
	enum queue = 0;
	enum node = 0;
	enum udp_tx_batch_size = 1;
	//--------------------

	auto pfq_error_str(){
		return to!string(pfq_error(p));
	}

	version ( unittest ){
		static this(){

		}
	}else{
		static this(){

			//kernel params:
			// modinfo pfq
			// cat /proc/modules | grep pfq | cut -f 1 -d " " | while read module; do  echo "Module: $module";  if [ -d "/sys/module/$module/parameters" ]; then   ls /sys/module/$module/parameters/ | while read parameter; do    echo -n "Parameter: $parameter --> ";    cat /sys/module/$module/parameters/$parameter;   done;  fi;  echo; done
			static if (is(typeof(registerMemoryErrorHandler))) registerMemoryErrorHandler();

			p =  pfq_open_group(Q_CLASS_DEFAULT, Q_POLICY_GROUP_PRIVATE, 1500, 4096, 1500, 4096);//pfq_open(64, 4096);

			if (p is null) {
				debug writefln("pfq_open_ error: %s", pfq_error_str());
			} else if (pfq_enable(p) < 0) {
				debug writefln ("pfq_enable error: %s", pfq_error_str());
			} else if (pfq_bind(p, dev.ptr, Q_ANY_QUEUE) < 0) {
				debug writefln("pfq_bind error: %s", pfq_error_str());
			} else if (pfq_timestamp_enable(p, 1) < 0) {
				debug writefln("pfq_timestamp_enable error: %s", pfq_error_str());
			} else if (pfq_bind_tx(p, dev.ptr, queue) < 0) {
				debug writefln("pfq_bind_tx error: %s", pfq_error(p));
			} else if (pfq_start_tx_thread(p, node) < 0) {
				debug writefln("pfq_start_tx_thread error: %s", pfq_error_str());
			} else{
				pfq_active = true;
				debug writefln("reading from %s...", dev);
			}

			NetworkConf conf = new LinuxNetworkConf();
			ipNetwork = new DefaultIpNetwork(conf.getConfig());
		}

	}


	class PFQDriver : Libevent2Driver {
		private{
			DriverCore core;
			bool m_exit = false;

			pfq_net_queue nq;
			pfq_iterator_t it, it_e;
		}
		this(DriverCore core)
		{
			super(core);
			this.core = core;
			debug writeln("PFQDriver");
		}

		override UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0"){
			debug writefln("PFQDriver - listenUDP, PFQ: %s", pfq_active);
			return pfq_active ? new PFQUDPConnection(core, port, bind_address) : super.listenUDP(port, bind_address);
		}

		/** Starts the event loop.

		The loop will continue to run until either no more event listeners are active or until
		exitEventLoop() is called.
		*/
		override int runEventLoop(){
			int ret;
			m_exit = false;
			while (!m_exit && (ret = runEventLoopOnce()) == 0) {
			}
			return ret;
		}

		/* Processes all outstanding events, potentially blocking to wait for the first event.
		*/
		override int runEventLoopOnce(){
			processEvents();
			//todo check: what about block??
			return 0;
		}
		
		/** Processes all outstanding events if any, does not block.
		*/
		override bool processEvents(){
			if(pfq_active) processPFQQueueRx();
			super.processEvents();
			if (m_exit) {
				m_exit = false;
				return false;
			}
			return true;
		}
		
		/** Exits any running event loop.
		*/
		override void exitEventLoop(){
			m_exit = true;
			super.exitEventLoop();
		}

		protected{
			int processPFQQueueRx(){
				debug writefln("read from: %s; %s", p, nq);
				int many = pfq_read(p, &nq, 1000000);
				debug writefln("processPFQQueueRx: %s", many);
				if (many < 0) {
					throw new Exception("error: " ~ to!string(pfq_error(p)));
				}
				
				debug writefln("queue size: %s", nq.len);
				
				it = pfq_net_queue_begin(&nq);
				it_e = pfq_net_queue_end(&nq);
				
				for(; it != it_e; it = pfq_net_queue_next(&nq, it))
				{
					int x;
					
					while (!pfq_iterator_ready(&nq, it))
						core.yieldForEvent();
					
					pfq_pkt_hdr *h = pfq_iterator_header(it);
					
					debug writefln("caplen:%s len:%s ifindex:%s hw_queue:%s -> ", h.caplen, h.len, h.if_index, h.hw_queue);
					
					ubyte *buff = pfq_iterator_data(it);
				}
				return 0;
			}
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
			DriverCore core;
			NetworkAddress bind_address;
			NetworkAddress dest_address;
			uint udp_tx_batch_size = 100;
			bool m_canBroadcast = false;
			ubyte[] buffer = new ubyte[2048];
		}


		this(DriverCore _core, ushort port, string address = "0.0.0.0"){
			import std.range;

			this.core = _core;
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

		@property uint batchSize() const{ 
			return udp_tx_batch_size; 
		} 
		
		@property uint batchSize(uint value) { 
			return udp_tx_batch_size = value; 
		} 

		void flushTxThread(){
			pfq_wakeup_tx_thread(p);
		}

		string getLastPFQError(){
			auto x = pfq_error(p);
			return to!string(x);
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
			//debug foreach(b; pck) writef("%02x ", b);
			do{
				rs = pfq_send_async(p, pck.ptr, pck.length, udp_tx_batch_size);//udp_tx_batch_size
				core.yieldForEvent();
			}while(rs==0);
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

	unittest{
		NetDev dev = NetDev();
		dev.name = "test";
		dev.mac = [1,1,1,2,2,2];
		dev.ip = parseIpDot("10.0.2.129");
		dev.hostname = "test.host";
		
		dev.gateway_mac = [3,3,3,4,4,4];
		dev.gateway_ip = parseIpDot("10.0.2.1");
		dev.net_mask = parseIpDot("255.255.255.0"); 
		
		auto localIp = parseIpDot("10.0.2.129");
		dev.arp_table[localIp] = [1,1,1,2,2,2];
		
		auto net = new DefaultIpNetwork([dev]);
		ubyte[] buffer = new ubyte[2048];
		ubyte[] payload = new ubyte[500];
		
		auto tmp = net.getPayloadUdp(buffer);
		memcpy(tmp.ptr, payload.ptr, payload.length); 
		auto dest = resolveHost("10.0.2.129", AF_INET, false);
		dest.port = 1234;
		auto bind_address = dest;

		ubyte[] pck = net.fillUdpPacket(buffer, payload.length, 
		                                      ip_v4(bind_address.sockAddrInet4.sin_addr.s_addr, true), bind_address.port, 
		                                      ip_v4(dest.sockAddrInet4.sin_addr.s_addr, true), dest.port);
		foreach(b; pck) writef("%02x ", b);
	}
	


}



