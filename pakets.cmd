dotnet paket install

copy /Y "packages\CargoWise.Customs.PL.MessageDefinitions\lib\net48\" "Bin"
copy /Y "packages\CargoWise.Customs.PL.MessageDefinitions\lib\net8.0\" "Bin\net8.0"

copy /Y "packages\CargoWise.Customs.PL.MessageContracts\lib\net48\" "Bin"
copy /Y "packages\CargoWise.Customs.PL.MessageContracts\lib\net8.0\" "Bin\net8.0"

pause