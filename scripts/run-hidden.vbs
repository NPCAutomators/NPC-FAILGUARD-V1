' NPC FailGuard - hidden daemon launcher.
' Task Scheduler runs this via wscript.exe so NO console window appears
' at logon (and there is no window to accidentally close).
' The daemon is run through cmd with output redirected to core\logs\daemon.out:
' pythonw.exe has NO stdout/stderr (sys.stdout is None) and uvicorn touches
' sys.stdout at startup, so without real handles the daemon dies silently.
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
core = root & "\core"
py = core & "\.venv\Scripts\pythonw.exe"
If Not fso.FileExists(py) Then py = core & "\.venv\Scripts\python.exe"
If Not fso.FolderExists(core & "\logs") Then fso.CreateFolder(core & "\logs")
q = Chr(34)
cmdline = "cmd /c " & q & q & py & q & " " & q & core & "\main.py" & q & _
          " > " & q & core & "\logs\daemon.out" & q & " 2>&1" & q
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = core
sh.Run cmdline, 0, False
