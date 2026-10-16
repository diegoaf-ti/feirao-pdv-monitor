Option Explicit
Dim pdvShell, pdvFiles, pdvDirectory, pdvPowerShell, pdvCommand
Set pdvShell = CreateObject("WScript.Shell")
Set pdvFiles = CreateObject("Scripting.FileSystemObject")
pdvDirectory = pdvFiles.GetParentFolderName(WScript.ScriptFullName)
pdvPowerShell = pdvShell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If pdvFiles.FileExists(pdvShell.ExpandEnvironmentStrings("%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe")) Then
  pdvPowerShell = pdvShell.ExpandEnvironmentStrings("%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe")
End If
pdvCommand = Chr(34) & pdvPowerShell & Chr(34) & " -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Chr(34) & pdvDirectory & "\InicializarMonitor.ps1" & Chr(34) & " -StartHidden"
pdvShell.Run pdvCommand, 0, False
