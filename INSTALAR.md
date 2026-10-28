# Instalar ScanForge Pro en tu iPhone sin App Store

GitHub compila la app automáticamente en un Mac en la nube y publica un archivo
**`ScanForge.ipa`** sin firmar en
[Releases](https://github.com/fleremiasflemin20-maker/ScanForge/releases/latest).
Para instalarlo, tu iPhone necesita que lo firmes con **tu propio Apple ID**. Elige uno
de estos tres caminos.

| Método | Necesitas | Dura | Recomendado si… |
|---|---|---|---|
| **A. Sideloadly** (Windows/Mac) | PC + cable + Apple ID gratis | 7 días (reinstalar con 1 clic) | Es la forma más rápida desde tu PC con Windows |
| **B. SideStore / AltStore** | PC solo la primera vez | 7 días, se renueva **desde el iPhone** | Quieres actualizar y renovar sin cable |
| **C. Xcode** (Mac) | Mac + Xcode | 7 días gratis / 1 año con cuenta de desarrollador (99 USD) | Vas a modificar el código |

> Con un Apple ID gratuito Apple limita las apps instaladas así a **7 días** y 3 apps a la
> vez. Al caducar, la app no se borra ni pierdes tus escaneos: basta con volver a
> firmarla. Con la cuenta de pago de Apple Developer dura 1 año.

---

## A. Sideloadly desde Windows (lo más rápido)

1. Instala **iTunes** e **iCloud** en su versión *de la web de Apple*, no la de
   Microsoft Store (Sideloadly necesita sus controladores):
   - iTunes: <https://www.apple.com/itunes/download/win64>
   - iCloud: <https://support.apple.com/en-us/HT204283>
2. Descarga e instala **Sideloadly**: <https://sideloadly.io>
3. Descarga `ScanForge.ipa` de
   [la última Release](https://github.com/fleremiasflemin20-maker/ScanForge/releases/latest).
4. Conecta el iPhone por cable, desbloquéalo y pulsa **Confiar en este ordenador**.
5. En Sideloadly: arrastra el `.ipa`, escribe tu Apple ID y pulsa **Start**.
   Te pedirá la contraseña del Apple ID y el código de verificación. Sideloadly se
   conecta directamente a Apple: tu contraseña no pasa por ScanForge.
6. En el iPhone:
   - **Ajustes → Privacidad y seguridad → Modo de desarrollador → Activar** (reinicia).
   - **Ajustes → General → VPN y gestión de dispositivos →** tu Apple ID → **Confiar**.
7. Abre **ScanForge Pro** y acepta el permiso de cámara.

Para renovarla a los 7 días, repite el paso 5. Tus escaneos se mantienen.

## B. SideStore o AltStore (actualizaciones desde el propio iPhone)

1. Instala **SideStore** (<https://sidestore.io>, renueva sin PC) o **AltStore**
   (<https://altstore.io>, renueva con AltServer en tu PC por Wi-Fi), siguiendo su guía.
2. En SideStore/AltStore: **Sources → +** y pega esta URL:

   ```
   https://fleremiasflemin20-maker.github.io/ScanForge/altstore.json
   ```

3. Abre la fuente **ScanForge** e instala **ScanForge Pro**. Cuando publiquemos una
   versión nueva aparecerá como actualización.
4. Activa el **Modo de desarrollador** como en el paso A.6.

## C. Xcode en tu Mac

```bash
brew install xcodegen
cd ios-capture
xcodegen generate
open ScanForge.xcodeproj
```

En *Signing & Capabilities* elige tu Team y pulsa **Run** con el iPhone conectado.

---

## Publicar una versión nueva

Cada push a `main` que toque `ios-capture/` compila la app en GitHub Actions. Para
publicar una Release con el `.ipa`:

```bash
git tag v2.0.1
git push origin v2.0.1
```

Después actualiza `version`, `downloadURL` y `size` en `docs/altstore.json` para que
SideStore/AltStore la ofrezcan como actualización.
