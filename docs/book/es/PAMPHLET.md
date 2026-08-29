# Swiss Army VPN

Una página. Si solo lees una cosa, que sea esta.

## Qué es

Una ventana pequeña de Windows para una VPN que Windows ya sabe usar. También puede cortar el resto de internet si esa VPN cae. Ese corte se llama kill switch (bloqueo).

No es la empresa NordVPN. No es un servicio nuevo. Tú pones el usuario y la contraseña.

## Qué hace en el equipo

- Crea una VPN de Windows llamada Swiss Army VPN.
- Puede encender cuatro reglas de cortafuegos que cortan internet normal.
- Puede guardar un usuario y una contraseña que guarda Windows.
- Puede cambiar el servidor.

No lee tus archivos. No guarda las páginas que visitas. No guarda tu token de GitHub.

## Qué no hace

No ejecuta WireGuard ni OpenVPN.

No te hace seguro en una red mala por sí sola. El bloqueo solo ayuda si está encendido y el túnel es el que esta app vigila.

## Cómo empezar

1. Baja el zip de la última Release en GitHub. No uses el botón verde Code.
2. Abre la carpeta. No separes los archivos.
3. Ejecuta `Install Swiss Army VPN.exe`. Windows pedirá permiso de administrador.
4. Abre la app. Elige SET UP SIGN-IN. Escribe el usuario y la contraseña de tu VPN.
5. CONNECT + ARM si quieres el bloqueo. CONNECT si no.

## Cómo parar

Elige DISCONNECT + UNLOCK.

Si la ventana no abre y no hay internet, usa Emergency Unlock en el menú Inicio.

## Si te trabas

El bloqueo puede cortar todo el equipo. Eso es el diseño. Primero desbloquea. Luego arregla el login o el servidor.

No envíes un registro crudo. Si debes compartir estado, usa el scrubber antes.

## Privacidad

Las contraseñas se quedan en Windows. Esta app no las imprime. No pide tu cara, tu voz ni un juego con tiempo.

Un problema de seguridad: GitHub security advisories. Nunca una contraseña en un issue.

## Quién lo hizo

Justichuu. No oficial. GPL-3.0-only. El código se puede leer.
