module vibe.core.drivers.unet.utils;

import core.stdc.string;
import std.stdio;
import vibe.core.drivers.utils;

struct UdpRxQueue(uint N = 32, ushort MAX_SIZE = 2048){
	ubyte[N][MAX_SIZE] queue;
	ushort[N] size;
	
	ulong write_pos;
	ulong read_pos;
	
	bool hasNext(){
		return read_pos<write_pos;
	}
	
	void add(ubyte* data, ushort len){
		memcpy(queue[write_pos % N].ptr, data, len);
		size[write_pos] = len;
		if(write_pos - read_pos == N ){
			debug writefln("overflow in cyclic buffer");
			read_pos += N + 1;
		}
		write_pos++;
	}
	
	bool get(ref ubyte[]data){
		if(read_pos>=write_pos) return false;
		data.length = size[read_pos];
		memcpy(data.ptr, queue[read_pos % N].ptr, data.length);
		read_pos++;
		return true;
	}
}


