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
| **C. Xcode** (Mac Mini) | Mac + Xcode | 7 días gratis / 1 año con cuenta de desarrollador (99 USD) | **Tienes Mac: es lo más fácil** |

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

## C. Xcode en tu Mac Mini (recomendado si tienes Mac)

No necesitas Sideloadly ni iTunes: Xcode instala la app directamente, y al conectar el
iPhone a Xcode aparece solo el **Modo de desarrollador**.

1. **Instala Xcode** desde la App Store del Mac. Ábrelo una vez y acepta los componentes
   adicionales.
2. **Instala Homebrew, XcodeGen y git.** Abre Terminal (Cmd + Espacio → *Terminal*):

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

   Ejecuta las líneas que te muestra en *Next steps* y luego:

   ```bash
   brew install xcodegen git
   ```

3. **Descarga el repo y abre el proyecto:**

   ```bash
   cd ~/Desktop && git clone https://github.com/fleremiasflemin20-maker/ScanForge.git && cd ScanForge/ios-capture && xcodegen generate && open ScanForge.xcodeproj
   ```

4. **Pon tu Apple ID en Xcode:** Xcode → Settings → Accounts → **+** → Apple ID.
5. **Firma la app:** en la columna izquierda clic en **ScanForge** (icono azul) →
   pestaña **Signing & Capabilities** → marca *Automatically manage signing* → en
   **Team** elige tu *Personal Team*. Si sale un error con el *Bundle Identifier*,
   cámbialo por uno único, por ejemplo `com.tunombre.scanforge`.
6. **Instala en el iPhone:**
   - Conecta el iPhone por cable, desbloquéalo y pulsa **Confiar**.
   - Arriba en Xcode elige **tu iPhone** como destino y pulsa **▶ (Run)**.
   - En el iPhone: **Ajustes → Privacidad y seguridad → Modo de desarrollador** →
     actívalo → reinicia → **Activar**.
   - Pulsa **▶** otra vez en Xcode.
   - Si dice que el desarrollador no es de confianza: **Ajustes → General → VPN y
     gestión de dispositivos →** tu correo → **Confiar**.

Con Apple ID gratuito dura 7 días: para renovarla, conecta el iPhone y pulsa ▶ de nuevo.
Para recibir cambios nuevos del repo: `cd ~/Desktop/ScanForge && git pull && cd ios-capture && xcodegen generate`.

> **¿No encuentras el Modo de desarrollador?** Está oculto hasta que instalas una app
> con Xcode o Sideloadly. Instala primero y vuelve a mirar en *Privacidad y seguridad*.
> No lo confundas con el **Modo de aislamiento** (Lockdown Mode): ese debe seguir
> desactivado.

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
