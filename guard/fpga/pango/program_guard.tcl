# JTAG download for Pangu 200Pro+ (PG2L200H).
#
# IMPORTANT: keep this file ASCII-only, and use exactly ONE percent-s
# placeholder (cdt_cfg counts them against -args). cdt_cfg's Tcl interpreter
# reads the script with the system codepage; UTF-8 Chinese comments can swallow
# the next line and leave variables (e.g. port) undefined -- the failure looks
# like 'can't read "port": no such variable'.
#
# The JTAG server (cdt_js) must listen on the same port as cfg_connect below.
# The .sbit path arrives through -args and is substituted below; it must be an
# absolute path with forward slashes.
set port 60000
cfg_connect -ip 127.0.0.1 -port $port
cfg_scan_chain
cfg_assign_file -file %s -device_index 0
cfg_program -device_index 0
cfg_disconnect
cfg_close
