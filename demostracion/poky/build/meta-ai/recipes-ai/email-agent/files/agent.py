#!/usr/bin/env python3
"""
agent.py — Asistente de ventas automatizado para tienda de electrónica.

Este script corre como servicio systemd en la Raspberry Pi 5.
Su función es monitorear una bandeja de Gmail, leer los correos entrantes,
consultar al modelo de lenguaje (Ollama) para generar una respuesta apropiada
basada en el inventario de la tienda, y enviar esa respuesta al remitente.

Dependencias externas:
    - requests: para llamar a la API REST de Ollama
    - El resto (imaplib, smtplib, email) son parte de la librería estándar de Python
"""

import imaplib       # Protocolo IMAP: permite leer correos de un servidor de email
import smtplib       # Protocolo SMTP: permite enviar correos
import email         # Parseo de mensajes de email (headers, cuerpo, adjuntos)
import time          # Para las pausas entre revisiones de la bandeja
import logging       # Para escribir el log de actividad en /var/log/email-agent.log
import requests      # Para hacer peticiones HTTP a la API de Ollama
from email.mime.text      import MIMEText        # Construye el cuerpo del email de respuesta
from email.mime.multipart import MIMEMultipart   # Construye el email completo (headers + cuerpo)
from email.header         import decode_header   # Decodifica asuntos y remitentes codificados

# Rutas de los archivos de configuración en el sistema de la Pi
CONFIG_FILE     = "/etc/email-agent/config.env"   # Credenciales y parámetros del agente
STORE_INFO_FILE = "/etc/email-agent/store_info.md" # Inventario y datos de la tienda
LOG_FILE        = "/var/log/email-agent.log"        # Archivo de log de actividad


# ─────────────────────────────────────────────────────────────────
# CARGA DE ARCHIVOS DE CONFIGURACIÓN
# ─────────────────────────────────────────────────────────────────

def load_config():
    """
    Lee el archivo config.env y devuelve sus valores como un diccionario.

    El archivo tiene el formato CLAVE=valor, una por línea.
    Las líneas que empiezan con # son comentarios y se ignoran.
    Las líneas vacías también se ignoran.

    Ejemplo de contenido del archivo:
        GMAIL_USER=ventas@tecnopartes.cr
        GMAIL_APP_PASSWORD=abcdabcdabcdabcd
        CHECK_INTERVAL=60
        OLLAMA_MODEL=qwen2.5:3b

    Retorna un dict como:
        {'GMAIL_USER': 'ventas@tecnopartes.cr', 'CHECK_INTERVAL': '60', ...}
    """
    config = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            # Ignorar líneas vacías y comentarios
            if line and not line.startswith('#') and '=' in line:
                # Dividir solo en el primer '=' para manejar valores que contengan '='
                key, val = line.split('=', 1)
                config[key.strip()] = val.strip()
    return config


def load_store_info():
    """
    Lee el archivo store_info.md completo y lo devuelve como una cadena de texto.

    Este archivo contiene el inventario de la tienda, datos de contacto,
    ubicación y horarios. Se lee completo y se inyecta en el prompt del LLM
    para que el modelo tenga el contexto necesario al responder.

    El archivo se lee en cada ciclo del agente (no solo al arrancar), lo que
    permite editar el inventario en la Pi sin necesidad de reiniciar el servicio.
    """
    with open(STORE_INFO_FILE) as f:
        return f.read()


# ─────────────────────────────────────────────────────────────────
# UTILIDADES PARA PROCESAR EMAILS ENTRANTES
# ─────────────────────────────────────────────────────────────────

def decode_str(s):
    """
    Decodifica el campo 'From' o 'Subject' de un email a texto plano.

    Los emails pueden codificar estos campos usando base64 o quoted-printable
    cuando contienen caracteres especiales (tildes, ñ, etc.).
    Por ejemplo, el asunto "Compra de componentes" podría llegar como:
        =?UTF-8?Q?Compra_de_componentes?=

    Esta función detecta ese encoding y lo convierte a texto legible.
    Si el campo ya es texto plano, lo devuelve sin cambios.
    """
    decoded_parts = decode_header(s)
    parts = []
    for part, enc in decoded_parts:
        if isinstance(part, bytes):
            # El fragmento está codificado — decodificarlo con el charset indicado
            parts.append(part.decode(enc or 'utf-8', errors='replace'))
        else:
            # El fragmento ya es texto plano
            parts.append(part)
    return ''.join(parts)


def get_email_body(msg):
    """
    Extrae el cuerpo en texto plano de un mensaje de email.

    Los emails modernos pueden tener múltiples partes (multipart):
    una versión en texto plano y otra en HTML. Este agente solo necesita
    el texto plano para enviarlo al LLM.

    Si el email es simple (no multipart), extrae el contenido directamente.
    Si es multipart, itera sobre las partes hasta encontrar 'text/plain'.

    En ambos casos, detecta el charset del mensaje (UTF-8, ISO-8859-1, etc.)
    para decodificar correctamente los bytes a texto.

    Devuelve el cuerpo como string, o cadena vacía si no se puede extraer.
    """
    if msg.is_multipart():
        # Iterar sobre todas las partes del mensaje
        for part in msg.walk():
            if part.get_content_type() == 'text/plain':
                payload = part.get_payload(decode=True)
                if payload:
                    charset = part.get_content_charset() or 'utf-8'
                    return payload.decode(charset, errors='replace')
    else:
        # Email simple con una sola parte
        payload = msg.get_payload(decode=True)
        if payload:
            charset = msg.get_content_charset() or 'utf-8'
            return payload.decode(charset, errors='replace')
    return ""


def extract_sender_address(from_header):
    """
    Extrae únicamente la dirección de email del campo 'From'.

    El campo From puede venir en dos formatos:
        1. Solo dirección:   gabo@gmail.com
        2. Nombre + ángulos: Gabriel Pérez <gabo@gmail.com>

    Esta función detecta el formato y devuelve siempre solo la dirección,
    que es lo que se necesita para enviar la respuesta.
    """
    if '<' in from_header and '>' in from_header:
        # Formato "Nombre <email>" — extraer lo que está entre < y >
        return from_header.split('<')[1].split('>')[0].strip()
    # Formato solo dirección — devolver directamente
    return from_header.strip()


# ─────────────────────────────────────────────────────────────────
# CONSTRUCCIÓN DEL PROMPT Y CONSULTA AL LLM
# ─────────────────────────────────────────────────────────────────

def build_prompt(store_info, personality, subject, body):
    """
    Construye el texto completo que se envía al modelo de lenguaje (LLM).

    El prompt tiene cuatro partes:
        1. Definición del rol del asistente
        2. La información de la tienda (inventario, sucursal, horarios)
        3. Las reglas de comportamiento
        4. El correo del cliente y la instrucción de respuesta

    Por qué el inventario va antes de las reglas:
        El modelo lee el prompt de arriba a abajo. Si el inventario va primero,
        el modelo lo tiene en contexto cuando lee las reglas. Si las reglas
        fueran primero, el modelo podría "olvidarlas" al leer 50 líneas de inventario.

    Por qué se trunca el cuerpo del correo a 600 caracteres:
        Los modelos pequeños como qwen2.5:3b tienen un límite de contexto.
        Un cuerpo de email muy largo consumiría tokens que se necesitan para
        el inventario y las reglas. En la práctica, los correos de clientes
        son cortos y 600 caracteres son más que suficientes.

    La variable 'personality' viene del archivo config.env y permite cambiar
    el tono del asistente sin modificar el código.
    """
    # Limitar el cuerpo del correo para no desperdiciar espacio de contexto
    body_truncated = body.strip()[:600]

    return f"""Eres un vendedor de TecnoPartes S.A. Responde el email del cliente usando solo la información de la lista de abajo.

LISTA DE LA TIENDA:
{store_info}

REGLAS:
1. Para cada producto que pida el cliente, busca su nombre en la lista de arriba.
2. Si dice DISPONIBLE: confirma que está disponible y da el precio exacto de la lista.
3. Si dice AGOTADO: indica que está agotado. No inventes precio ni fecha.
4. Si el producto no está en la lista: indica que no lo manejamos. No lo inventes.
5. Si piden varias unidades de algo DISPONIBLE: multiplica el precio por la cantidad.
6. Para ubicación y horarios: usa solo lo que dice la lista. No inventes direcciones.
7. Escribe la respuesta como un email normal. No copies el formato de la lista.

EMAIL DEL CLIENTE:
Asunto: {subject}
Mensaje: {body_truncated}

{personality}
Respuesta:"""


def query_ollama(prompt, model, ollama_url, logger):
    """
    Envía el prompt a la API de Ollama y espera la respuesta completa del LLM.

    Ollama expone una API REST en el puerto 11434. El endpoint /api/generate
    acepta un prompt y devuelve el texto generado por el modelo.

    Parámetros importantes de la petición:
        stream=False:
            Con True, Ollama devuelve tokens uno a uno (streaming).
            Con False, espera a generar toda la respuesta antes de devolverla.
            Se usa False porque es más simple de manejar en este contexto.

        temperature=0.1:
            Controla cuánta "creatividad" tiene el modelo al generar texto.
            0.0 = completamente determinista (siempre la misma respuesta).
            1.0 = muy creativo, más propenso a inventar información.
            0.1 es el valor mínimo efectivo: el modelo es casi determinista,
            lo que reduce drásticamente la tendencia a inventar datos.

        num_predict=1200:
            Límite máximo de tokens (palabras/fragmentos) en la respuesta.
            Con 600 era insuficiente para responder preguntas múltiples
            (productos + ubicación + horarios). Con 1200 hay margen suficiente.

        timeout=600:
            10 minutos de espera máxima. qwen2.5:3b en CPU puede tardar
            entre 5 y 9 minutos por respuesta según la longitud del prompt.
    """
    url = f"{ollama_url}/api/generate"
    payload = {
        "model":  model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": 1200,
            "temperature": 0.1
        }
    }

    logger.info(f"Enviando prompt a Ollama ({len(prompt)} chars)...")
    start    = time.time()
    response = requests.post(url, json=payload, timeout=600)
    response.raise_for_status()  # Lanza excepción si Ollama devuelve error HTTP

    elapsed = time.time() - start
    result  = response.json()["response"].strip()
    logger.info(f"Respuesta recibida en {elapsed:.1f}s — {len(result)} chars")
    return result


# ─────────────────────────────────────────────────────────────────
# INICIALIZACIÓN Y WARMUP DE OLLAMA
# ─────────────────────────────────────────────────────────────────

def warmup_ollama(model, ollama_url, logger):
    """
    Hace una inferencia pequeña para confirmar que el modelo está cargado en RAM.

    Por qué es necesario:
        El agente y Ollama arrancan al mismo tiempo con systemd.
        Ollama puede tardar 30-60 segundos en cargar el modelo en RAM después
        de que su API ya responde. Si el agente hace una solicitud real antes
        de que el modelo esté listo, la inferencia queda colgada silenciosamente
        o falla sin un error claro.

        El warmup resuelve esto enviando un prompt trivial ("Di solo: OK")
        que fuerza al modelo a cargarse completamente. Una vez que el warmup
        termina, el modelo está listo para procesar correos reales.
    """
    logger.info("Calentando el modelo con inferencia de prueba...")
    url     = f"{ollama_url}/api/generate"
    payload = {
        "model":   model,
        "prompt":  "Di solo: OK",
        "stream":  False,
        "options": {"num_predict": 5}
    }
    try:
        start    = time.time()
        response = requests.post(url, json=payload, timeout=180)
        response.raise_for_status()
        logger.info(f"Warmup completado en {time.time()-start:.1f}s. Modelo listo.")
        return True
    except Exception as e:
        logger.error(f"Warmup falló: {e}")
        return False


def wait_for_ollama(ollama_url, logger, retries=15, delay=20):
    """
    Espera a que la API de Ollama esté respondiendo antes de continuar.

    Consulta el endpoint /api/tags que devuelve la lista de modelos instalados.
    Si responde con HTTP 200, Ollama está activo.

    Reintenta hasta 'retries' veces con 'delay' segundos entre cada intento.
    Si después de todos los intentos Ollama no responde, el agente aborta.

    Por qué esperar:
        El servicio email-agent.service tiene 'Requires=ollama.service' en
        su archivo de unidad, lo que garantiza que systemd arranca Ollama primero.
        Sin embargo, "arrancado" no significa "listo para inferencia". Esta función
        completa esa espera de forma activa.
    """
    for i in range(retries):
        try:
            r = requests.get(f"{ollama_url}/api/tags", timeout=5)
            if r.status_code == 200:
                logger.info("API de Ollama responde correctamente.")
                return True
        except Exception:
            pass
        logger.info(f"Esperando Ollama... intento {i+1}/{retries}")
        time.sleep(delay)
    logger.error("Ollama no respondió después de todos los intentos.")
    return False


# ─────────────────────────────────────────────────────────────────
# ENVÍO DE RESPUESTA POR CORREO
# ─────────────────────────────────────────────────────────────────

def send_reply(config, to_address, subject, body, logger):
    """
    Envía la respuesta generada por el LLM al remitente via Gmail SMTP.

    Protocolo utilizado: SMTP sobre SSL en el puerto 465.
        - SMTP_SSL establece la conexión cifrada desde el inicio.
        - Puerto 465 es el estándar para SMTP con SSL implícito.
        - Se usa la App Password de Google (no la contraseña normal),
          porque IMAP/SMTP con 2FA requiere esta contraseña especial.

    El asunto de la respuesta:
        Si el asunto original es "Consulta de stock", la respuesta lleva
        "Re: Consulta de stock". Si ya empieza con "Re:", no se duplica.

    Manejo de errores:
        SMTPAuthenticationError se captura por separado porque indica un
        problema de credenciales (App Password incorrecta), que es diferente
        a un error de red o de envío. Se loguea con un mensaje específico
        para facilitar el diagnóstico.
    """
    # Agregar "Re: " al asunto si no lo tiene ya
    reply_subject = subject if subject.startswith("Re:") else f"Re: {subject}"

    # Construir el mensaje de email con sus headers
    msg = MIMEMultipart()
    msg['From']    = config['GMAIL_USER']
    msg['To']      = to_address
    msg['Subject'] = reply_subject
    # utf-8 asegura que las tildes y la ñ se envíen correctamente
    msg.attach(MIMEText(body, 'plain', 'utf-8'))

    logger.info(f"Enviando respuesta a {to_address}...")
    try:
        # Abrir conexión SSL con Gmail SMTP y enviar
        with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=30) as server:
            server.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
            server.send_message(msg)
            logger.info("Correo enviado correctamente.")
    except smtplib.SMTPAuthenticationError as e:
        logger.error(f"Error de autenticación SMTP: {e}")
        logger.error("Verificar GMAIL_USER y GMAIL_APP_PASSWORD en config.env")
        raise
    except Exception as e:
        logger.error(f"Error al enviar correo: {type(e).__name__}: {e}")
        raise


# ─────────────────────────────────────────────────────────────────
# CICLO PRINCIPAL DE PROCESAMIENTO DE CORREOS
# ─────────────────────────────────────────────────────────────────

def process_unread_emails(config, store_info, logger):
    """
    Conecta a Gmail via IMAP, procesa todos los correos no leídos y responde a cada uno.

    Flujo completo para cada correo:
        1. Conectar a Gmail usando IMAP sobre SSL (puerto 993)
        2. Autenticar con la App Password de Google
        3. Seleccionar la bandeja de entrada (inbox)
        4. Buscar correos con flag UNSEEN (no leídos)
        5. Por cada correo no leído:
            a. Descargarlo completo (headers + cuerpo)
            b. Extraer remitente, asunto y cuerpo en texto plano
            c. Construir el prompt con el inventario de la tienda
            d. Enviar el prompt a Ollama y esperar la respuesta del LLM
            e. Enviar la respuesta al remitente via SMTP
            f. Marcar el correo como leído (flag \\Seen)
        6. Cerrar la conexión IMAP

    Por qué marcar como leído aunque haya error:
        Si un correo falla al procesarse, se marca como leído igualmente.
        Esto evita un bucle infinito donde el mismo correo fallido se
        reintenta en cada ciclo. Si se necesita reintentar un correo,
        se puede marcar manualmente como no leído en Gmail.

    Por qué leer store_info fuera de esta función:
        store_info se lee en cada ciclo del bucle principal de main(),
        no aquí. Esto permite que los cambios en el inventario (editando
        store_info.md en la Pi) tomen efecto sin reiniciar el servicio.
    """
    ollama_url  = config.get('OLLAMA_URL', 'http://localhost:11434')
    model       = config.get('OLLAMA_MODEL', 'qwen2.5:3b')
    personality = config.get('PERSONALITY', 'Firma como "Equipo de Ventas - TecnoPartes S.A."')

    logger.info("Conectando a Gmail IMAP...")
    try:
        # IMAP4_SSL usa el puerto 993 con TLS desde el inicio
        mail = imaplib.IMAP4_SSL('imap.gmail.com', timeout=30)
    except Exception as e:
        logger.error(f"No se pudo conectar a Gmail: {type(e).__name__}: {e}")
        return

    try:
        mail.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        logger.info("Autenticación IMAP exitosa.")
    except imaplib.IMAP4.error as e:
        logger.error(f"Error de autenticación IMAP: {e}")
        logger.error("Verificar credenciales en /etc/email-agent/config.env")
        mail.logout()
        return

    # Seleccionar la bandeja de entrada
    mail.select('inbox')

    # Buscar correos no leídos (UNSEEN = sin el flag \Seen)
    status, messages = mail.search(None, 'UNSEEN')
    if status != 'OK' or not messages[0]:
        logger.info("Sin correos nuevos.")
        mail.logout()
        return

    email_ids = messages[0].split()
    logger.info(f"Correos no leídos encontrados: {len(email_ids)}")

    for email_id in email_ids:
        try:
            # RFC822 descarga el mensaje completo incluyendo todos los headers
            status, data = mail.fetch(email_id, '(RFC822)')
            if status != 'OK':
                logger.error(f"No se pudo descargar el correo {email_id}")
                continue

            # Parsear el mensaje de bytes a objeto email de Python
            raw_email = data[0][1]
            msg       = email.message_from_bytes(raw_email)

            sender  = msg.get('From', '')
            subject = decode_str(msg.get('Subject', '(Sin asunto)'))
            body    = get_email_body(msg)

            sender_address = extract_sender_address(sender)
            logger.info(f"--- De: {sender_address} | Asunto: {subject}")
            logger.info(f"    Longitud del cuerpo: {len(body)} caracteres")

            # Paso 1: construir prompt y consultar al LLM
            prompt     = build_prompt(store_info, personality, subject, body)
            reply_text = query_ollama(prompt, model, ollama_url, logger)

            # Paso 2: enviar la respuesta al remitente
            send_reply(config, sender_address, subject, reply_text, logger)

            # Paso 3: marcar como leído para no procesarlo en el próximo ciclo
            mail.store(email_id, '+FLAGS', '\\Seen')
            logger.info(f"Correo {email_id} marcado como leído.")

        except Exception as e:
            logger.error(f"Error procesando correo {email_id}: {type(e).__name__}: {e}")
            # Marcar como leído para evitar bucles de reintento infinito
            try:
                mail.store(email_id, '+FLAGS', '\\Seen')
                logger.info(f"Correo {email_id} marcado como leído (tras error).")
            except Exception:
                pass

    mail.logout()
    logger.info("Sesión IMAP cerrada.")


# ─────────────────────────────────────────────────────────────────
# PUNTO DE ENTRADA PRINCIPAL
# ─────────────────────────────────────────────────────────────────

def main():
    """
    Punto de entrada del script. Configura el logging y arranca el bucle principal.

    Secuencia de arranque:
        1. Configurar el sistema de logging (archivo + formato de timestamp)
        2. Cargar la configuración desde config.env
        3. Esperar a que la API de Ollama responda (wait_for_ollama)
        4. Hacer el warmup del modelo (cargar en RAM)
        5. Entrar al bucle infinito: revisar correos cada CHECK_INTERVAL segundos

    El bucle principal:
        En cada iteración se lee store_info.md fresco del disco. Esto permite
        actualizar el inventario de la tienda sin reiniciar el agente: basta con
        editar el archivo en la Pi y el cambio toma efecto en el siguiente ciclo.

    Manejo de errores en el bucle:
        Si una iteración completa falla (por ejemplo, pérdida de conexión de red),
        el error se loguea y el bucle continúa en el siguiente ciclo. El agente
        nunca se detiene por un error puntual.
    """
    # Configurar logging: escribe en archivo con timestamp en cada línea
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s'
    )
    logger = logging.getLogger(__name__)
    logger.info("=== Email agent iniciado ===")

    # Cargar configuración (credenciales, modelo, intervalo de revisión)
    config         = load_config()
    check_interval = int(config.get('CHECK_INTERVAL', '60'))
    ollama_url     = config.get('OLLAMA_URL', 'http://localhost:11434')
    model          = config.get('OLLAMA_MODEL', 'qwen2.5:3b')

    # Esperar a que Ollama esté disponible antes de procesar correos
    if not wait_for_ollama(ollama_url, logger):
        logger.error("Abortando: Ollama no disponible.")
        return

    # Calentar el modelo para asegurar que está cargado en RAM
    if not warmup_ollama(model, ollama_url, logger):
        logger.warning("Warmup falló — el primer correo puede tardar más de lo normal.")

    logger.info(f"Agente listo. Revisando bandeja cada {check_interval} segundos.")

    # Bucle principal: corre indefinidamente hasta que el proceso se detenga
    while True:
        try:
            # Leer el inventario fresco en cada ciclo para reflejar cambios
            store_info = load_store_info()
            process_unread_emails(config, store_info, logger)
        except Exception as e:
            logger.error(f"Error en ciclo principal: {type(e).__name__}: {e}")

        # Esperar antes del próximo ciclo de revisión
        time.sleep(check_interval)


# El bloque if __name__ == '__main__' asegura que main() solo se ejecute
# cuando el script se corre directamente, no cuando se importa como módulo
if __name__ == '__main__':
    main()
