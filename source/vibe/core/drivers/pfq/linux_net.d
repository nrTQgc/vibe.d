module vibe.core.drivers.pfq.linux_net;

version(linux){
	import std.socket: InternetAddress;
	import std.stdio;
	import std.exception;
	import std.array;
	import std.string;
	import std.algorithm;
	import vibe.core.drivers.pfq.lsif;
	import std.conv;
	import vibe.core.drivers.pfq.network;
	import vibe.core.drivers.pfq.ethernet;
	import vibe.core.drivers.pfq.ip;
	


	class LinuxNetworkConf : NetworkConf{
		NetDev[] getConfig(){
			NetDev[] rs;
			char            buf[8192];
			/* Get a socket handle. */
			int sck = socket(AF_INET, SOCK_DGRAM, 0);
			if(sck < 0) {
				throw new Exception("socket");
			}
			/* Query available interfaces. */
			ifconf ifc = ifconf(buf.length, buf.ptr);
			if(ioctl(sck, SIOCGIFCONF, &ifc) < 0) {
				throw new Exception("ioctl(SIOCGIFCONF)");
			}
			/* Iterate through the list of interfaces. */
			ifreq* ifr = ifc.ifc_req;
			auto nInterfaces = ifc.ifc_len / ifreq.sizeof; 
			char hostname[NI_MAXHOST];
			for(int i = 0; i < nInterfaces; i++) {
				NetDev tmp;
				ifreq* item = &ifr[i];
				tmp.name = item.ifr_name[0 .. item.ifr_name.indexOf('\0')].idup;
				/* Show the device name and IP address */
				sockaddr * addr = &(item.ifr_addr);
				socklen_t salen;
				switch(addr.sa_family) {
					case AF_INET:
						salen = sockaddr_in.sizeof;
						memcpy(&tmp.ip, &(cast(sockaddr_in *)addr).sin_addr, salen);
						break;
					case AF_INET6:
						salen = sockaddr_in6.sizeof;
						memcpy(tmp.ip6.ptr, &(cast(sockaddr_in6 *)addr).sin6_addr, salen);
						break;
					default:
						salen = 0;
				}
				/* the call to get the mac address changes what is stored in the
		           item, meaning that we need to determine the hostname now */
				hostname[] = 0;
				getnameinfo(addr, salen, hostname.ptr, hostname.length, null, 0, NI_NAMEREQD);
				tmp.hostname = hostname[0 .. hostname.indexOf('\0')].idup;
				
				/* Lots of different ways to get the ethernet address */
				/* Linux */
				/* Get the MAC address */
				if(ioctl(sck, SIOCGIFHWADDR, item) < 0) {
					throw new Exception("ioctl(SIOCGIFHWADDR)");
				}
				memcpy(tmp.mac.ptr, &item.ifr_hwaddr.sa_data, tmp.mac.length);
				if(tmp.name=="lo" || tmp.name.startsWith("lo:")){
					tmp.gateway_ip = parseIpDot("127.0.0.1");
					tmp.net_mask = parseIpDot("255.0.0.0");
				}
				rs ~= tmp;
			}
			fillArp(rs);
			fillGatewayInfo(rs);

			debug writefln("Net conf: %s", rs);
			return rs;
		}
	}
	

private:

	void fillArp(NetDev[] devices){
		auto arpTable = File("/proc/net/arp");
		scope(exit) arpTable.close;
		arpTable.readln;
		foreach(dev; devices){
			mac_type[ip_v4] empty;
			dev.arp_table = empty;
		}
		
		foreach(line; arpTable.byLine){
			auto a = line.split();
			if(a[3]=="00:00:00:00:00:00") continue;
			auto devName = a[5];
			auto idx = devices.countUntil!((a,b) => a.name == b)(devName);
			auto mac = parseMac(a[3]);
			auto ip = parseIpDot(a[0].idup);
			devices[idx].arp_table[ip] = mac;
		}
	}
	
	void fillGatewayInfo(NetDev[] devices){
		auto routeTable = File("/proc/net/route");
		scope(exit) routeTable.close;
		routeTable.readln;
		foreach(line; routeTable.byLine){
			auto a = line.split();
			if(a.length==0) continue;
			auto devName = a[0];
			auto gatewayIp4 = a[2];
			auto flags = parse!uint(a[3]);
			auto strMask = a[7];
			if( (flags&1) == 0){
				//unusable;
				continue;
			}
			auto idx = devices.countUntil!((a,b) => a.name == b)(devName);
			if(flags&2){
				//gateway
				devices[idx].gateway_ip = parseIpHex(gatewayIp4);
			}else if (strMask != "00000000"){
				devices[idx].net_mask = parseIpHex(strMask);
			}
		}
	}
}