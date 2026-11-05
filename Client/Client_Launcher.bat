@echo off
REM You must be logged into steam, and steam client must be running in the background!
Rem copy the new battley to the folder.
rem copy arma 2's "addons" folder to Operation arrowhead folder.
rem change %userprofile% to your actual user folder, or replace the whole %userprofile%\Desktop\armaMods\@DayZ_Epoch with the full path of the mods directory
Rem this script should just work if you copy the epoch mod to your desktop\armaMmods\ folder. 
start "arma2" /min /high "C:\Program Files (x86)\Steam\steamapps\common\Arma 2 Operation Arrowhead\"ArmA2OA_BE.exe -nosplash -skipIntro -world=empty "-mod=%userprofile%\Desktop\armaMods\@DayZ_Epoch"
