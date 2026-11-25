import struct, sys
import usb.core, usb.util

dev = usb.core.find(idVendor=0x2207, idProduct=0x350a)
assert dev is not None, "no Rockchip device"
dev.set_configuration() if False else None
cfg = dev.get_active_configuration()
intf = cfg[(0, 0)]
ep_out = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
ep_in = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)
print("interface class %02x/%02x/%02x, endpoints out=0x%02x in=0x%02x" % (intf.bInterfaceClass, intf.bInterfaceSubClass, intf.bInterfaceProtocol, ep_out.bEndpointAddress, ep_in.bEndpointAddress))
tag = [0]

def cmd(cdb, data_len, data_in, out_data=None, timeout=20000, cblen=10):
    tag[0] += 1
    cb = struct.pack("<4sIIBBB16s", b"USBC", tag[0], data_len, 0x80 if data_in else 0, 0, cblen, cdb.ljust(16, b"\0"))
    ep_out.write(cb, timeout)
    data = b""
    if data_len and data_in:
        data = bytes(ep_in.read(data_len, timeout))
    elif data_len:
        ep_out.write(out_data, timeout)
    csw = bytes(ep_in.read(13, timeout))
    sig, rtag, resid, status = struct.unpack("<4sIIB", csw)
    return data, status

def read_lba(lba, n):
    cdb = bytes([0x14, 0]) + struct.pack(">I", lba) + b"\0" + struct.pack(">H", n)
    return cmd(cdb, n * 512, True)

def desc(b):
    if not any(b): return "all zeros"
    if len(set(b)) == 1: return "all 0x%02x" % b[0]
    return "data, first bytes " + b[:8].hex(" ")

for lba in (0, 1, 60000, 65535, 65536, 65537, 70000, 131072, 1000000, 5000000):
    try:
        d, st = read_lba(lba, 8)
        print("READ_LBA sector %-8d x8 -> status %d, %s" % (lba, st, desc(d)))
    except Exception as e:
        print("READ_LBA sector %-8d x8 -> error %s" % (lba, e))
