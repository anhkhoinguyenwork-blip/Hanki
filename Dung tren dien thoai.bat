@echo off
rem Hanki on your phone, through Tailscale. Double-click once, then say Yes to the admin prompt.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "TS=%ProgramFiles%\Tailscale\tailscale.exe"
if not exist "%TS%" (
  echo.
  echo  Chua thay Tailscale tren may.
  echo  Cai Tailscale truoc ^(tailscale.com/download^), dang nhap, roi chay lai file nay.
  echo.
  pause
  exit /b
)
echo.
echo  [1/3] Cho Hanki nhan ket noi qua Tailscale...
netsh http delete urlacl url=http://+:8765/ >nul 2>&1
netsh http add urlacl url=http://+:8765/ sddl=D:(A;;GX;;;WD) >nul
echo  [2/3] Mo dia chi HTTPS rieng cho dien thoai...
echo        Neu hien mot duong link "To enable, visit", mo link do, bam Enable, roi quay lai day.
"%TS%" serve --bg 8765
echo  [3/3] Khoi dong lai Hanki...
explorer.exe "%~dp0launch.vbs"
echo.
echo  Xong. Dia chi de mo tren dien thoai la dong https://... ben duoi:
echo.
"%TS%" serve status
echo.
pause
