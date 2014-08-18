module vibe.core.drivers.libpfq;

version(VibeLibeventDriver) version(PFQDriver)
{

	import vibe.core.drivers.libevent2;
	import vibe.core.driver;
	debug import std.stdio;

	class PFQDriver : Libevent2Driver {
		this(DriverCore core)
		{
			super(core);
			debug writeln("PFQDriver");
		}

		override UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0"){
			debug writeln("PFQDriver - listenUDP");
			return super.listenUDP(port, bind_address);
		}

	}
}

