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

Instalação rápida (setup)

No Kali, como root, rode o setup da XPSec Academy — ele baixa e prepara o lab:

```bash
curl -fsSL https://raw.githubusercontent.com/XPSec-Security/wifilab/main/wifilab-setup-academy.sh | sudo bash
```

---

## Uso

```bash
sudo ./xpsec-wifi-lab-pro.sh --up            # instala deps + sobe o lab completo
sudo ./xpsec-wifi-lab-pro.sh --install       # só instala as dependências
sudo ./xpsec-wifi-lab-pro.sh --status        # mostra o que está no ar
sudo ./xpsec-wifi-lab-pro.sh --down          # destrói tudo
```

---

## Redes do lab

| # | SSID | Banda / Canal | Cenário | Credencial / segredo |
|---|------|---------------|---------|----------------------|
| 1 | `XPSEC-WPA2` | 2.4 / 11 | WPA2-PSK fraca | senha `verao2024` |
| 2 | `XPSEC-OPEN` | 2.4 / 3 | Aberta + login HTTP em claro | `funcionario` / `Intranet@2026` |
| 3 | `XPSEC-MACACL` | 2.4 / 9 | Aberta + filtro de MAC | MAC autorizado `02:ca:fe:00:11:22` |
| 4 | `XPSEC-PMKID` | 5 / 36 | WPA2-PSK clientless (PMKID) | senha `familia10` |
| 5 | `XPSEC-CORP` | 5 / 149 | WPA2-Enterprise (hostapd-wpe) | `funcionario@xpsec.local` / `Senha@Corp123` |

Interface livre para o aluno colocar em monitor: **`mon_lab`**.
Interface managed livre para o registrar WPS: **`atk_wps`**.

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
