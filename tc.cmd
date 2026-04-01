@echo off
:: Usage:
::   tc        — open current folder in TC right panel (default)
::   tc L      — open current folder in TC left panel
::   tc R      — open current folder in TC right panel

"C:\Program Files\totalcmd\TOTALCMD64.EXE" /O /R="%CD%"