module vibe.core.drivers.pfq.ethernet;

alias ubyte[6] mac_type;
enum mac_type NO_MAC = [0];

struct EthernetPacket{
	align (1):
	mac_type dest;
	mac_type src;
	ushort type;
}


auto parseMac(const char[] s){
	import std.conv;
	mac_type mac;
	string tmp = s.idup;
	for(int i=0; i<6; i++){
		string str = tmp[0 .. 2];
		mac[i] = parse!ubyte(str, 16);
		if(tmp.length>3) tmp = tmp[3 .. $];
	}
	return mac;
}

unittest{
	auto mac = parseMac("00:08:ca:e6:7e:57");
	assert(parseMac("00:08:ca:e6:7e:57") == cast(ubyte[])x"0008cae67e57");
}


