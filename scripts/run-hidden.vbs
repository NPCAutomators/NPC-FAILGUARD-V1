' NPC FailGuard - hidden daemon launcher.
' Task Scheduler runs this via wscript.exe so NO console window appears
' at logon (and there is no window to accidentally close).
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
core = root & "\core"
py = core & "\.venv\Scripts\pythonw.exe"
If Not fso.FileExists(py) Then py = core & "\.venv\Scripts\python.exe"
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = core
sh.Run """" & py & """ """ & core & "\main.py""", 0, False
