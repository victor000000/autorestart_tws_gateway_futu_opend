@{
    obs = @{ ProcessName = 'obs64'; Executable = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe' }
    schwab = @{ ProcessName = 'thinkorswim'; Executable = '%LOCALAPPDATA%\thinkorswim\thinkorswim.exe' }
    wh6 = @{ ProcessName = 'mytrader_spqh'; Executable = 'C:\wh6浙商期货\mytrader_spqh.exe' }
    yongchun = @{ ProcessName = 'AlgoMaster'; Executable = 'C:\AlgoM2ZSQH\APPs64\AlgoMaster.exe' }
    doublecmd = @{ ProcessName = 'doublecmd'; Executable = 'C:\Program Files\Double Commander\doublecmd.exe' }
    futubull = @{ ProcessName = 'FTNN'; Directory = 'C:\Program Files\FTNN\app'; FileName = 'FTNN.exe' }
    # Shinny/KuaiQi stages upgrades in a new version directory whose Q73N.exe is
    # an unsigned stub, so dir.xml <current> names the installed client build.
    shinny = @{ ProcessName = 'Q73N'; Directory = '%APPDATA%\Q73N_cnzsqh_3_standard'; FileName = 'Q73N.exe'; Manifest = 'dir.xml' }
}
