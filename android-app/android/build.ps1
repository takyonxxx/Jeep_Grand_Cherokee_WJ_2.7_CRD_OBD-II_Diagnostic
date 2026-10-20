# Gradle'siz derleme: aapt2 + javac + d8 + zipalign + apksigner  (build-tools 37.0.0, android-36, JDK 17)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$bt = "$sdk\build-tools\37.0.0"
$platform = "$sdk\platforms\android-36\android.jar"
$jdk = "C:\Program Files\Android\Android Studio\jbr"
$javac = "$jdk\bin\javac.exe"; $keytool = "$jdk\bin\keytool.exe"
$out = "$root\build"
$ks = "$root\wjdiag.jks"; $ksPass = "wjdiag2026"; $alias = "wjdiag"
$apkOut = "$root\..\WJDiag.apk"

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force "$out\res", "$out\classes", "$out\gen" | Out-Null

Write-Host "== aapt2 compile"
& "$bt\aapt2.exe" compile --dir "$root\res" -o "$out\res.zip"
if ($LASTEXITCODE) { throw "aapt2 compile failed" }

Write-Host "== aapt2 link"
& "$bt\aapt2.exe" link -o "$out\base.apk" -I $platform --manifest "$root\AndroidManifest.xml" `
    --java "$out\gen" --min-sdk-version 21 --target-sdk-version 28 --auto-add-overlay "$out\res.zip"
if ($LASTEXITCODE) { throw "aapt2 link failed" }

Write-Host "== javac"
$sources = Get-ChildItem -Recurse "$root\src", "$out\gen" -Filter *.java | ForEach-Object { $_.FullName }
& $javac -source 1.8 -target 1.8 -encoding UTF-8 -classpath $platform -d "$out\classes" -nowarn -Xlint:-options $sources
if ($LASTEXITCODE) { throw "javac failed" }

Write-Host "== d8"
& "$jdk\bin\jar.exe" cf "$out\classes.jar" -C "$out\classes" .
if ($LASTEXITCODE) { throw "jar failed" }
& "$bt\d8.bat" --release --min-api 21 --lib $platform --output "$out" "$out\classes.jar"
if ($LASTEXITCODE) { throw "d8 failed" }

Write-Host "== apk paketleme"
Copy-Item "$out\base.apk" "$out\unaligned.apk"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open("$out\unaligned.apk", "Update")
$entry = $zip.CreateEntry("classes.dex", [System.IO.Compression.CompressionLevel]::Optimal)
$s = $entry.Open(); $bytes = [System.IO.File]::ReadAllBytes("$out\classes.dex"); $s.Write($bytes, 0, $bytes.Length); $s.Close()
$zip.Dispose()

Write-Host "== zipalign"
& "$bt\zipalign.exe" -f -p 4 "$out\unaligned.apk" "$out\aligned.apk"
if ($LASTEXITCODE) { throw "zipalign failed" }

if (-not (Test-Path $ks)) {
    Write-Host "== keystore oluşturuluyor"
    & $keytool -genkeypair -keystore $ks -storepass $ksPass -keypass $ksPass -alias $alias -keyalg RSA -keysize 2048 `
        -validity 10000 -dname "CN=WJ Diag, O=Turkay, C=TR"
    if ($LASTEXITCODE) { throw "keytool failed" }
}

Write-Host "== imzalama"
& "$bt\apksigner.bat" sign --ks $ks --ks-pass "pass:$ksPass" --key-pass "pass:$ksPass" --ks-key-alias $alias `
    --out $apkOut "$out\aligned.apk"
if ($LASTEXITCODE) { throw "apksigner failed" }
& "$bt\apksigner.bat" verify --print-certs $apkOut
Write-Host "== HAZIR: $(Resolve-Path $apkOut)"
