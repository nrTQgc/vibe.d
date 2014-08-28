module vibe.core.drivers.libnetmap;

version(VibeLibeventDriver) version(NetmapDriver)
{

	import vibe.core.drivers.libevent2;
	import vibe.core.driver;
	debug import std.stdio;
	import std.string;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.fcntl;
	import core.sys.posix.unistd;
	import core.sys.posix.sys.ioctl;
	import core.sys.posix.net.if_;
	import core.sys.posix.sys.mman;
	import core.time;
	import std.conv;
	import deimos.event2.bufferevent;
	import deimos.event2.dns;
	import deimos.event2.event;
	import deimos.event2.thread;
	import deimos.event2.util;
	import vibe.core.drivers.utils;
	import core.stdc.string;
	import core.thread;
	import vibe.core.drivers.unet.ip;
	import std.exception;
	import vibe.core.drivers.unet.network;
	import vibe.core.drivers.unet.linux_net;
	import vibe.core.drivers.unet.netmap;
	import vibe.core.drivers.unet.netmap_user;

	import vibe.core.drivers.unet.ethernet;
	import vibe.core.drivers.unet.ip;
	import vibe.core.drivers.unet.udp;

	nm_desc* pa;
	nm_desc* pb;
	bool zerocopy = true;
	pollfd poll_fd[2];

	bool netmap_active = false;
	IpNetwork ipNetwork;
	mac_type myMac;
	ip_v4 myIp4;
	NetworkAddress[] sockets;

	//--------------------
	//
	enum dev = "netmap:eth0";
	enum queue = 0;
	enum node = 0;
	enum burst = 1024;
	//--------------------


	version ( unittest ){
		static this(){

		}
	}else{
		static this(){

			//kernel params:
			// cat /proc/modules | grep netmap | cut -f 1 -d " " | while read module; do  echo "Module: $module";  if [ -d "/sys/module/$module/parameters" ]; then   ls /sys/module/$module/parameters/ | while read parameter; do    echo -n "Parameter: $parameter --> ";    cat /sys/module/$module/parameters/$parameter;   done;  fi;  echo; done
			static if (is(typeof(registerMemoryErrorHandler))) registerMemoryErrorHandler();

			pa = nm_open(dev.toStringz(), null, 0, null);
			if (pa is null) {
				debug writefln("cannot open %s", dev);
				return;
			}
			// XXX use a single mmap ?
			pb = nm_open((dev~"^").toStringz(), null, NM_OPEN_NO_MMAP, pa);
			if (pb == null) {
				debug writefln("cannot open(2) %s", dev);
				nm_close(pa);
				pa = null;
				return;
			}

			zerocopy = (pa.mem == pb.mem);
			debug writefln("zerocopy: %s", zerocopy);

			/* setup poll(2) variables. */
			poll_fd[0].fd = pa.fd;
			poll_fd[1].fd = pb.fd;


			netmap_active = true;
			NetworkConf conf = new LinuxNetworkConf();
			foreach(c; conf.getConfig()){
				//debug writefln("check %s==%s for mac: %s; rs: %s", c.name, dev, c.mac, c.name==dev);
				if(("netmap:"~c.name)==dev){
					debug writefln("my mac: %(%02x %), ip4: 0x%08x", c.mac, c.ip.ip);
					myMac = c.mac;
					myIp4 = c.ip;
					break;
				}
			}
			ipNetwork = new DefaultIpNetwork(conf.getConfig());

		}

		static ~this(){

			if(pa){
				nm_close(pa);
			}
			if(pb){
				nm_close(pb);
			}

		}
	}


	class NetmapDriver : Libevent2Driver {
		private{
			DriverCore core;
			bool m_exit = false;
		}
		this(DriverCore core)
		{
			super(core);
			this.core = core;
			debug writeln("NetmapDriver");
		}

		override UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0"){
			debug writefln("NetmapDriver - listenUDP, netmap: %s", netmap_active);
			return netmap_active ? new NetmapUDPConnection(core, port, bind_address) : super.listenUDP(port, bind_address);
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
			if(netmap_active) processNetQueue();
			//todo what about block???
			return super.runEventLoopOnce();
		}
		
		/** Processes all outstanding events if any, does not block.
		*/
		override bool processEvents(){
			if (m_exit) {
				m_exit = false;
			}else if(netmap_active){
				processNetQueue();
			}
			return super.processEvents();
		}
		
		/** Exits any running event loop.
		*/
		override void exitEventLoop(){
			m_exit = true;
			super.exitEventLoop();
		}

		protected{
			int processNetQueue(){
				int n0, n1, ret;
				poll_fd[0].events = poll_fd[1].events = 0;
				poll_fd[0].revents = poll_fd[1].revents = 0;
				n0 = pkt_queued(pa, 0);
				n1 = pkt_queued(pb, 0);
				if (n0)
					poll_fd[1].events |= POLLOUT;
				else
					poll_fd[0].events |= POLLIN;
				if (n1)
					poll_fd[0].events |= POLLOUT;
				else
					poll_fd[1].events |= POLLIN;
				ret = poll(poll_fd.ptr, 2, 2500);
				/*
				debug writefln("poll %s [0] ev %x %x rx %s@%s tx %d, [1] ev %x %x rx %s@%s tx %s",
						ret <= 0 ? "timeout" : "ok",
						poll_fd[0].events, poll_fd[0].revents,
						pkt_queued(pa, 0), NETMAP_RXRING(pa.nifp, pa.cur_rx_ring).cur,
						pkt_queued(pa, 1), poll_fd[1].events,
						poll_fd[1].revents,	pkt_queued(pb, 0),
						NETMAP_RXRING(pb.nifp, pb.cur_rx_ring).cur,
						pkt_queued(pb, 1));
						*/
				if (ret < 0)
					return 0;
				if (poll_fd[0].revents & POLLERR) {
					netmap_ring *rx = NETMAP_RXRING(pa.nifp, pa.cur_rx_ring);
					debug writefln("error on fd0, rx [%s,%s,%s)", rx.head, rx.cur, rx.tail);
				}
				if (poll_fd[1].revents & POLLERR) {
					netmap_ring *rx = NETMAP_RXRING(pb.nifp, pb.cur_rx_ring);
					debug writefln("error on fd1, rx [%d,%d,%d)", rx.head, rx.cur, rx.tail);
				}
				if (poll_fd[0].revents & POLLOUT) {
					move(pb, pa, burst);
					// XXX we don't need the ioctl */
					// ioctl(me[0].fd, NIOCTXSYNC, NULL);
				}
				if (poll_fd[1].revents & POLLOUT) {
					move(pa, pb, burst);
					// XXX we don't need the ioctl */
					// ioctl(me[1].fd, NIOCTXSYNC, NULL);
				}
				return ret;
			}
		}
	}

	bool cmpNetworkAddress(NetworkAddress a, NetworkAddress b){
		return a.toAddressString>b.toAddressString;
	}

	/**
	 Represents a bound and possibly 'connected' UDP socket.
    */
	class NetmapUDPConnection : UDPConnection {

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

			while(send_packet(NETMAP_TXRING(pa.nifp, pa.first_tx_ring), pck)==0){
				//yield();
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
	

	/* move packts from src to destination */
	int move(nm_desc *src, nm_desc *dst, u_int limit)
	{
		netmap_ring *txring;
		netmap_ring *rxring;
		u_int m = 0, si = src.first_rx_ring, di = dst.first_tx_ring;
		string msg = (src.req.nr_ringid & NETMAP_SW_RING) ? "host->net" : "net->host";
		
		while (si <= src.last_rx_ring && di <= dst.last_tx_ring) {
			rxring = NETMAP_RXRING(src.nifp, si);
			txring = NETMAP_TXRING(dst.nifp, di);
			//ND("txring %p rxring %p", txring, rxring);
			if (nm_ring_empty(rxring)) {
				si++;
				continue;
			}
			if (nm_ring_empty(txring)) {
				di++;
				continue;
			}
			m += process_rings(rxring, txring, limit, msg);
		}
		return (m);
	}

	/*
 	* move up to 'limit' pkts from rxring to txring swapping buffers.
 	*/
	int process_rings(netmap_ring *rxring, netmap_ring *txring, u_int limit, string msg)
	{
		u_int j, k, m = 0;
		/* print a warning if any of the ring flags is set (e.g. NM_REINIT) */
		if (rxring.flags || txring.flags)
			debug writefln("warn: %s rxflags %x txflags %x", msg, rxring.flags, txring.flags);
		j = rxring.cur; /* RX */
		k = txring.cur; /* TX */
		m = nm_ring_space(rxring);
		if (m < limit)
			limit = m;
		m = nm_ring_space(txring);
		if (m < limit)
			limit = m;
		m = limit;
		//debug writefln("limit: %s", limit);
		while (limit-- > 0) {
			//ubyte *test = cast(ubyte*)rxring;
			//writefln("%(%02x %)", test[0 .. 64]);
			//test = cast(ubyte*)txring;
			//writefln("%(%02x %)", test[0 .. 64]);


			netmap_slot *rs = rxring.slot.ptr + j;
			netmap_slot *ts = txring.slot.ptr + k;
			
			/* swap packets */
			if (ts.buf_idx < 2 || rs.buf_idx < 2) {
				debug writefln("wrong index rx[%s] = %s  -> tx[%s] = %s", j, rs.buf_idx, k, ts.buf_idx);
				assert(0);
				//sleep(2);
			}
			/* copy the packet length. */
			if (rs.len > 2048) {
				debug writefln("wrong len %s rx[%s] -> tx[%s]", rs.len, j, k);
				rs.len = 0;
				continue;
			} else {// if (verbose > 1)
				//debug writefln("%s send len %s rx[%s] -> tx[%s]", msg, rs.len, j, k);
			}
			ubyte *rxbuf = NETMAP_BUF(rxring, rs.buf_idx);
			if(!routePacket(rxbuf, rs.len)){
				ts.len = rs.len;
				if (zerocopy) {
					uint32_t pkt = ts.buf_idx;
					ts.buf_idx = rs.buf_idx;
					rs.buf_idx = pkt;
					/* report the buffer change. */
					ts.flags |= NS_BUF_CHANGED;
					rs.flags |= NS_BUF_CHANGED;
				} else {
					ubyte *txbuf = NETMAP_BUF(txring, ts.buf_idx);
					nm_pkt_copy(rxbuf, txbuf, ts.len);
				}
			}
			j = nm_ring_next(rxring, j);
			k = nm_ring_next(txring, k);
		}
		rxring.head = rxring.cur = j;
		txring.head = txring.cur = k;
		//debug if (/*verbose &&*/ m > 0) writefln("%s sent %s packets to %s", msg, m, txring);
		
		return (m);
	}


	/*
 	* how many packets on this set of queues ?
 	*/
	int pkt_queued(nm_desc *d, bool tx)
	{
		u_int i, tot = 0;
		
		if (tx) {
			for (i = d.first_tx_ring; i <= d.last_tx_ring; i++) {
				tot += nm_ring_space(NETMAP_TXRING(d.nifp, i));
			}
		} else {
			for (i = d.first_rx_ring; i <= d.last_rx_ring; i++) {
				tot += nm_ring_space(NETMAP_RXRING(d.nifp, i));
			}
		}
		//debug writefln("p: %s; total: %s", d, tot);
		return tot;
	}

	bool routePacket(ubyte *data, uint len){
		EthernetPacket* ethPck = cast(EthernetPacket*)data;
		if( (/*todo broadcast: ethPck.dest!=BROADCAST_MAC &&*/ ethPck.dest!=myMac) || ethPck.type!=IP){
			//debug if (ethPck.dest!=BROADCAST_MAC) writefln("%(%02x %)", data[0 .. 32]);
			return false;
		}
		//debug writefln("eth detected: %(%02x %)", data[0 .. 32]);
		data = data + EthernetPacket.sizeof;
		Ip4Packet* ipPck = cast(Ip4Packet*)data;
		if( (ipPck.ip_version&0xf0)!=0x40 || ipPck.protocol!=UDP_PROTOCOL || ipPck.dest!=myIp4.ip /*todo broadcast: */){
			//debug writefln("%x %x %x %(%02x %)", (ipPck.ip_version&0xf0), ipPck.protocol, ipPck.dest, data[0 .. 32]);
			return false;
		}
		//debug writefln("ip detected: %(%02x %)", data[0 .. 32]);
		data = data + 4*(ipPck.header_length&0x0f);
		UdpIp4Packet* udpPck = cast(UdpIp4Packet*)data;
		if(udpPck.dst_port!=d_htons(1234)){
			return false;
		}
		data = data + UdpIp4Packet.sizeof;
		debug writefln("udp payload: %(%02x %)", data[0 .. d_ntohs(udpPck.length)]);
		/*
		ubyte[] payload =[];
		payload.length = d_ntohs(udpPck.length);
		memcpy(cast(void*)data, cast(void*)payload.ptr, payload.length);
		debug writefln("udp payload: %(%02x %)", payload);*/
		return true;
	}

	//todo use batch
	int send_packet(netmap_ring *ring, ubyte[] pkt)
	{
		uint n = nm_ring_space(ring);
		if (n < 1){
			return 0;
		}
		auto cur = ring.cur;
		netmap_slot *slot = ring.slot.ptr + cur;
		ubyte *p = NETMAP_BUF(ring, slot.buf_idx);
		//todo GC and pkt.ptr???
		slot.ptr = cast(void*)pkt.ptr;
		slot.len = cast(ushort)pkt.length;
		slot.flags &= ~NS_MOREFRAG;
		slot.flags |= NS_INDIRECT;
		slot.flags |= NS_REPORT;
		cur = nm_ring_next(ring, cur);
		ring.head = ring.cur = cur;
		return 1;
	}
}


