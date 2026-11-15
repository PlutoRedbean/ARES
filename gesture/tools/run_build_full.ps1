Set-Location 'E:\qs\ScreenSense\fpga\prj_pds'
& 'D:\Pango\PDS_2025.2-SP3-EN-ads\bin\pds_shell.exe' -file 'E:\qs\ScreenSense\tools\build_full.tcl' *> 'E:\qs\ScreenSense\tools\build_full.log'
Add-Content 'E:\qs\ScreenSense\tools\build_full.log' ('EXIT=' + $LASTEXITCODE)
