module vibe.core.drivers.unet.network;

import vibe.core.drivers.unet.ip;
import vibe.core.drivers.unet.ethernet;
import vibe.core.drivers.unet.udp;
import core.sys.posix.arpa.inet;
import vibe.core.drivers.utils;
import std.exception;
import std.socket;
debug import std.stdio;
import vibe.core.net;
import std.string;
import std.conv;
import vibe.core.drivers.unet.utils;

enum ubyte UDP_PROTOCOL = 0x11;


ip_v4 parseIpDot(string address){
	uint ip;
	size_t idx;
	for(int i; i<4 && address.length>0; i++){
		idx = i<3? address.indexOf('.') : address.length;
		uint part = to!uint(address[0 .. idx]);
		ip |= part<<(i*8);
		if(i<3) address = address[(idx + 1) .. $];
	}
	return ip_v4(d_ntohl(ip));
}

unittest{
	ip_v4 ip = parseIpDot("1.2.3.4");
	assert(ip.ip==resolveHost("1.2.3.4", AF_INET, false).sockAddrInet4().sin_addr.s_addr);
}

mac_type resolveMacByArp(NetDev[] network, ip_v4 ip){
	foreach(net; network){
		if( ip in net.arp_table ) 
			return net.arp_table[ip];
	}
	return NO_MAC;
}




struct NetDev{
	string name;
	mac_type mac;
	ip_v4 ip;
	ip_v6 ip6;
	string hostname;
	
	mac_type gateway_mac;
	ip_v4 gateway_ip;
	ip_v4 net_mask;
	mac_type[ip_v4] arp_table;
	
	this(ip_v4 gateway_ip, ip_v4 net_mask){
		this.net_mask = net_mask;
		this.gateway_ip = gateway_ip;
	}
	this(ip_v4 ip, ip_v4 gateway_ip, ip_v4 net_mask){
		this.ip = ip;
		this.net_mask = net_mask;
		this.gateway_ip = gateway_ip;
	}	
	bool is_ip_local(ip_v4 ip){
		auto tmp = gateway_ip.ip & net_mask.ip;
		return ((ip.ip ^ tmp) & net_mask.ip) == 0;
	}
	
	unittest{
		auto n = NetDev();
		n.net_mask = ip_v4(0x00FFFFFF);
		n.gateway_ip = ip_v4(0x0102000A);
		assert(n.is_ip_local(ip_v4(0x0102000A)));
		assert(n.is_ip_local(ip_v4(0x0802000A)));
		assert(!n.is_ip_local(ip_v4(0x0802000B)));
	}
}


interface NetworkConf{
	NetDev[] getConfig();
}

interface IpNetwork(uint UDP_RX_QUEUE_MAX_SIZE, ushort UDP_PACKET_MAX_SIZE){
	ubyte[] getPayloadUdp(ubyte[] buffer);
	bool routePacket(ubyte *data, uint len);
	void registerUdpRxQueue(ip_v4 address, ushort port, ref UdpRxQueue!(UDP_RX_QUEUE_MAX_SIZE, UDP_PACKET_MAX_SIZE) queue);
	ubyte[] fillUdpPacket(ubyte[] buffer, size_t payload_len, ip_v4 src, ushort src_port, ip_v4 dest, ushort dst_port);
}





class DefaultIpNetwork(uint UDP_RX_QUEUE_MAX_SIZE, ushort UDP_PACKET_MAX_SIZE): IpNetwork!(UDP_RX_QUEUE_MAX_SIZE, UDP_PACKET_MAX_SIZE){
	private{
		NetDev[] network;
		alias UdpRxQueue!(UDP_RX_QUEUE_MAX_SIZE, UDP_PACKET_MAX_SIZE)* QUEUE_PTR;
		alias QUEUE_PTR[ushort] ports_map;
		ports_map[ip_v4] addresses_map;

		mac_type myMac;
		ip_v4 myIp4;


	}
	enum MultiCastNet = NetDev(parseIpDot("224.0.0.0"), ip_v4(uint.max));
	enum BroadCastNet = NetDev(parseIpDot("255.255.255.255"), ip_v4(uint.max));
	enum LocalhostNet = NetDev(parseIpDot("127.0.0.1"), parseIpDot("127.0.0.0"), parseIpDot("255.0.0.0"));
	unittest{
		assert(LocalhostNet.is_ip_local(parseIpDot("127.0.0.1")));
		assert(!LocalhostNet.is_ip_local(parseIpDot("17.0.0.1")));
		assert(!LocalhostNet.is_ip_local(parseIpDot("10.0.2.129")));
	}

	this(NetDev[] network, string dev){
		this.network = network;
		foreach(c; network){
			//debug writefln("check %s==%s for mac: %s; rs: %s", c.name, dev, c.mac, c.name==dev);
			if(("netmap:"~c.name)==dev){
				debug writefln("my mac: %(%02x %), ip4: 0x%08x", c.mac, c.ip.ip);
				myMac = c.mac;
				myIp4 = c.ip;
				break;
			}
		}
	}

	override void registerUdpRxQueue(ip_v4 address, ushort port, ref UdpRxQueue!(UDP_RX_QUEUE_MAX_SIZE, UDP_PACKET_MAX_SIZE) queue){
		ports_map map;
		if(address in addresses_map){
			map = addresses_map[address];
		} else if (address == ZERO_IP){
			map = addresses_map[ZERO_IP];
		} else{
			addresses_map[address] = map;
		}
		socketEnforce(port !in map, "Error enabling socket address reuse on listening socket");
		addresses_map[address][port] = &queue;
	}



	override ubyte[] getPayloadUdp(ubyte[] buffer){
		return buffer[(EthernetPacket.sizeof + Ip4Packet.sizeof + UdpIp4Packet.sizeof) .. $];
	}
	
	override ubyte[] fillUdpPacket(ubyte[] buffer, size_t _payload_len, ip_v4 src, ushort src_port, ip_v4 dest, ushort dst_port){
		assert(_payload_len<=ushort.max);

		ushort payload_len = cast(ushort)_payload_len;
		mac_type dest_mac, src_mac;
		NetDev *cur;
		//todo support: 0.0.0.0 as source, multicat, broadcast, ...
		foreach(NetDev dev; network){
			if(dev.is_ip_local(dest) && !LocalhostNet.is_ip_local(dest)){
				import std.exception;
				import std.conv;
				/*debug{ 
					import std.stdio;writefln("%x %s", dest.ip, LocalhostNet.is_ip_local(dest));
					foreach(key, val; dev.arp_table)
						writefln("\t%x : %s", key.ip, val);

				}*/
				cur = &dev;
				if(dest==dev.ip){
					dest_mac = dev.mac;

				}else{
					enforce(dest in dev.arp_table, "dest not in dev.arp_table: " ~ dev.name ~" : "~to!string(dest) ~ "/" ~ to!string(dev.arp_table));
					dest_mac = dev.arp_table[dest];
				}
			}
			if(dev.ip.ip == src.ip){
				//debug writefln("dev.ip == src");
				src_mac = dev.mac;
				cur = &dev;
			}//else debug writefln("dev.ip(%x) != src(%x)", dev.ip.ip, src.ip);
		}
		if(dest_mac == NO_MAC && cur!=null){
			dest_mac = cur.gateway_mac;
		}
		if(src.ip == 0 && cur !is null){
			src_mac = cur.mac;
			src = cur.ip;
		} else{
			src = LocalhostNet.ip;
		}
		
		EthernetPacket *pck = cast(EthernetPacket*)buffer.ptr;
		
		pck.src = src_mac;
		pck.dest = dest_mac;
		pck.type = IP;
		ubyte[] ip_raw = buffer[EthernetPacket.sizeof .. $];
		Ip4Packet* ip = cast(Ip4Packet*)ip_raw;
		static assert(Ip4Packet.sizeof==20);
		ip.ip_version = 0x45; //version 4 and header length 20 
		ip.services_field = 0;
		ip.total_length = htons(cast(ushort)(payload_len + 20 + 8));
		ip.identification = htons(0x32cb);//?todo?
		//ip.flags = ; //don't fragment
		ip.fragment_offset = htons(0x4000);
		ip.time_to_live = 0x40;
		ip.protocol = UDP_PROTOCOL;
		ip.source = src.ip;
		ip.dest = dest.ip;
		ip.header_checksum = 0;
		ip.header_checksum = htons(checksum_head_ip4(cast(ubyte*)ip, 20));
		
		ubyte[] udp_raw = ip_raw[Ip4Packet.sizeof .. $];
		UdpIp4Packet* udp = cast(UdpIp4Packet*)udp_raw;
		static assert(UdpIp4Packet.sizeof==8);
		udp.dst_port = htons(dst_port);
		udp.src_port = htons(src_port);
		udp.length = htons(cast(ushort)(UdpIp4Packet.sizeof + payload_len));
		ubyte[] data = udp_raw[UdpIp4Packet.sizeof .. $];
		enforce(data.length >= payload_len);
		udp.checksum = 0;//htons(0x10);//htons(0x1bcd);//todo? UDP checksum is optional
		return buffer[0 .. (EthernetPacket.sizeof + Ip4Packet.sizeof + UdpIp4Packet.sizeof + payload_len)];
	}

	override bool routePacket(ubyte *data, uint len){
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
		if(myIp4 !in addresses_map){
			return false;
		}
		auto map = addresses_map[myIp4];

		data = data + 4*(ipPck.header_length&0x0f);
		UdpIp4Packet* udpPck = cast(UdpIp4Packet*)data;
		auto dest_port = d_ntohs(udpPck.dst_port);
		if(dest_port !in map){
			return false;
		}
		auto queue = map[dest_port];

		data = data + UdpIp4Packet.sizeof;
		queue.add(data, d_ntohs(udpPck.length));
		//debug writefln("udp payload: %(%02x %)", data[0 .. d_ntohs(udpPck.length)]);
		/*
		ubyte[] payload =[];
		payload.length = d_ntohs(udpPck.length);
		memcpy(cast(void*)data, cast(void*)payload.ptr, payload.length);
		debug writefln("udp payload: %(%02x %)", payload);*/
		return true;
	}
	
}


unittest{
	NetDev dev = NetDev();
	dev.name = "test";
	dev.mac = [0,1,2,3,4,1];
	dev.ip = parseIpDot("10.0.2.30");
	dev.hostname = "test.host";
	
	dev.gateway_mac = [0,1,2,3,4,2];
	dev.gateway_ip = parseIpDot("10.0.2.1");
	dev.net_mask = parseIpDot("10.0.2.0"); 
	auto localIp = parseIpDot("10.0.2.2");
	auto globalIp = parseIpDot("8.8.8.8");
	dev.arp_table[localIp] = [0,1,2,3,4,3];
	
	auto net = new DefaultIpNetwork([dev]);
	ubyte[] buffer = new ubyte[2048];
	ubyte[] payload = new ubyte[1024];
	net.fillUdpPacket(buffer, payload.length, dev.ip, 2000, localIp, 8000);
	assert(buffer[0 .. 6] == dev.arp_table[localIp]);
	buffer = buffer[6 .. $];
	assert(buffer[0 .. 6] == dev.mac);
	buffer = buffer[6 .. $];
	assert(*(cast(ushort*)(buffer[0 .. 2].ptr)) == htons(0x0800));
	buffer = buffer[2 .. $];
	assert(buffer[0] == 0x45);
	buffer = buffer[1 .. $];
	
	buffer[] = 0;
	net.fillUdpPacket(buffer, payload.length, dev.ip, 2000, globalIp, 8000);
	assert(buffer[0 .. 6] == dev.gateway_mac);
}


version(LittleEndian){

	/**
	 * Convert an u16_t from host- to network byte order.
	 *
	 * @param n u16_t in host byte order
	 * @return n in network byte order
	 */
	ushort d_htons(ushort n)
	{
		return ((n & 0xff) << 8) | ((n & 0xff00) >> 8);
	}

	/**
	 * Convert an u16_t from network- to host byte order.
	 *
	 * @param n u16_t in network byte order
	 * @return n in host byte order
	 */
	ushort	d_ntohs(ushort n)
	{
		return d_htons(n);
	}

	/**
	 * Convert an u32_t from host- to network byte order.
	 *
	 * @param n u32_t in host byte order
	 * @return n in network byte order
	 */
	uint d_htonl(uint n)
	{
		return ((n & 0xff) << 24) |
			((n & 0xff00) << 8) |
				((n & 0xff0000UL) >> 8) |
				((n & 0xff000000UL) >> 24);
	}

	/**
	 * Convert an u32_t from network- to host byte order.
	 *
	 * @param n u32_t in network byte order
	 * @return n in host byte order
	 */
	uint d_ntohl(uint n)
	{
		return d_htonl(n);
	}

}