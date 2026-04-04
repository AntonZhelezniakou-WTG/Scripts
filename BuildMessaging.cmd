copy /Y c:\git\GitHub\WiseTechGlobal\CargoWise.Database\Database\Bin\net48\CargoWise.Data.dll .\Bin\
copy /Y c:\git\GitHub\WiseTechGlobal\CargoWise.Database\Database\Bin\net48\CargoWise.Data.pdb .\Bin\
copy /Y c:\git\GitHub\WiseTechGlobal\CargoWise.Database\Database\Bin\net48\CargoWise.Data.dll.config .\Bin\

copy /Y c:\git\GitHub\WiseTechGlobal\CargoWise.Database\Database\Bin\net8.0\CargoWise.Data.dll .\Bin\net8.0\
copy /Y c:\git\GitHub\WiseTechGlobal\CargoWise.Database\Database\Bin\net8.0\CargoWise.Data.pdb .\Bin\net8.0\
copy /Y c:\git\GitHub\WiseTechGlobal\CargoWise.Database\Database\Bin\net8.0\CargoWise.Data.deps.json .\Bin\net8.0\
copy /Y c:\git\GitHub\WiseTechGlobal\CargoWise.Database\Database\Bin\net8.0\CargoWise.Data.dll.config .\Bin\net8.0\

dotnet paket install

copy /Y "packages\CargoWise.Customs.PL.MessageDefinitions\lib\net48\" "Bin"
copy /Y "packages\CargoWise.Customs.PL.MessageDefinitions\lib\net8.0\" "Bin\net8.0"

copy /Y "packages\CargoWise.Customs.PL.MessageContracts\lib\net48\" "Bin"
copy /Y "packages\CargoWise.Customs.PL.MessageContracts\lib\net8.0\" "Bin\net8.0"

call c:\git\GitHub\WiseTechGlobal\Personal\Scripts\build.cmd .\Enterprise\Product\Core\ServiceManager\ServiceManager\ServiceManager.Runner.CW\ServiceManager.Runner.CW.csproj .\Enterprise\Product\Core\ServiceManager\ServiceManager\ServiceManager.sln .\Enterprise\Product\Core\Integration\Enterprise.Integration.sln .\Enterprise\Product\Core\Messaging\Enterprise.Messaging.Integration\Enterprise.Messaging.Integration.sln .\Enterprise\Product\Core\Messaging\Enterprise.Messaging.sln

dotnet tool run AssemblyMetaDataExtractor -- Build.xml