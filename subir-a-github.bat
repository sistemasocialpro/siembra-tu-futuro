@echo off
cd /d "%~dp0"
echo Carpeta: %cd%
echo.
git log --oneline -1
echo.
git remote set-url origin https://sistemasocialpro@github.com/sistemasocialpro/siembra-tu-futuro.git
git branch -M main
git push -u origin main
echo.
echo Listo. Copia aqui lo que dice arriba si hubo un error.
pause
