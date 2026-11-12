#!/bin/bash
# ==========================================================================
#  Gestion des sites Apache + comptes FTP virtuels vsftpd (labo TSPCR)
#
#  Chaque "client" reçoit :
#   - un compte FTP virtuel (pas un vrai compte Linux), enfermé dans son dossier
#   - un dossier /var/www/<client>/public_html
#   - un site Apache (VirtualHost) pour son nom de domaine
#
#  Fonctionnement des comptes virtuels :
#   - logins.txt : liste "utilisateur / mot de passe", une ligne sur deux
#   - logins.db  : la même liste au format base de données, lue par PAM
#                  (module pam_userdb, voir pam.d-vsftpd)
#   - tous les comptes virtuels travaillent en réalité sous le compte local "ftp"
#     (guest_username dans vsftpd.conf)
#
#  Prérequis : apt install apache2 vsftpd db-util
#
#  Corrections par rapport à la version d'origine (voir README) :
#   - "Lister" affichait aussi les MOTS DE PASSE en clair → n'affiche que les noms
#   - nom d'utilisateur vide ou bizarre ("../", espaces) refusé : un nom vide
#     pouvait mener à "rm -rf /var/www/"
#   - recherche d'utilisateur faite sur les lignes "nom" uniquement (un mot de
#     passe identique à un nom faussait la recherche et la suppression)
#   - logins.txt protégé (il était lisible par tous les comptes de la machine)
#   - VirtualHost sur *:80 au lieu de l'IP : le site ne casse plus si l'IP change
#   - listage des dossiers (Options Indexes) désactivé
#   - droits : 755 sur les dossiers, 644 sur les fichiers (plus de fichiers exécutables)
#   - configuration Apache vérifiée avant rechargement
# ==========================================================================

# === Configuration ===
VUSER_DB_TXT="/etc/vsftpd/logins.txt"
VUSER_DB="/etc/vsftpd/logins.db"        # pam_userdb l'appelle "/etc/vsftpd/logins" (sans .db)
USER_CONF_DIR="/etc/vsftpd/vsftpdUsers" # = user_config_dir dans vsftpd.conf
FTP_ROOT="/var/www"
APACHE_CONF_DIR="/etc/apache2/sites-available"
GUEST_SYSTEM_USER="ftp"                 # = guest_username dans vsftpd.conf

# === Vérifications ===
if [ "$EUID" -ne 0 ]; then
    echo "❌ Ce script doit être lancé en tant que root."
    exit 1
fi
if ! command -v db_load >/dev/null 2>&1; then
    echo "❌ db_load introuvable : installez-le avec 'apt install db-util'."
    exit 1
fi

# Fichier des comptes : créé si absent, lisible par root uniquement
mkdir -p "$(dirname "$VUSER_DB_TXT")"
touch "$VUSER_DB_TXT"
chmod 600 "$VUSER_DB_TXT"

# Le fichier alterne nom / mot de passe : les noms sont sur les lignes impaires
lister_noms() {
    awk 'NR % 2 == 1 && NF' "$VUSER_DB_TXT"
}

utilisateur_existe() {
    lister_noms | grep -qxF "$1"
}

# Nom d'utilisateur sûr : minuscules, chiffres, - et _, commence par une lettre
nom_valide() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]
}

# Régénère la base lue par PAM à partir du fichier texte
regenerer_base() {
    rm -f "$VUSER_DB"
    db_load -T -t hash -f "$VUSER_DB_TXT" "$VUSER_DB"
    chmod 600 "$VUSER_DB"
}

recharger_apache() {
    if apache2ctl configtest 2>/dev/null; then
        systemctl reload apache2
    else
        echo "⚠️ Erreur dans la configuration Apache (voir 'apache2ctl configtest') : Apache n'a pas été rechargé."
    fi
}

# === Créer utilisateur/site ===
creer_utilisateur() {
    read -p "Nom de l'utilisateur virtuel FTP : " VUSER
    if ! nom_valide "$VUSER"; then
        echo "❌ Nom invalide : 2 à 32 caractères, minuscules, chiffres, - ou _, en commençant par une lettre."
        return
    fi
    read -p "Nom de domaine (ex: monsite.local) : " DOMAIN
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        echo "❌ Nom de domaine invalide."
        return
    fi

    if utilisateur_existe "$VUSER" || [ -d "$FTP_ROOT/$VUSER" ] || \
       [ -f "$USER_CONF_DIR/$VUSER" ] || [ -f "$APACHE_CONF_DIR/$VUSER.conf" ]; then
        echo "❌ L'utilisateur ou le site existe déjà."
        return
    fi

    read -s -p "Mot de passe FTP : " VPASS
    echo
    read -s -p "Confirmez le mot de passe : " VPASS2
    echo

    if [ -z "$VPASS" ] || [ "$VPASS" != "$VPASS2" ]; then
        echo "❌ Mot de passe vide ou différent."
        return
    fi

    # Dossier du site, propriété du compte "ftp" (utilisé par les comptes virtuels)
    mkdir -p "$FTP_ROOT/$VUSER/public_html"
    echo "<h1>Bienvenue sur $DOMAIN</h1>" > "$FTP_ROOT/$VUSER/public_html/index.html"
    chown -R "$GUEST_SYSTEM_USER:$GUEST_SYSTEM_USER" "$FTP_ROOT/$VUSER"
    find "$FTP_ROOT/$VUSER" -type d -exec chmod 755 {} +
    find "$FTP_ROOT/$VUSER" -type f -exec chmod 644 {} +

    # Ajout du compte (nom puis mot de passe) et régénération de la base
    printf '%s\n%s\n' "$VUSER" "$VPASS" >> "$VUSER_DB_TXT"
    regenerer_base

    # Réglages FTP propres à ce compte : enfermé dans son dossier, droit d'écriture
    mkdir -p "$USER_CONF_DIR"
    cat <<EOF > "$USER_CONF_DIR/$VUSER"
local_root=$FTP_ROOT/$VUSER
write_enable=YES
anon_world_readable_only=NO
anon_upload_enable=YES
anon_mkdir_write_enable=YES
anon_other_write_enable=YES
EOF

    # Site Apache. *:80 = toutes les adresses de la machine (fonctionne même si l'IP change).
    # Pas de "Indexes" : un dossier sans index.html n'affiche pas la liste de ses fichiers.
    cat <<EOF > "$APACHE_CONF_DIR/$VUSER.conf"
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot $FTP_ROOT/$VUSER/public_html

    <Directory $FTP_ROOT/$VUSER/public_html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$VUSER-error.log
    CustomLog \${APACHE_LOG_DIR}/$VUSER-access.log combined
</VirtualHost>
EOF

    a2ensite -q "$VUSER.conf"
    recharger_apache

    echo "✅ Utilisateur '$VUSER' et site '$DOMAIN' créés avec succès."
}

# === Supprimer utilisateur/site ===
supprimer_utilisateur() {
    read -p "Nom de l'utilisateur à supprimer : " VUSER

    # Contrôle indispensable avant tout "rm -rf" : un nom vide visait /var/www/ entier
    if ! nom_valide "$VUSER" || ! utilisateur_existe "$VUSER"; then
        echo "❌ L'utilisateur '$VUSER' n'existe pas."
        return
    fi

    echo "⚠️ Cette opération supprimera l'utilisateur, son site et ses fichiers."
    read -p "Confirmer la suppression de '$VUSER' ? (o/n) : " CONF
    if [[ "$CONF" != "o" && "$CONF" != "O" ]]; then
        echo "❌ Annulé."
        return
    fi

    # Retire le couple nom + mot de passe (en ne regardant que les lignes "nom")
    TMP=$(mktemp)
    awk -v user="$VUSER" '
        NR % 2 == 1 { nom = $0; next }
        nom != user { print nom; print $0 }
    ' "$VUSER_DB_TXT" > "$TMP"
    cat "$TMP" > "$VUSER_DB_TXT"   # "cat >" garde les droits 600 du fichier d'origine
    rm -f "$TMP"
    regenerer_base

    rm -rf "${FTP_ROOT:?}/${VUSER:?}"
    rm -f "$USER_CONF_DIR/$VUSER"
    a2dissite -q "$VUSER.conf" 2>/dev/null
    rm -f "$APACHE_CONF_DIR/$VUSER.conf"
    recharger_apache

    echo "✅ Utilisateur '$VUSER' supprimé avec succès."
}

# === Lister les utilisateurs (noms uniquement, jamais les mots de passe) ===
lister_utilisateurs() {
    echo "📂 Utilisateurs FTP virtuels :"
    lister_noms | sed 's/^/   - /'
}

# === Menu principal ===
while true; do
    echo ""
    echo "╔══════════════════════════════╗"
    echo "║   GESTION FTP / APACHE2      ║"
    echo "╠══════════════════════════════╣"
    echo "║ 1. Créer un utilisateur/site ║"
    echo "║ 2. Supprimer un utilisateur  ║"
    echo "║ 3. Lister les utilisateurs   ║"
    echo "║ 4. Quitter                   ║"
    echo "╚══════════════════════════════╝"
    read -p "Choix [1-4] : " CHOICE
    echo ""

    case "$CHOICE" in
        1) creer_utilisateur ;;
        2) supprimer_utilisateur ;;
        3) lister_utilisateurs ;;
        4) echo "👋 Au revoir !" ; exit 0 ;;
        *) echo "❌ Choix invalide." ;;
    esac
done
