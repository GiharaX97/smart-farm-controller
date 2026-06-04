$urls = @{
    firmware = "https://raw.githubusercontent.com/GiharaX97/smart-farm-controller/main/esp32s3_firmware/esp32s3-firmwarev2.0.ino"
    hivemq = "https://raw.githubusercontent.com/GiharaX97/smart-farm-controller/main/flutter_app/lib/services/hivemq_service.dart"
    home = "https://raw.githubusercontent.com/GiharaX97/smart-farm-controller/main/flutter_app/lib/screens/home_screen.dart"
}

$dest = "H:\My_Projects\farm-v2"
Write-Output "=== Syncing Farm Controller v2.0 ==="

Write-Output "[1/3] Downloading firmware v2.0..."
Invoke-WebRequest -Uri $urls.firmware -OutFile "$dest\sketch_apr30b_v8.ino" -UseBasicParsing
Write-Output "  -> $dest\sketch_apr30b_v8.ino (replaces old v8.0)"

Write-Output "[2/3] Downloading hivemq_service.dart..."
Invoke-WebRequest -Uri $urls.hivemq -OutFile "$dest\farmv1\lib\services\hivemq_service.dart" -UseBasicParsing
Write-Output "  -> $dest\farmv1\lib\services\hivemq_service.dart"

Write-Output "[3/3] Downloading home_screen.dart..."
Invoke-WebRequest -Uri $urls.home -OutFile "$dest\farmv1\lib\screens\home_screen.dart" -UseBasicParsing
Write-Output "  -> $dest\farmv1\lib\screens\home_screen.dart"

Write-Output ""
Write-Output "=== ALL FILES SYNCED ==="
Write-Output "Now open the Arduino IDE and flash sketch_apr30b_v8.ino to your ESP32-S3"
Write-Output "Then run 'flutter build apk' from the farmv1 folder for the Android app"
