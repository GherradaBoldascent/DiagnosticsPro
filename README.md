# DiagnosticsPro (PowerShell Port)

Port 1:1 de `PreRequisitesDDG.py` a PowerShell 5.1 nativo. Win10/11, una sola linea, sin .exe.

## Uso (PowerShell como Administrador)

Ya estas en PowerShell Admin, ejecuta directo (sin `powershell ...` anidado):

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm https://raw.githubusercontent.com/GherradaBoldascent/DiagnosticsPro/develop/DDG-Diagnostics.ps1 | iex
```

Silencioso masivo:

```powershell
$env:DDG_Silent='1'
irm https://raw.githubusercontent.com/GherradaBoldascent/DiagnosticsPro/develop/DDG-Diagnostics.ps1 | iex
```

Reporte: `C:\1\SystemInfo.txt`
