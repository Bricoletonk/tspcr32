#!/bin/bash
# ==========================================================================
#  Pare-feu passerelle : le réseau LAN sort sur Internet UNIQUEMENT via le proxy
#  (labo TSPCR — iptables)
#
#  Schéma :
#
#     Internet ── [CARTE_EXT]  PARE-FEU  [CARTE_LAN] ── LAN 10.10.14.0/24
#                                                         └─ Proxy 10.10.14.5
#
#  - Seul le proxy a le droit de sortir sur Internet (web, DNS, ping).
#    Les postes du LAN passent par le proxy (le trafic poste → proxy reste
#    dans le LAN et ne traverse pas le pare-feu).
#  - L'interface d'administration du proxy (port 12000) est publiée vers
#    l'extérieur, depuis ADMIN_SOURCE uniquement.
#  - Le pare-feu lui-même est administrable en SSH sur le port 22222.
#
#  Corrections par rapport à la version d'origine (voir README) :
#   - activation du routage (ip_forward), sans quoi rien n'était transmis
#   - "80:443" ouvrait TOUS les ports de 80 à 443 → remplacé par "80,443"
#   - sorties du pare-feu : NEW,RELATED → ESTABLISHED,RELATED
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
CARTE_EXT="enp0s3"            # côté Internet
CARTE_LAN="enp0s8"            # côté réseau local
RESEAU_LAN="10.10.14.0/24"
IP_PROXY="10.10.14.5"
PORT_SSH_FW="22222"           # SSH du pare-feu (sshd doit écouter sur ce port)
PORT_WEBADMIN="12000"         # interface d'admin du proxy publiée vers l'extérieur
ADMIN_SOURCE="0.0.0.0/0"      # qui peut joindre SSH et l'admin : à restreindre (ex. 203.0.113.10/32)

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
$IPT -F            # vide les règles de la table filter
$IPT -X            # supprime les chaînes personnalisées
$IPT -t nat -F
$IPT -t nat -X

# --- 3. Règles de base (avant de tout bloquer) ----------------------------
# Boucle locale : le pare-feu se parle à lui-même
$IPT -A INPUT  -i lo -j ACCEPT
$IPT -A OUTPUT -o lo -j ACCEPT

# Réponses aux connexions déjà acceptées, dans les 3 chaînes.
# "conntrack" suit l'état des connexions : une seule règle suffit pour
# laisser passer tous les retours, au lieu d'une règle "retour" par service.
$IPT -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A OUTPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Paquets incohérents (ne correspondant à aucune connexion connue) : rejetés
$IPT -A INPUT   -m conntrack --ctstate INVALID -j DROP
$IPT -A FORWARD -m conntrack --ctstate INVALID -j DROP

# --- 4. Politiques par défaut : tout ce qui n'est pas autorisé est refusé ---
$IPT -P INPUT   DROP
$IPT -P OUTPUT  DROP
$IPT -P FORWARD DROP

# ==========================================================================
#  INPUT / OUTPUT : trafic destiné au pare-feu ou émis par lui
# ==========================================================================

# SSH vers le pare-feu (port personnalisé). Plus besoin de règle OUTPUT
# "retour" : elle est couverte par ESTABLISHED,RELATED ci-dessus.
$IPT -A INPUT -i "$CARTE_EXT" -s "$ADMIN_SOURCE" -p tcp --dport "$PORT_SSH_FW" -m conntrack --ctstate NEW -j ACCEPT
$IPT -A INPUT -i "$CARTE_LAN" -s "$RESEAU_LAN"   -p tcp --dport "$PORT_SSH_FW" -m conntrack --ctstate NEW -j ACCEPT

# Ping vers le pare-feu (utile pour le dépannage), limité contre l'inondation
$IPT -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT

# Le pare-feu peut faire ses mises à jour : DNS + web (multiport : 80 ET 443,
# alors que "--dport 80:443" ouvrait toute la plage 80 → 443)
$IPT -A OUTPUT -p udp --dport 53 -j ACCEPT
$IPT -A OUTPUT -p tcp --dport 53 -j ACCEPT
$IPT -A OUTPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
$IPT -A OUTPUT -p udp --dport 123 -j ACCEPT          # NTP (heure)
$IPT -A OUTPUT -p icmp -j ACCEPT

# ==========================================================================
#  FORWARD : trafic qui TRAVERSE le pare-feu
# ==========================================================================

# Le proxy peut sortir sur Internet : web, DNS, ping
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$IP_PROXY" -p tcp -m multiport --dports 80,443 -j ACCEPT
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$IP_PROXY" -p udp --dport 53 -j ACCEPT
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$IP_PROXY" -p tcp --dport 53 -j ACCEPT
$IPT -A FORWARD -i "$CARTE_LAN" -o "$CARTE_EXT" -s "$IP_PROXY" -p icmp -j ACCEPT

# Interface d'admin du proxy accessible depuis l'extérieur (après DNAT, voir NAT)
$IPT -A FORWARD -i "$CARTE_EXT" -o "$CARTE_LAN" -s "$ADMIN_SOURCE" -d "$IP_PROXY" -p tcp --dport "$PORT_WEBADMIN" -m conntrack --ctstate NEW -j ACCEPT

# ==========================================================================
#  NAT
# ==========================================================================

# Sortie du proxy sur Internet : on remplace son adresse privée par celle
# du pare-feu (MASQUERADE). Une seule règle suffit : le filtrage par port
# est déjà fait dans FORWARD.
$IPT -t nat -A POSTROUTING -o "$CARTE_EXT" -s "$IP_PROXY" -j MASQUERADE

# Publication de l'admin du proxy : ce qui arrive sur le port 12000 du
# pare-feu est redirigé vers le proxy (DNAT). Les réponses repassent
# automatiquement grâce au suivi de connexion : pas besoin d'autre règle.
$IPT -t nat -A PREROUTING -i "$CARTE_EXT" -p tcp --dport "$PORT_WEBADMIN" -j DNAT --to-destination "$IP_PROXY:$PORT_WEBADMIN"

# ==========================================================================
#  Journal : derniers paquets refusés (visible avec "journalctl -k | grep FW-")
#  Limité pour ne pas remplir les journaux.
# ==========================================================================
$IPT -A INPUT   -m limit --limit 5/min -j LOG --log-prefix "FW-INPUT-DROP: "
$IPT -A FORWARD -m limit --limit 5/min -j LOG --log-prefix "FW-FORWARD-DROP: "

# ==========================================================================
#  IPv6 : non utilisé dans ce labo → tout fermé (sauf boucle locale).
#  Sans ça, IPv6 restait entièrement ouvert, quelles que soient les règles IPv4.
# ==========================================================================
ip6tables -P INPUT ACCEPT; ip6tables -P OUTPUT ACCEPT; ip6tables -P FORWARD ACCEPT
ip6tables -F; ip6tables -X
ip6tables -A INPUT  -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -P INPUT DROP; ip6tables -P OUTPUT DROP; ip6tables -P FORWARD DROP

# ==========================================================================
#  Sauvegarde : sans elle, les règles disparaissent au redémarrage.
#  (paquet "iptables-persistent" : apt install iptables-persistent)
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
