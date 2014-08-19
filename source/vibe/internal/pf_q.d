module vibe.internal.pf_q;


alias ushort uint16_t;
alias uint uint32_t;
alias ubyte uint8_t;
alias ulong uint64_t;

void smp_wmb() { barrier(); }
void smp_rmb() { barrier(); }

void barrier() { 
	//asm volatile ("" ::: "memory"); 
	/*
	 * http://forum.dlang.org/thread/bifrvifzrhgocrejepvc@forum.dlang.org?page=3#post-mailman.2455.1382620969.1719.digitalmars-d:40puremagic.com
In gdc:
---
asm {"" ::: "memory";}

An asm instruction without any output operands will be treated
identically to a volatile asm instruction in gcc, which indicates that
the instruction has important side effects.  So it creates a point in
the code which may not be deleted (unless it is proved to be
unreachable).

The "memory" clobber will tell the backend to not keep memory values
cached in registers across the assembler instruction and not optimize
stores or loads to that memory.  (That does not prevent a CPU from
reordering loads and stores with respect to another CPU, though; you
need real memory barrier instructions for that.)
    */
	version(GNU){
		asm {"" ::: "memory";}
	}
}


struct pfq_pkt_hdr
{
	uint64_t data;          /* state from pfq_cb */
	
	union
	{
		ulong tv64;
		struct {
			uint32_t    sec;
			uint32_t    nsec;
		};               /* note: struct timespec is badly defined for 64 bits arch. */
	};
	
	int         if_index;   /* interface index */
	int         gid;        /* gruop id */
	
	uint16_t    len;        /* length of the packet (off wire) */
	uint16_t    caplen;     /* bytes captured */
	
	/+*union
	{
		struct
		{
			uint16_t vlan_vid:12,   /* 8021q vlan id */
				reserved:1,    /* 8021q reserved bit */
				vlan_prio:3;   /* 8021q vlan priority */
		};
		
		uint16_t     vlan_tci;
	};*+/
	uint16_t     vlan_tci;

	uint8_t     hw_queue;   /* 256 queues per device */
	uint8_t     commit;
	
}; /* __attribute__((packed)); */

/*
 * Functional argument:
 *
 * pod          -> (ptr, sizeof, 1  )
 * pod array    -> (ptr, sizeof, len)
 * string       -> (ptr, 0     ,  - )
 * expression   -> (0,   index ,  - )
 *
 */
struct pfq_functional_arg_descr
{
	const void *            ptr;
	size_t                  size;
	size_t                  nelem;   /* > 1 is an array */
};



/*
 * Functional descriptor:
 */

struct pfq_functional_descr
{
	const char *             symbol;
	pfq_functional_arg_descr arg[4];
	size_t                          next;
};


struct pfq_computation_descr
{
	size_t                          size;
	size_t                          entry_point;
	pfq_functional_descr*     fun;
};


/*  sock options helper structures */


struct pfq_vlan_toggle
{
	int gid;
	int vid;
	int toggle;
};

struct pfq_binding
{
	int gid;
	int if_index;
	int hw_queue;
};

struct pfq_group_join
{
	int gid;
	int policy;
	ulong class_mask;
};

struct pfq_group_computation
{
	int gid;
	pfq_computation_descr *prog;
};


struct pfq_group_context
{
	void *context;
	size_t       size;      /* sizeof(context) */
	int gid;
	int level;
};

/* pfq_fprog: per-group sock_fprog */
struct pfq_fprog
{
	int gid;
	sock_fprog fcode;
};



/* pfq statistics for socket and groups */
struct pfq_stats
{
	ulong recv;   /* received by the queue         */
	ulong lost;   /* queue is full, packet lost... */
	ulong drop;   /* by filter                     */
	
	ulong sent;   /* sent by the driver */
	ulong disc;   /* discarded by the driver */
};

/* pfq counters for groups */
enum Q_MAX_COUNTERS = 64;
enum Q_MAX_PERSISTENT = 1024;

struct pfq_counters
{
	ulong counter[Q_MAX_COUNTERS];
};









//from uapi/linux/filter.h
struct sock_fprog { /* Required for SO_ATTACH_FILTER. */
	ushort      len;    /* Number of filter blocks */
	void *filter;
};


