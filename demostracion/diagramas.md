## Diagrama 1 — Infraestructura de red

```mermaid
flowchart TD
    CLIENTE["📧 Cliente externo
    cualquier dispositivo"]

    GMAIL["☁️ Gmail
    Servidor Google
    IMAP · SMTP"]

    IPHONE["📱 iPhone de Gabriel
    Hotspot WiFi + datos móviles
    Router de internet"]

    PI["🔴 Raspberry Pi 5
    Ollama + LLM gemma3:4b
    email-agent.service"]

    LAPTOP["💻 Laptop presentador
    SSH 172.20.10.x"]

    CLIENTE -- "1 · Envía correo (SMTP)" --> GMAIL
    GMAIL -- "4 · Entrega respuesta" --> CLIENTE

    PI -- "WiFi WPA2 · 172.20.10.x" --> IPHONE
    IPHONE -- "2 · Lee correos (IMAP)
    3 · Envía respuesta (SMTP)" --> GMAIL

    LAPTOP -- "WiFi · misma red hotspot" --> IPHONE
    IPHONE -- "SSH 172.20.10.x" --> PI

    style CLIENTE fill:#E6F1FB,stroke:#185FA5,color:#0C447C
    style GMAIL   fill:#EAF3DE,stroke:#3B6D11,color:#27500A
    style IPHONE  fill:#E1F5EE,stroke:#0F6E56,color:#085041
    style PI      fill:#EEEDFE,stroke:#534AB7,color:#3C3489
    style LAPTOP  fill:#F1EFE8,stroke:#5F5E5A,color:#444441
```

---

## Diagrama 2 — Agente Python


```mermaid
flowchart TD
    A(["Servicio arranca"]):::start

    B["Esperar a Ollama
    Consulta cada 20 segundos
    Máximo 5 minutos"]:::init

    BFAIL(["Ollama no respondió
    systemd reiniciará el agente"]):::error

    C["Calentar el modelo
    Inferencia de prueba
    para cargar el modelo en RAM"]:::init

    subgraph LOOP["Bucle principal — se repite cada 60 segundos"]
        D1["Leer inventario
        Lee store_info.md
        siempre fresco del disco"]:::file

        D2["Conectar a Gmail
        IMAP SSL puerto 993
        Con App Password"]:::net

        D2FAIL["Error de conexión
        Se registra en el log
        Se intenta en el próximo ciclo"]:::error

        D3{"Hay correos
        no leídos?"}:::decision

        D4["Sin correos
        Cerrar conexión
        Dormir 60 segundos"]:::sleep

        subgraph FOREACH["Por cada correo no leído"]
            E1["Descargar correo
            Obtiene el mensaje completo
            con todos sus encabezados"]:::net
            E2["Extraer datos
            Remitente, asunto y cuerpo
            del correo recibido"]:::proc
            E3["Construir prompt
            Combina el inventario
            con el correo del cliente"]:::llm
            E4["Consultar al LLM
            Ollama genera la respuesta
            Puede tardar hasta 10 minutos"]:::llm
            E5["Enviar respuesta
            Gmail SMTP puerto 465
            Responde al remitente"]:::net
            E6["Marcar como leído
            Para no responderlo
            de nuevo"]:::proc
            E1 --> E2 --> E3 --> E4 --> E5 --> E6
        end

        D1 --> D2
        D2 --> D2FAIL
        D2 --> D3
        D3 -- "No hay" --> D4
        D3 -- "Sí hay" --> FOREACH
        FOREACH --> D4
    end

    CONFIG["config.env
    Credenciales de Gmail
    Modelo y personalidad"]:::file

    STORE["store_info.md
    Inventario y precios
    Sucursal y horarios"]:::file

    A --> B
    B -- "No responde" --> BFAIL
    B -- "Listo" --> C
    C --> LOOP

    CONFIG -.-> D2
    CONFIG -.-> E4
    CONFIG -.-> E5
    STORE  -.-> D1
    D1     -.-> E4

    classDef start    fill:#534AB7,stroke:#3C3489,color:#EEEDFE
    classDef init     fill:#0F6E56,stroke:#085041,color:#E1F5EE
    classDef net      fill:#185FA5,stroke:#0C447C,color:#E6F1FB
    classDef llm      fill:#3C3489,stroke:#26215C,color:#CECBF6
    classDef file     fill:#BA7517,stroke:#854F0B,color:#FAEEDA
    classDef decision fill:#993C1D,stroke:#712B13,color:#FAECE7
    classDef sleep    fill:#5F5E5A,stroke:#444441,color:#F1EFE8
    classDef proc     fill:#1A6B8A,stroke:#0E4D66,color:#E0F4FF
    classDef error    fill:#7A1C1C,stroke:#5A1212,color:#FFE0E0
```