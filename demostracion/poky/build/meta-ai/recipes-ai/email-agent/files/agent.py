#!/usr/bin/env python3
import imaplib, smtplib, email, time, logging, requests
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import decode_header

CONFIG_FILE     = "/etc/email-agent/config.env"
STORE_INFO_FILE = "/etc/email-agent/store_info.md"
LOG_FILE        = "/var/log/email-agent.log"

def load_config():
    config = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, val = line.split('=', 1)
                config[key.strip()] = val.strip()
    return config

def load_store_info():
    with open(STORE_INFO_FILE) as f:
        return f.read()

def decode_str(s):
    parts = []
    for part, enc in decode_header(s):
        if isinstance(part, bytes):
            parts.append(part.decode(enc or 'utf-8', errors='replace'))
        else:
            parts.append(part)
    return ''.join(parts)

def get_email_body(msg):
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == 'text/plain':
                payload = part.get_payload(decode=True)
                if payload:
                    return payload.decode(part.get_content_charset() or 'utf-8', errors='replace')
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            return payload.decode(msg.get_content_charset() or 'utf-8', errors='replace')
    return ""

def extract_sender_address(from_header):
    if '<' in from_header and '>' in from_header:
        return from_header.split('<')[1].split('>')[0].strip()
    return from_header.strip()

def build_prompt(store_info, personality, subject, body):
    body_truncated = body.strip()[:600]
    return f"""Eres un vendedor de TecnoPartes S.A. Responde el email del cliente usando exclusivamente la informacion  textual de la lista de abajo.

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
8. Asegúrate de que toda la información que brindes exista dentro de la "LISTA DE LA TIENDA". Si no encuentras algo dentro de esta, indica que no lo manejamos.

EMAIL DEL CLIENTE:
Asunto: {subject}
Mensaje: {body_truncated}

{personality}
Respuesta:"""

def query_ollama(prompt, model, ollama_url, logger):
    url = f"{ollama_url}/api/generate"
    payload = {"model": model, "prompt": prompt, "stream": False,
               "options": {"num_predict": 1200, "temperature": 0.1}}
    logger.info(f"Enviando prompt a Ollama ({len(prompt)} chars)...")
    start = time.time()
    response = requests.post(url, json=payload, timeout=600)
    response.raise_for_status()
    result = response.json()["response"].strip()
    logger.info(f"Respuesta en {time.time()-start:.1f}s")
    return result

def warmup_ollama(model, ollama_url, logger):
    logger.info("Calentando el modelo...")
    payload = {"model": model, "prompt": "Di solo: OK",
               "stream": False, "options": {"num_predict": 5}}
    try:
        response = requests.post(f"{ollama_url}/api/generate", json=payload, timeout=180)
        response.raise_for_status()
        logger.info("Warmup completado.")
        return True
    except Exception as e:
        logger.error(f"Warmup fallo: {e}")
        return False

def wait_for_ollama(ollama_url, logger, retries=15, delay=20):
    for i in range(retries):
        try:
            r = requests.get(f"{ollama_url}/api/tags", timeout=5)
            if r.status_code == 200:
                logger.info("Ollama responde.")
                return True
        except Exception:
            pass
        logger.info(f"Esperando Ollama... {i+1}/{retries}")
        time.sleep(delay)
    logger.error("Ollama no respondio.")
    return False

def send_reply(config, to_address, subject, body, logger):
    reply_subject = subject if subject.startswith("Re:") else f"Re: {subject}"
    msg = MIMEMultipart()
    msg['From'] = config['GMAIL_USER']
    msg['To'] = to_address
    msg['Subject'] = reply_subject
    msg.attach(MIMEText(body, 'plain', 'utf-8'))
    logger.info(f"Enviando a {to_address}...")
    with smtplib.SMTP_SSL('smtp.gmail.com', 465, timeout=30) as server:
        server.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        server.send_message(msg)
    logger.info("Enviado.")

def process_unread_emails(config, store_info, logger):
    ollama_url  = config.get('OLLAMA_URL', 'http://localhost:11434')
    model       = config.get('OLLAMA_MODEL', 'qwen2.5:3b')
    personality = config.get('PERSONALITY', 'Firma como "Equipo de Ventas - TecnoPartes S.A."')
    logger.info("Conectando a Gmail IMAP...")
    try:
        mail = imaplib.IMAP4_SSL('imap.gmail.com', timeout=30)
    except Exception as e:
        logger.error(f"Fallo conexion: {e}"); return
    try:
        mail.login(config['GMAIL_USER'], config['GMAIL_APP_PASSWORD'])
        logger.info("Autenticacion IMAP ok.")
    except imaplib.IMAP4.error as e:
        logger.error(f"Error auth IMAP: {e}"); mail.logout(); return
    mail.select('inbox')
    status, messages = mail.search(None, 'UNSEEN')
    if status != 'OK' or not messages[0]:
        logger.info("Sin correos nuevos."); mail.logout(); return
    email_ids = messages[0].split()
    logger.info(f"Correos no leidos: {len(email_ids)}")
    for email_id in email_ids:
        try:
            status, data = mail.fetch(email_id, '(RFC822)')
            if status != 'OK': continue
            msg       = email.message_from_bytes(data[0][1])
            sender    = msg.get('From', '')
            subject   = decode_str(msg.get('Subject', '(Sin asunto)'))
            body      = get_email_body(msg)
            sender_address = extract_sender_address(sender)
            logger.info(f"--- De: {sender_address} | {subject}")
            prompt     = build_prompt(store_info, personality, subject, body)
            reply_text = query_ollama(prompt, model, ollama_url, logger)
            send_reply(config, sender_address, subject, reply_text, logger)
            mail.store(email_id, '+FLAGS', '\\Seen')
            logger.info(f"Correo {email_id} leido.")
        except Exception as e:
            logger.error(f"Error correo {email_id}: {e}")
            try: mail.store(email_id, '+FLAGS', '\\Seen')
            except: pass
    mail.logout()

def main():
    logging.basicConfig(filename=LOG_FILE, level=logging.INFO,
                        format='%(asctime)s [%(levelname)s] %(message)s')
    logger = logging.getLogger(__name__)
    logger.info("=== Email agent iniciado ===")
    config = load_config()
    check_interval = int(config.get('CHECK_INTERVAL', '60'))
    ollama_url = config.get('OLLAMA_URL', 'http://localhost:11434')
    model = config.get('OLLAMA_MODEL', 'qwen2.5:3b')
    if not wait_for_ollama(ollama_url, logger):
        logger.error("Abortando."); return
    if not warmup_ollama(model, ollama_url, logger):
        logger.warning("Warmup fallo.")
    logger.info(f"Agente listo. Revisando cada {check_interval}s.")
    while True:
        try:
            store_info = load_store_info()
            process_unread_emails(config, store_info, logger)
        except Exception as e:
            logger.error(f"Error ciclo: {e}")
        time.sleep(check_interval)

if __name__ == '__main__':
    main()
