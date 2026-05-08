#!/usr/bin/env python3
"""
agent.py — Asistente de ventas automatizado para TecnoPartes S.A.

Este script corre como un servicio de systemd en la Raspberry Pi 5.
Su trabajo es monitorear una bandeja de Gmail, leer los correos entrantes,
consultar al modelo de lenguaje (Ollama) para generar una respuesta basada
en el inventario de la tienda, y enviar esa respuesta al remitente.

Dependencias externas (no vienen con Python estándar):
    - requests: para hacer llamadas HTTP a la API de Ollama

Todo lo demás (imaplib, smtplib, email, logging) es parte de la
libreria estandar de Python y no requiere instalacion adicional.
"""

import imaplib   # Protocolo IMAP: permite leer correos desde un servidor de email
import smtplib   # Protocolo SMTP: permite enviar correos
import email     # Herramientas para parsear el contenido de un mensaje de email
import time      # Para medir tiempos y hacer pausas entre revisiones
import logging   # Para escribir mensajes de actividad en el archivo de log
import requests  # Para hacer peticiones HTTP a la API REST de Ollama

from email.mime.text      import MIMEText        # Crea el cuerpo del email de respuesta
from email.mime.multipart import MIMEMultipart   # Arma el email completo con sus headers
from email.header         import decode_header   # Decodifica asuntos con caracteres especiales

# Rutas fijas de los archivos de configuracion en la Pi
CONFIG_FILE     = "/etc/email-agent/config.env"     # Credenciales y parametros del agente
STORE_INFO_FILE = "/etc/email-agent/store_info.md"  # Inventario y datos de la tienda
LOG_FILE        = "/var/log/email-agent.log"        # Archivo donde se registra la actividad


# ===================================================================
# BLOQUE 1 — CARGA DE ARCHIVOS DE CONFIGURACION
# ===================================================================

def load_config():
    """
    Lee el archivo config.env y devuelve un diccionario con todos sus valores.

    El archivo tiene el formato CLAVE=valor, una por linea.
    Las lineas vacias y las que empiezan con # se ignoran.

    Ejemplo de contenido:
        GMAIL_USER=ventas@tecnopartes.cr
        GMAIL_APP_PASSWORD=abcdabcdabcdabcd
        OLLAMA_MODEL=gemma3:4b

    Retorna un diccionario como:
        {'GMAIL_USER': 'ventas@...', 'OLLAMA_MODEL': 'gemma3:4b', ...}
    """
    config = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            # Ignorar lineas vacias y comentarios
            if line and not line.startswith('#') and '=' in line:
                # split con maxsplit=1 divide solo en el primer '='
                # para manejar valores que puedan contener '=' (como contrasenas)
                key, val = line.split('=', 1)
                config[key.strip()] = val.strip()
    return config


def load_store_info():
    """
    Lee el archivo store_info.md completo y lo devuelve como texto.

    Este archivo contiene el inventario, precios, datos de la sucursal
    y horarios de la tienda. Se inyecta completo en el prompt del LLM
    para que el modelo tenga todo el contexto necesario al responder.

    Se llama en CADA ciclo del bucle principal, no solo al arrancar.
    Esto permite editar el inventario en la Pi sin reiniciar el servicio:
    el cambio toma efecto en el proximo ciclo de revision automaticamente.
    """
    with open(STORE_INFO_FILE) as f:
        return f.read()


# ===================================================================
# BLOQUE 2 — UTILIDADES PARA PROCESAR EMAILS ENTRANTES
# ===================================================================

def decode_str(s):
    """
    Decodifica campos de email que vienen codificados.

    Los campos Subject y From pueden venir en formato codificado cuando
    contienen tildes, n con tilde u otros caracteres especiales. Por ejemplo:
        =?UTF-8?Q?Consulta_de_componentes?=

    decode_header() los convierte a texto legible.
    Si el campo ya es texto plano, lo retorna sin cambios.
    """
    parts = []
    for part, enc in decode_header(s):
        if isinstance(part, bytes):
            # El fragmento esta codificado — decodificar con su charset
            parts.append(part.decode(enc or 'utf-8', errors='replace'))
        else:
            # Ya es texto plano
            parts.append(part)
    return ''.join(parts)


def get_email_body(msg):
    """
    Extrae unicamente el cuerpo en texto plano de un mensaje de email.

    Los emails modernos son "multipart": traen el mismo contenido en
    dos versiones, una en texto plano y otra en HTML.
    El agente solo necesita el texto plano para enviarlo al LLM.

    Si el email es simple (no multipart), extrae el contenido directo.
    Si no encuentra ninguna parte de texto, retorna una cadena vacia.
    """
    if msg.is_multipart():
        # Recorrer todas las partes del mensaje buscando text/plain
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
    Extrae solo la direccion de email del campo From.

    El campo From puede venir en dos formatos:
        1. Solo la direccion:       cliente@gmail.com
        2. Nombre mas la direccion: Juan Perez <cliente@gmail.com>

    Esta funcion detecta el formato y siempre retorna solo la direccion,
    que es lo que se necesita para enviar la respuesta correctamente.
    """
    if '<' in from_header and '>' in from_header:
        # Formato "Nombre <email>" — extraer lo que esta entre < y >
        return from_header.split('<')[1].split('>')[0].strip()
    # Formato solo direccion — retornar directamente
    return from_header.strip()


# ===================================================================
# BLOQUE 3 — CONSTRUCCION DEL PROMPT Y CONSULTA AL LLM
# ===================================================================

def build_prompt(store_info, personality, subject, body):
    """
    Construye el texto completo que se enviara al modelo de lenguaje.

    El LLM no sabe nada de la tienda por si solo. Toda la informacion
    se la proporcionamos en este prompt. El modelo lee el texto y genera
    una respuesta basandose EXCLUSIVAMENTE en lo que recibe aqui.

    Estructura del prompt:
        1. Rol: define quien es el asistente
        2. Inventario: el contenido completo de store_info.md
        3. Reglas: instrucciones especificas para no inventar informacion
        4. Correo del cliente: asunto y cuerpo (truncado a 600 caracteres)
        5. Personalidad: tono y firma (viene de config.env)

    Por que truncar el cuerpo a 600 caracteres:
        Los modelos tienen un limite de tokens. Un email muy largo
        consumiria tokens que se necesitan para el inventario y las reglas.

    Por que las reglas son tan especificas:
        Los modelos pequenos (3-4B parametros) tienden a alucinar,
        es decir, inventan informacion plausible cuando no la encuentran.
        Reglas explicitas como "si no esta en la lista, di que no lo manejamos"
        reducen significativamente ese comportamiento.
    """
    # Limitar el cuerpo del correo a 600 caracteres
    body_truncated = body.strip()[:600]

    return f"""Eres un vendedor de TecnoPartes S.A. Responde el email del cliente usando exclusivamente la informacion textual de la lista de abajo.

LISTA DE LA TIENDA:
{store_info}

REGLAS:
1. Para cada producto que pida el cliente, busca su nombre en la lista de arriba.
2. Luego de encontrar el nombre exacto del producto, buscar la palabra "DISPONIBLE" o "AGOTADO".
3. Si dice DISPONIBLE: confirma que esta disponible y da el precio exacto de la lista.
4. Si dice AGOTADO: indica que esta agotado. No inventes precio ni fecha.
5. Si el producto no esta en la lista: indica que no lo manejamos. No lo inventes.
6. Para ubicacion y horarios: usa solo lo que dice la lista. No inventes direcciones.
7. Escribe la respuesta como un email normal.
8. Asegurate de que toda la informacion que brindes exista dentro de la "LISTA DE LA TIENDA". Si no encuentras algo dentro de esta, indica que no lo manejamos.

EMAIL DEL CLIENTE:
Asunto: {subject}
Mensaje: {body_truncated}

{personality}
Respuesta:"""


def query_ollama(prompt, model, ollama_url, logger):
    """
    Envia el prompt a la API de Ollama y espera la respuesta completa.

    Ollama expone una API REST en el puerto 11434.
    El endpoint /api/generate acepta el prompt y retorna el texto generado.

    Parametros importantes:
        stream=False:
            Con True Ollama envia tokens uno a uno conforme los genera.
            Con False espera a terminar y envia la respuesta completa.
            Se usa False para simplificar el procesamiento.

        temperature=0.1:
            Controla la creatividad del modelo.
            0.0 = completamente deterministico, siempre la misma respuesta.
            1.0 = muy creativo, propenso a inventar informacion.
            0.1 es casi deterministico: el modelo se cine al contexto
            dado, reduciendo las alucinaciones de datos inventados.

        num_predict=1200:
            Limite maximo de tokens en la respuesta.
            Con poco espacio el modelo truncaba antes de responder
            todas las preguntas (productos + ubicacion + horarios).

        timeout=600:
            10 minutos de espera maxima.
            qwen3:4b en CPU puro puede tardar entre 5 y 9 minutos.
    """
    url = f"{ollama_url}/api/generate"
    payload = {
        "model":  model,
        "prompt": prompt,
        "stream": False,
        "options": {"num_predict": 1200, "temperature": 0.1}
    }

    logger.info(f"Enviando prompt a Ollama ({len(prompt)} chars)...")
    start    = time.time()
    response = requests.post(url, json=payload, timeout=600)

    # raise_for_status lanza excepcion si el servidor retorno un error HTTP
    # (por ejemplo 404 si el modelo no esta cargado, 500 si hay un fallo interno)
    response.raise_for_status()

    result = response.json()["response"].strip()
    logger.info(f"Respuesta en {time.time()-start:.1f}s")
    return result


# ===================================================================
# BLOQUE 4 — INICIALIZACION Y WARMUP DE OLLAMA
# ===================================================================

def warmup_ollama(model, ollama_url, logger):
    """
    Hace una inferencia pequena para confirmar que el modelo esta en RAM.

    Problema que resuelve:
        Ollama arranca como servicio y su API responde en segundos,
        pero cargar el modelo completo en RAM puede tardar 30-60 segundos mas.
        Si el agente envia un correo real antes de que el modelo este listo,
        la inferencia falla silenciosamente con un error 404.

    Solucion:
        Enviar un prompt trivial con num_predict=5 (pocas palabras).
        Esto fuerza la carga completa del modelo en RAM.
        Cuando retorna exitosamente el modelo esta listo para correos reales.

    Si el warmup falla el agente continua de todas formas.
    Es mejor intentar procesar correos que bloquearse indefinidamente.
    """
    logger.info("Calentando el modelo...")
    payload = {
        "model":   model,
        "prompt":  "Di solo: OK",
        "stream":  False,
        "options": {"num_predict": 5}
    }
    try:
        response = requests.post(
            f"{ollama_url}/api/generate",
            json=payload,
            timeout=180  # 3 minutos maximo para el warmup
        )
        response.raise_for_status()
        logger.info("Warmup completado.")
        return True
    except Exception as e:
        logger.error(f"Warmup fallo: {e}")
        return False


def wait_for_ollama(ollama_url, logger, retries=15, delay=20):
    """
    Espera a que la API de Ollama este respondiendo antes de continuar.

    Ollama y el agente arrancan juntos con systemd. Aunque el servicio
    del agente tiene Requires=ollama.service, systemd solo garantiza
    que Ollama arranco, no que su API HTTP este lista para recibir peticiones.
    Esta funcion resuelve esa condicion de carrera.

    Logica:
        Consulta /api/tags (lista de modelos instalados) cada 20 segundos.
        Reintenta hasta 15 veces (5 minutos en total).
        Si responde HTTP 200 el servidor esta activo.
        Si todos los intentos fallan el agente aborta.
    """
    for i in range(retries):
        try:
            r = requests.get(f"{ollama_url}/api/tags", timeout=5)
            if r.status_code == 200:
                logger.info("Ollama responde.")
                return True
        except Exception:
            # Ollama aun no esta listo, intentar de nuevo
            pass
        logger.info(f"Esperando Ollama... {i+1}/{retries}")
        time.sleep(delay)

    logger.error("Ollama no respondio.")
    return False


# ===================================================================
# BLOQUE 5 — ENVIO DE RESPUESTA POR CORREO
# ===================================================================

def send_reply(config, to_address, subject, body, logger):
    """
    Envia la respuesta generada por el LLM al remitente via Gmail SMTP.

    Protocolo: SMTP sobre SSL en el puerto 465.
        SMTP_SSL establece la conexion cifrada desde el inicio.
        Se usa App Password de Google, no la contrasena normal.
        Google bloquea IMAP/SMTP con contrasena normal cuando 2FA esta activo.

    El asunto lleva "Re: " al principio para que el cliente sepa
    que es una respuesta a su correo original.
    utf-8 garantiza que tildes y caracteres especiales se transmitan bien.
    """
    # Agregar "Re: " al asunto si no lo tiene ya
    reply_subject = subject if subject.startswith("Re:") else f"Re: {subject}"

    # Construir el mensaje de email con sus headers
    msg = MIMEMultipart()
    msg['From']    = config['GMAIL_USER']
    msg['To']      = to_address
    msg['Subject'] = reply_subject
    msg.attach(MIMEText(body, 'plain', 'utf-8'))

    logger.info(f"Enviando a {to_address}...")
    # SMTP_SSL abre la conexion ya cifrada desde el inicio (puerto 465)
    with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=30) as server:
        server.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        server.send_message(msg)
    logger.info("Enviado.")


# ===================================================================
# BLOQUE 6 — CICLO PRINCIPAL DE PROCESAMIENTO DE CORREOS
# ===================================================================

def process_unread_emails(config, store_info, logger):
    """
    Conecta a Gmail via IMAP, lee todos los correos no leidos,
    genera una respuesta con el LLM para cada uno y la envia.

    IMAP (Internet Message Access Protocol):
        Permite leer correos dejandolos en el servidor.
        Se conecta por SSL en el puerto 993.

    Flag UNSEEN:
        Gmail marca internamente cada correo con flags.
        UNSEEN = no leido. Se buscan solo estos para no reprocesar correos.

    Flag Seen:
        Al terminar cada correo se marca como leido con el flag Seen.
        Esto evita que aparezca como UNSEEN en el proximo ciclo.

    Manejo de errores:
        Si un correo falla se marca como leido igualmente.
        Evita bucles infinitos donde el mismo correo falla repetidamente.
    """
    ollama_url  = config.get('OLLAMA_URL', 'http://localhost:11434')
    model       = config.get('OLLAMA_MODEL', 'gemma3:4b')
    personality = config.get('PERSONALITY', 'Firma como "Equipo de Ventas - TecnoPartes S.A."')

    # ── Conexion IMAP ─────────────────────────────────────────────
    logger.info("Conectando a Gmail IMAP...")
    try:
        # Conexion segura al servidor de Gmail en el puerto 993
        mail = imaplib.IMAP4_SSL('imap.gmail.com', timeout=30)
    except Exception as e:
        logger.error(f"Fallo conexion: {e}"); return

    try:
        mail.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        logger.info("Autenticacion IMAP ok.")
    except imaplib.IMAP4.error as e:
        logger.error(f"Error auth IMAP: {e}"); mail.logout(); return

    # Seleccionar la carpeta de entrada
    mail.select('inbox')

    # ── Buscar correos no leidos ──────────────────────────────────
    # search retorna lista de IDs de correos que coinciden con UNSEEN
    status, messages = mail.search(None, 'UNSEEN')
    if status != 'OK' or not messages[0]:
        logger.info("Sin correos nuevos."); mail.logout(); return

    # messages[0] es una cadena de IDs: b'1 2 3' -> [b'1', b'2', b'3']
    email_ids = messages[0].split()
    logger.info(f"Correos no leidos: {len(email_ids)}")

    # ── Procesar cada correo no leido ─────────────────────────────
    for email_id in email_ids:
        try:
            # RFC822: descarga el mensaje completo con headers y cuerpo
            status, data = mail.fetch(email_id, '(RFC822)')
            if status != 'OK': continue

            # Parsear los bytes a un objeto email de Python
            msg = email.message_from_bytes(data[0][1])

            # Extraer los campos del mensaje
            sender  = msg.get('From', '')
            subject = decode_str(msg.get('Subject', '(Sin asunto)'))
            body    = get_email_body(msg)
            sender_address = extract_sender_address(sender)
            logger.info(f"--- De: {sender_address} | {subject}")

            # Paso 1: construir el prompt con inventario + correo del cliente
            prompt = build_prompt(store_info, personality, subject, body)

            # Paso 2: enviar el prompt a Ollama y esperar la respuesta del LLM
            reply_text = query_ollama(prompt, model, ollama_url, logger)

            # Paso 3: enviar la respuesta al remitente por Gmail SMTP
            send_reply(config, sender_address, subject, reply_text, logger)

            # Paso 4: marcar el correo como leido para no reprocesarlo
            # '+FLAGS' agrega el flag al correo sin borrar los existentes
            mail.store(email_id, '+FLAGS', '\\Seen')
            logger.info(f"Correo {email_id} leido.")

        except Exception as e:
            logger.error(f"Error correo {email_id}: {e}")
            # Marcar como leido aunque haya error — evita bucles de reintento
            try: mail.store(email_id, '+FLAGS', '\\Seen')
            except: pass

    mail.logout()


# ===================================================================
# BLOQUE 7 — PUNTO DE ENTRADA PRINCIPAL
# ===================================================================

def main():
    """
    Punto de entrada del script cuando systemd lo arranca como servicio.

    Secuencia de arranque:
        1. Configura el sistema de logging (archivo con timestamp)
        2. Carga la configuracion desde config.env
        3. Espera a que Ollama este disponible
        4. Carga el modelo en RAM con una inferencia de prueba (warmup)
        5. Entra al bucle infinito de revision de correos

    El bucle lee store_info.md fresco en cada iteracion para que los
    cambios en el inventario tomen efecto sin reiniciar el servicio.
    Si una iteracion falla, el error se loguea y el bucle continua.
    El agente nunca se detiene por un error puntual.
    """
    # Configurar logging: escribe en archivo con timestamp en cada linea
    # Formato ejemplo: 2026-05-05 11:28:43,595 [INFO] Ollama responde.
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s'
    )
    logger = logging.getLogger(__name__)
    logger.info("=== Email agent iniciado ===")

    config         = load_config()
    check_interval = int(config.get('CHECK_INTERVAL', '60'))  # segundos entre revisiones
    ollama_url     = config.get('OLLAMA_URL', 'http://localhost:11434')
    model          = config.get('OLLAMA_MODEL', 'gemma3:4b')

    # Esperar a que Ollama este listo antes de hacer cualquier cosa
    if not wait_for_ollama(ollama_url, logger):
        logger.error("Abortando — Ollama no disponible.")
        return  # systemd reiniciara el servicio segun RestartSec=30

    # Calentar el modelo para que este en RAM al llegar el primer correo
    if not warmup_ollama(model, ollama_url, logger):
        logger.warning("Warmup fallo — el primer correo puede tardar mas.")

    logger.info(f"Agente listo. Revisando cada {check_interval}s.")

    # Bucle principal infinito
    while True:
        try:
            # Leer inventario fresco en cada ciclo
            store_info = load_store_info()
            process_unread_emails(config, store_info, logger)
        except Exception as e:
            logger.error(f"Error ciclo: {e}")
        # Pausar antes de la proxima revision
        time.sleep(check_interval)


# Garantiza que main() solo se ejecute cuando el script
# se corre directamente, no cuando se importa como modulo
if __name__ == '__main__':
    main()
