# Сервер Invisible Movement. Перед каждым запуском сам обновляется до свежей сборки
# (версии Minecraft и Fabric и моды берутся из pack.toml) и делает резервную копию мира.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location $PSScriptRoot

$PackUrl = 'https://raw.githubusercontent.com/matthewbkrr/invisiblemovement-pack/main/pack.toml'
$ScriptUrl = 'https://raw.githubusercontent.com/matthewbkrr/invisiblemovement-pack/main/server/start.ps1'
$Memory = '4G'
$BackupsToKeep = 10

# Скрипт обновляет и сам себя: если в сборке он новее, подменяем файл и запускаем новую версию вместо этой.
function Restart-IfScriptUpdated {
    $downloaded = Join-Path $env:TEMP 'invisiblemovement-start.ps1'
    try {
        Invoke-WebRequest -UseBasicParsing $ScriptUrl -OutFile $downloaded
    } catch {
        return
    }
    if ((Get-FileHash $downloaded).Hash -eq (Get-FileHash $PSCommandPath).Hash) {
        Remove-Item $downloaded
        return
    }
    Move-Item $downloaded $PSCommandPath -Force
    Write-Host 'Скрипт сервера обновился, перезапускаю его.'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

function Test-Java {
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        return $false
    }
    # java -version пишет в поток ошибок; через cmd, чтобы Windows PowerShell не принял это за сбой.
    $version = cmd /c 'java -version 2>&1' | Select-Object -First 1
    $match = [regex]::Match([string]$version, 'version "(\d+)')
    return $match.Success -and [int]$match.Groups[1].Value -ge 25
}

function Test-Eula {
    if (-not (Test-Path eula.txt)) {
        Set-Content eula.txt 'eula=false' -Encoding ASCII
    }
    return [bool](Select-String -Path eula.txt -Pattern '^eula=true' -Quiet)
}

function Update-Server {
    Write-Host 'Проверяю обновления...'
    $pack = (Invoke-WebRequest -UseBasicParsing $PackUrl).Content
    $minecraft = [regex]::Match($pack, 'minecraft\s*=\s*"([^"]+)"').Groups[1].Value
    $loader = [regex]::Match($pack, 'fabric\s*=\s*"([^"]+)"').Groups[1].Value
    $wanted = "$minecraft/$loader"
    $current = if (Test-Path server-version.txt) { (Get-Content server-version.txt -Raw).Trim() } else { '' }
    if ($wanted -ne $current -or -not (Test-Path fabric-server-launch.jar)) {
        Write-Host "Ставлю Minecraft $minecraft с Fabric $loader..."
        # Явный цикл: Windows PowerShell отдаёт JSON-массив в конвейер одним куском, и фильтры по нему не работают.
        $installer = $null
        foreach ($candidate in (Invoke-RestMethod 'https://meta.fabricmc.net/v2/versions/installer')) {
            if ($candidate.stable) {
                $installer = $candidate.version
                break
            }
        }
        if (-not $installer) {
            throw 'не удалось узнать версию установщика Fabric'
        }
        Invoke-WebRequest -UseBasicParsing "https://meta.fabricmc.net/v2/versions/loader/$minecraft/$loader/$installer/server/jar" -OutFile fabric-server-launch.jar
        Set-Content server-version.txt $wanted -Encoding ASCII
    }
    & java -jar packwiz-installer-bootstrap.jar -g -s server $PackUrl
    if ($LASTEXITCODE -ne 0) {
        throw 'не удалось обновить моды'
    }
}

function Backup-World {
    if (-not (Test-Path world)) {
        return
    }
    New-Item -ItemType Directory -Force backups | Out-Null
    $archive = 'backups\world-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm') + '.zip'
    Write-Host "Резервная копия мира: $archive"
    Compress-Archive -Path world -DestinationPath $archive -Force
    Get-ChildItem 'backups\world-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $BackupsToKeep | Remove-Item
}

Restart-IfScriptUpdated
if (-not (Test-Java)) {
    Write-Host 'Нужна Java 25 или новее: https://adoptium.net/temurin/releases/?version=25'
    exit 1
}
if (-not (Test-Eula)) {
    Write-Host 'Нужно согласие с EULA Minecraft: https://www.minecraft.net/eula'
    Write-Host 'Если согласен, открой eula.txt в этой папке, замени eula=false на eula=true и снова запусти start.bat.'
    exit 1
}

while ($true) {
    Restart-IfScriptUpdated
    try {
        Update-Server
    } catch {
        if (-not (Test-Path fabric-server-launch.jar)) {
            Write-Host "Не удалось скачать сервер: $_"
            exit 1
        }
        Write-Host "Не удалось проверить обновления ($_). Запускаю то, что уже скачано."
    }
    Backup-World
    Write-Host 'Запускаю сервер. Остановить: команда stop в этом окне.'
    & java '-Xms2G' "-Xmx$Memory" -jar fabric-server-launch.jar nogui
    Write-Host 'Сервер остановлен. Через 10 секунд перезапуск с обновлением; чтобы выключить совсем, закрой окно.'
    Start-Sleep -Seconds 10
}
