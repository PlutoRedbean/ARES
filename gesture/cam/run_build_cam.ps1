Set-Location 'E:\qs\ScreenSense\cam\fpga\pango'
& 'D:\Pango\PDS_2025.2-SP3-EN-ads\bin\pds_shell.exe' -file 'E:\qs\ScreenSense\cam\fpga\pango\flow_cam.tcl' *> 'E:\qs\ScreenSense\cam\build_cam.log'
Add-Content 'E:\qs\ScreenSense\cam\build_cam.log' ('EXIT=' + $LASTEXITCODE)
