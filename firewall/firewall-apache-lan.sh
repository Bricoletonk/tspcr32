#!/bin/bash
# ==========================================================================
#  Pare-feu passerelle : serveur web/FTP publié + réseau LAN qui sort sur Internet
#  (labo TSPCR — iptables)
#
#  Schéma :
#
#     Internet ── [CARTE_EXT]  PARE-FEU  [CARTE_LAN] ── LAN 172.16.2.0/24
#                                 │
#                                 └── serveur Apache/FTP 10.10.10.10
#
#  - Le serveur Apache (web + FTP) est publié vers Internet par redirection
#    de ports (DNAT) : 80, 443, 21 et la plage FTP passive 40000-50000.
#  - Le SSH du serveur Apache est joignable sur le port 2222 du pare-feu
#    (redirigé vers son port 22), depuis ADMIN_SOURCE uniquement.
#  - Le LAN peut sortir sur Internet (web, DNS, ping) et joindre le serveur.
#  - Le pare-feu lui-même est administrable en SSH sur le port 22222.
#
#  Fusion de "iptables-apache-simple.sh" et "iptables-apache-lan.sh",
#  qui étaient deux versions presque identiques.
#
#  Corrections par rapport à la version d'origine (voir README) :
#   - activation du routage (ip_forward), sans quoi rien n'était transmis
#   - le SSH "privé" (2222) était ouvert à tout Internet → limité à ADMIN_SOURCE
#   - règles "--sport 21 / 40000:50000" supprimées : elles laissaient le serveur
#     ouvrir des connexions vers n'importe où depuis ces ports
#   - règle "--dport 2222" en FORWARD supprimée : inutile après la redirection
#   - IPv6 fermé (il restait entièrement ouvert)
#   - -m state (obsolète) → -m conntrack
#   - règles sauvegardées pour survivre au redémarrage
#   - journal des paquets refusés
# ==========================================================================

# --- Vérification : il faut être root -------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être lancé en root." >&2
    exit 1
fi

# --- Variables (à adapter) ------------------------------------------------
CARTE_EXT="ens18"             # côté Internet
CARTE_LAN="ens20"             # côté réseau local
RESEAU_LAN="172.16.2.0/24"
IP_APACHE="10.10.10.10"       # serveur web/FTP publié
PORT_SSH_FW="22222"           # SSH du pare-feu (sshd doit écouter sur ce port)
PORT_SSH_APACHE="2222"        # port public redirigé vers le SSH (22) du serveur Apache
FTP_PASSIF="40000:50000"      # doit correspondre à pasv_min_port / pasv_max_port de vsftpd
ADMIN_SOURCE="0.0.0.0/0"      # qui peut joindre les SSH : à restreindre (ex. 203.0.113.10/32)

IPT="iptables"

# --- 1. Routage : indispensable pour qu'une machine transmette des paquets
#        d'une carte à l'autre (FORWARD). Activé tout de suite et au démarrage.
sysctl -q -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-routeur.conf

# --- 2. Remise à zéro -----------------------------------------------------
#  On repasse d'abord en ACCEPT : si les politiques étaient déjà en DROP,
#  vider les règles couperait immédiatement la session SSH en cours.
$IPT -P INPUT ACCEPT
$IPT -P OUTPUT ACCEPT
$IPT -P FORWARD ACCEPT
$IPT -F
$IPT -X
$IPT -t nat -F
$IPT -t nat -X

# --- 3. Règles de base (avant de tout bloquer) ----------------------------
$IPT -A INPUT  -i lo -j ACCEPT
$IPT -A OUTPUT -o lo -j ACCEPT

# Réponses aux connexions déjà acceptées : une seule règle par chaîne.
# Elle remplace toutes les règles "retour" (--sport ...) de l'ancienne version.
$IPT -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A OUTPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

$IPT -A INPUT   -m conntrack --ctstate INVALID -j DROP
$IPT -A FORWARD -m conntrack --ctstate INVALID -j DROP

# --- 4. Politiques par défaut : tout ce qui n'est pas autorisé est refusé ---
$IPT -P INPUT   DROP
$IPT -P OUTPUT  DROP
$IPT -P FORWARD DROP

# ==========================================================================
#  INPUT / OUTPUT : trafic destiné au pare-feu ou émis par lui
# ==========================================================================

# SSH vers le pare-feu
$IPT -A INPUT -i "$CARTE_EXT" -s "$ADMIN_SOURCE" -p tcp --dport "$PORT_SSH_FW" -m conntrack --ctstate NEW -j ACCEPT
$IPT -A INPUT -i "$CARTE_LAN" -s "$RESEAU_LAN"   -p tcp --dport "$PORT_SSH_FW" -m conntrack --ctstate NEW -j ACCEPT

# Ping vers le pare-feu, limité
$IPT -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT

# Le pare-feu peut faire ses mises à jour : DNS, web, heure
$IPT -A OUTPUT -p udp --dport 53 -j ACCEPT
$IPT -A OUTPUT -p tcp --dport 53 -j ACCEPT
$IPT -A OUTPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
$IPT -A OUTPUT -p udp --dport 123 -j ACCEPT
$IPT -A OUTPUT -p icmp -j ACCEPT

# ==========================================================================
#  FORWARD : vers le serveur Apache (après redirection DNAT, voir NAT)
#  Seules les NOUVELLES connexions sont listées ; les retours passent par
#  la règle ESTABLISHED,RELATED.
# ==========================================================================

# Web et FTP publics
$IPT -A FORWARD -d "$IP_APACHE" -p tcp -m multiport --dports 80,443,21 -m conntrack --ctstate NEW -j ACCEPT
$IPT -A FORWARD -d "$IP_APACHE" -p tcp --dport "$FTP_PASSIF"           -m conntrack --ctstate NEW -j ACCEPT

# SSH du serveur : depuis l'extérieur (ADMIN_SOURCE, arrivé par le port 2222)
# et depuis le LAN (directement sur le port 22)
$IPT -A FORWARD -i "$CARTE_EXT" -s "$ADMIN_SOURCE" -d "$IP_APACHE" -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
$IPT -A FORWARD -i "$CARTE_LAN" -s "$RESEAU_LAN"   -d "$IP_APACHE" -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# Ping vers le serveur
$IPT -A FORWARD -d "$IP_APACHE" -p icmp --icmp-type echo-request -j ACCEPT

# Le serveur peut faire ses mises à jour (DNS, web, heure)
$IPT -A FORWARD -s "$IP_APACHE" -o "$CARTE_EXT" -p udp --dport 53 -j ACCEPT
$IPT -A FORWARD -s "$IP_APACHE" -o "$CARTE_EXT" -p tcp -m multiport --dports 53,80,443 -j ACCEPT
$IPT -A FORWARD -s "$IP_APACHE" -o "$CARTE_EXT" -p udp --dport 123 -j ACCEPT
$IPT -A FORWARD -s "$IP_APACHE" -o "$CARTE_EXT" -p icmp -j ACCEPT

# ==========================================================================
#  FORWARD : le LAN vers Internet
# ==========================================================================
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$RESEAU_LAN" -p tcp -m multiport --dports 80,443 -j ACCEPT
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$RESEAU_LAN" -p udp --dport 53 -j ACCEPT
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$RESEAU_LAN" -p tcp --dport 53 -j ACCEPT
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$RESEAU_LAN" -p icmp -j ACCEPT

# ==========================================================================
#  NAT
# ==========================================================================

# Publication du serveur : ce qui arrive sur ces ports du pare-feu est
# redirigé vers le serveur Apache (DNAT)
$IPT -t nat -A PREROUTING -i "$CARTE_EXT" -p tcp -m multiport --dports 80,443,21 -j DNAT --to-destination "$IP_APACHE"
$IPT -t nat -A PREROUTING -i "$CARTE_EXT" -p tcp --dport "$FTP_PASSIF"           -j DNAT --to-destination "$IP_APACHE"

# SSH du serveur : port public 2222 → port 22 du serveur.
# "-i CARTE_EXT" ajouté : l'ancienne règle s'appliquait sur toutes les cartes.
$IPT -t nat -A PREROUTING -i "$CARTE_EXT" -p tcp --dport "$PORT_SSH_APACHE" -j DNAT --to-destination "$IP_APACHE:22"

# Sorties vers Internet (serveur et LAN) : adresse remplacée par celle du
# pare-feu. Le filtrage par port est fait dans FORWARD.
$IPT -t nat -A POSTROUTING -o "$CARTE_EXT" -s "$IP_APACHE"  -j MASQUERADE
$IPT -t nat -A POSTROUTING -o "$CARTE_EXT" -s "$RESEAU_LAN" -j MASQUERADE

# Module de suivi FTP : aide le pare-feu à reconnaître les connexions de
# données FTP comme "RELATED" (complément à la plage passive ouverte ci-dessus)
modprobe nf_conntrack_ftp 2>/dev/null

# ==========================================================================
#  Journal : derniers paquets refusés (visible avec "journalctl -k | grep FW-")
# ==========================================================================
$IPT -A INPUT   -m limit --limit 5/min -j LOG --log-prefix "FW-INPUT-DROP: "
$IPT -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "FW-FORWARD-DROP: "

# ==========================================================================
#  IPv6 : non utilisé dans ce labo → tout fermé (sauf boucle locale).
# ==========================================================================
ip6tables -P INPUT ACCEPT; ip6tables -P OUTPUT ACCEPT; ip6tables -P FORWARD ACCEPT
ip6tables -F; ip6tables -X
ip6tables -A INPUT  -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -P INPUT DROP; ip6tables -P OUTPUT DROP; ip6tables -P FORWARD DROP

# ==========================================================================
#  Sauvegarde (paquet "iptables-persistent")
# ==========================================================================
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null && echo -e "\e[1;32mRègles sauvegardées (restaurées au démarrage).\e[0m"
else
    echo -e "\e[1;33mAttention : règles NON persistantes. Installez iptables-persistent pour les garder au redémarrage.\e[0m"
fi

# ==========================================================================
#  Affichage des règles
# ==========================================================================
echo -e "\n\e[1;35m╔════════════════════════════╗"
echo -e "║        TABLE NAT           ║"
echo -e "╚════════════════════════════╝\e[0m"
$IPT -t nat -vnL --line-numbers

echo -e "\n\e[1;34m╔════════════════════════════╗"
echo -e "║       TABLE FILTER         ║"
echo -e "╚════════════════════════════╝\e[0m"
$IPT -t filter -vnL --line-numbers
