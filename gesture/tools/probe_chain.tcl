# probe: connect to the JTAG server and dump the scan chain
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_disconnect
cfg_close
