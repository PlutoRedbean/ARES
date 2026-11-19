set image_dir [file join $work build rtos_amp]
file mkdir $image_dir
foreach image {irom.hex dram.hex worker_irom.hex worker_dram.hex} {
    file copy -force [file join $root build rtos_amp $image] $image_dir
}

# The generated Guard ROMs use paths relative to the PDS project directory.
set guard_rom_dir [file join $work build gen]
file mkdir $guard_rom_dir
foreach rom {emb conv1 conv1_b conv2 conv2_b head head_b vocab} {
    file copy -force [file join $root build gen ner_${rom}.hex] $guard_rom_dir
}
