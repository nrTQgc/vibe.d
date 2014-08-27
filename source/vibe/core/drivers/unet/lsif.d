module vibe.core.drivers.unet.lsif;


public import core.sys.posix.sys.ioctl;
public import core.sys.posix.sys.socket;
public import core.sys.posix.arpa.inet;
public import core.sys.posix.netinet.in_;
public import core.stdc.string;
public import core.sys.posix.netdb;

/*
 * Port from  https://raw.githubusercontent.com/ajrisi/lsif/master/lsif.c
 */
struct ifreq {
	char ifr_name[IFNAMSIZ]; /* Interface name */
	union {
		sockaddr ifr_addr;
		sockaddr ifr_dstaddr;
		sockaddr ifr_broadaddr;
		sockaddr ifr_netmask;
		sockaddr ifr_hwaddr;
		short	       ifr_flags;
		int	       ifr_ifindex;
		int	       ifr_metric;
		int	       ifr_mtu;
		ifmap    ifr_map;
		char	       ifr_slave[IFNAMSIZ];
		char	       ifr_newname[IFNAMSIZ];
		char *	       ifr_data;
	};
};

struct ifmap {
	ulong mem_start;
	ulong mem_end;
	ushort base_addr; 
	ubyte irq;
	ubyte dma;
	ubyte port;
	/* 3 bytes spare */
};

struct ifconf {
	int		      ifc_len; /* size of buffer */
	union {
		char *	      ifc_buf; /* buffer address */
		ifreq * ifc_req; /* array of structures */
	};
};

enum NI_MAXHOST = 1025;
enum NI_MAXSERV = 32;
enum IFNAMSIZ   = 16;

char* get_ip_str(sockaddr *sa, char *s, int maxlen)
{
	switch(sa.sa_family) {
		case AF_INET:
			inet_ntop(AF_INET, &((cast(sockaddr_in *)sa).sin_addr), s, maxlen);
			break;
			
		case AF_INET6:
			inet_ntop(AF_INET6, &((cast(sockaddr_in6 *)sa).sin6_addr), s, maxlen);
			break;
			
		default:
			strncpy(s, "Unknown AF", maxlen);
			return null;
	}
	return s;
}
