module vibe.core.drivers.pfq.udp;


struct UdpIp4Packet{
	align (1):
	ushort src_port;
	ushort dst_port;
	ushort length;
	ushort checksum;
}
