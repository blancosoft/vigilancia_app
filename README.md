# Vigilancia Wi-Fi

Aplicación Flutter para Android que transmite la cámara de un teléfono a un
segundo teléfono mediante WebRTC. La conexión se realiza dentro de la misma red
Wi-Fi y no necesita un servidor externo.

## Ejecutar en VS Code

1. Abre esta carpeta en Visual Studio Code.
2. Instala la extensión oficial **Flutter**.
3. En la terminal ejecuta:

   ```powershell
   flutter pub get
   flutter devices
   flutter run -d <ID_DEL_DISPOSITIVO>
   ```

Para generar un APK de pruebas:

```powershell
flutter build apk --debug
```

El archivo queda en `build/app/outputs/flutter-apk/app-debug.apk`. Instala ese
mismo APK en los dos teléfonos. En Android también puedes usar:

```powershell
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

## Uso

1. En el teléfono que tendrá la cámara, pulsa **Activar en el teléfono
   cámara** y concede el permiso.
2. Lee la dirección IPv4 que aparece en pantalla.
3. En el segundo teléfono, escribe esa dirección y pulsa **Conectar como
   visor**. Acepta el permiso de red local si Android lo solicita.

El puerto de señalización TCP es `8080`. La aplicación muestra la IP para que no
sea necesario conocerla previamente.

## Problemas frecuentes

- Ambos teléfonos deben estar conectados al mismo SSID Wi-Fi. Desactiva Mobile
  Data, VPN, datos móviles y cualquier ahorro de datos.
- En redes de hotel, aeropuertos, tiendas o redes Guest puede existir aislamiento
  de clientes (AP/client isolation). Esa red no permite que un teléfono abra
  un socket contra el otro aunque ambos tengan Internet.
- Usa una red doméstica o el punto de acceso de un router. Si el router tiene
  varios Access Points, verifica que ambos teléfonos estén en el mismo segmento.
- La pantalla del teléfono cámara debe permanecer abierta. Android puede
  suspender la aplicación y liberar la cámara al ponerla en segundo plano.
- Si la red tiene una IP dinámica o cambia, vuelve a leer la dirección mostrada por
  la aplicación.
- Comprueba que no estés escribiendo `localhost` o `127.0.0.1`: el visor debe
  escribir la IP privada del teléfono cámara, por ejemplo `192.168.1.25`.
- En Android 13 o posterior, concede **Dispositivos cercanos** si aparece. En
  Android 17 o posterior, concede **Red local**. En versiones anteriores,
  `INTERNET` es suficiente para este socket.
- Si instalas una versión nueva, desinstala la anterior o vuelve a conceder los
  permisos desde **Ajustes > Aplicaciones > Vigilancia Wi-Fi > Permisos**.

## Detalles técnicos

- `lib/screens/camera_screen.dart`: captura la cámara, publica la oferta SDP y
  transmite la pista de video.
- `lib/screens/viewer_screen.dart`: recibe la oferta, genera la respuesta y
  muestra la pista remota mediante `onTrack`.
- `lib/services/streaming_service.dart`: servidor/cliente TCP y protocolo de
  señalización.
- `AndroidManifest.xml`: permisos de cámara, audio, Internet y red local.
- Los mensajes son JSON separados por `\n`; así una lectura TCP puede contener
  varios mensajes o solo un fragmento sin romper el SDP.
- Los candidatos ICE que llegan antes de la descripción remota se guardan en
  una cola y se agregan después.
- El teléfono cámara escucha en el puerto TCP `8080`; el visor abre una sola
  conexión a la IP mostrada.

## Nota sobre `flutter_webrtc`

`flutter_webrtc` 1.6.2+hotfix.3 requiere Flutter/Dart compatible con el SDK
instalado y Android API 23 o posterior. La aplicación fue preparada para
`minSdk 23`, permisos runtime de cámara y WebRTC con `onTrack`.
