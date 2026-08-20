# El Almacén — Base de datos en Supabase

## Cómo cargarla
1. Entrá a tu proyecto en **supabase.com** → **SQL Editor** → **New query**.
2. Pegá todo el contenido de `supabase_el_almacen.sql` y tocá **Run**.
3. Listo: crea tablas, índices, seguridad (RLS), la función `crear_pedido()` y los datos de ejemplo.
   - El script es **re-ejecutable**: al principio borra las tablas si ya existían.

## Qué crea
- **config**: una sola fila con nombre, portada, logo, horarios, cierre manual y ajustes de diseño (JSON).
- **categorias, formas_pago, tipos_envio, estados_pedido**: los catálogos editables.
- **productos** y **promos** (+ `promo_items`): el catálogo de la tienda.
- **clientes**, **usuarios** (login del panel), **pedidos** (+ `pedido_items`).

## Seguridad (RLS) — ya viene configurada
- **Público (anon)**: puede **leer** el escaparate (config, productos, promos, catálogos) y **crear pedidos** solo a través de la función `crear_pedido()` (no puede tocar tablas directamente).
- **Staff (usuarios logueados con Supabase Auth)**: gestiona todo.

## Crear un pedido desde la tienda (ejemplo supabase-js)
```js
const { data, error } = await supabase.rpc('crear_pedido', {
  p_nombre: 'Marta Gómez',
  p_tel: '1145550011',
  p_dir: 'Belgrano 240',
  p_tipo: 'delivery',
  p_pago: 'efectivo',
  p_nota: '',
  p_items: [
    { producto_id: 'p01', nombre: 'Jamón cocido', unidad: 'kg', precio: 12800, qty: 0.5, es_promo: false },
    { producto_id: 'promo1', nombre: 'Promo: Combo Picada', unidad: 'un', precio: 13900, qty: 1, es_promo: true }
  ]
});
// data = número de pedido (n). El estado inicial y el costo de envío los calcula la función.
```

## Leer el catálogo (tienda)
```js
const { data: productos } = await supabase.from('productos').select('*').eq('activo', true).order('orden');
const { data: cfg }       = await supabase.from('config').select('*').single();
```

## Nota importante sobre los usuarios / login
La tabla `usuarios` (con `pass` en texto) replica el login simple de la app **para la demo**.
Para producción real conviene usar **Supabase Auth** (email/clave o teléfono) y una tabla `perfiles`
ligada a `auth.users` con el campo `rol`. Cuando quieras, adapto la app para:
1. Login/registro de clientes con Supabase Auth.
2. Leer/guardar todo contra estas tablas (reemplazando el localStorage).
3. Realtime para que el panel vea los pedidos entrar en vivo.

## Mapa app → base de datos
| App (localStorage)      | Tabla Supabase                    |
|-------------------------|-----------------------------------|
| CONFIG (marca/hero/ui…) | `config` (fila única)             |
| CONFIG.cats             | `categorias`                      |
| CONFIG.pagos            | `formas_pago`                     |
| CONFIG.envios           | `tipos_envio`                     |
| CONFIG.estados          | `estados_pedido`                  |
| CONFIG.promos           | `promos` + `promo_items`          |
| PRODUCTS                | `productos`                       |
| CLIENTES                | `clientes`                        |
| USERS                   | `usuarios`                        |
| ORDERS                  | `pedidos` + `pedido_items`        |

---

# Conectar la app (Fase 1 — ya integrada)

La app ya trae integración con Supabase. Para activarla:

1. Abrí `el-almacen.html` y, arriba de todo del `<script>`, completá:
   ```js
   const SUPABASE_URL = 'https://TU-PROYECTO.supabase.co';
   const SUPABASE_ANON_KEY = 'TU_ANON_KEY';
   ```
   (Supabase → Project Settings → API → Project URL y anon public key.)
2. Guardá y abrí la app. Vas a ver en consola `☁ Catálogo cargado desde Supabase`.

**Qué hace en modo nube (Fase 1):**
- La tienda **lee** nombre, portada, rubros, pagos, envíos, estados, productos y promos **desde Supabase**.
- Al confirmar, el pedido se crea en Supabase con la función `crear_pedido()` (calcula estado inicial, costo de envío y da de alta al cliente).
- Si las credenciales están vacías o falla la conexión, la app usa **datos locales** (todo sigue funcionando como antes).

**Qué falta (Fase 2, cuando quieras):**
- **Supabase Auth** para el panel del dueño/empleados y para clientes, de modo que:
  - la edición del catálogo/config desde el panel **sincronice** a la nube (hoy la RLS bloquea escrituras anónimas, por seguridad);
  - el panel liste los **pedidos en vivo** (Realtime) y el cliente vea **su historial** en cualquier dispositivo.
- Reemplazar la tabla `usuarios` (login simple) por `auth.users` + `perfiles(rol)`.

---

# Fase 2 — Panel del dueño en la nube (ya integrada)

Requisitos: haber corrido `supabase_el_almacen.sql` (Fase 1) y ahora **`supabase_fase2_auth.sql`**.

### Pasos
1. **Correr** `supabase_fase2_auth.sql` en el SQL Editor (crea `perfiles`, roles, RLS por rol y Realtime).
2. **Crear tu usuario**: Authentication → Users → *Add user* (email + contraseña; activá *Auto Confirm*).
3. **Hacerte admin** (SQL Editor, cambiando el email):
   ```sql
   update perfiles set rol='admin'
     where id=(select id from auth.users where email='vos@correo.com');
   ```
   (Para un empleado: `rol='empleado'`.)
4. Abrí la app (con `SUPABASE_URL`/`SUPABASE_ANON_KEY` cargadas). En **Panel** ahora te pide **email + contraseña**.

### Qué hace en modo nube con staff logueado
- **Edición del catálogo/config sincroniza** a Supabase (productos, rubros, pagos, envíos, estados, promos, horarios, diseño, logo…). Altas/ediciones = upsert; borrados = delete.
- **Pedidos**: el panel los **lee de Supabase** y **entran en vivo (Realtime)** — aparece "🔔 ¡Nuevo pedido!" y se actualiza la lista sola.
- **Cambiar estado** (avanzar/cancelar) se guarda en Supabase.
- La **tienda pública** sigue anónima: lee catálogo y crea pedidos por `crear_pedido()` (que ahora también guarda `cliente_uid` si el que compra está logueado).

### Seguridad
- Las escrituras al catálogo/pedidos requieren estar logueado como **staff** (RLS con `is_staff()`); un cliente logueado NO puede tocar el catálogo.
- Los clientes ya pueden ver **solo sus** pedidos (policy por `cliente_uid`) — se aprovechará en la Fase 3.

### Fase 3 (opcional, futura)
- Login/registro de **clientes con Supabase Auth** para que vean su **historial y repitan pedidos** desde cualquier dispositivo (la base ya quedó lista: `cliente_uid` + policies de cliente).

---

# Fase 3 — Clientes con cuenta (ya integrada)

No requiere SQL nuevo: usa lo de la Fase 2 (`perfiles`, `cliente_uid` y policies de cliente).

### Cómo funciona (en modo nube)
- En **Panel**, la pantalla de ingreso ofrece **Iniciar sesión** o **Crear tu cuenta** (cliente).
- El **registro** usa Supabase Auth (`signUp` con email + contraseña + nombre + teléfono). El perfil se crea solo (trigger) con rol `cliente`.
- Al **loguearse**, la app rutea por rol: staff → panel de gestión; cliente → **"Mi cuenta"** con **sus** pedidos (la RLS garantiza que ve solo los propios).
- El cliente puede **repetir** cualquier pedido, y en el **checkout su nombre y teléfono vienen de la cuenta** (bloqueados). Los pedidos que hace logueado quedan ligados a él (`cliente_uid`).
- **En vivo**: si cambiás el estado de su pedido desde el panel, lo ve actualizarse solo (Realtime filtrado por su usuario).
- La sesión se **mantiene** entre recargas y dispositivos.

### Recomendación de configuración (para que el alta sea fluida)
Por defecto Supabase pide **confirmar el email**. Para una demo/tienda de barrio sin fricción:
- Authentication → **Providers → Email** → desactivá **"Confirm email"** (o dejalo activo si querés verificación real; en ese caso, tras registrarse el cliente debe confirmar y luego iniciar sesión).

### Resumen de fases
- **Fase 1**: tienda lee catálogo/config de la nube + crea pedidos (anónimo). ✅
- **Fase 2**: staff con Auth edita catálogo/config, ve pedidos en vivo, cambia estados. ✅
- **Fase 3**: clientes con cuenta ven/repiten su historial desde cualquier dispositivo. ✅
