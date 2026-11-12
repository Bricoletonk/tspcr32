# tspcr32

Scripts de mes labos de formation **TSPCR** (Technicien Systèmes PC & Réseaux), revus et commentés.

> Ce sont des scripts pédagogiques prévus pour des machines de labo (adresses de test, VM Proxmox). Avant de les réutiliser, adaptez les variables en haut de chaque fichier, en particulier `ADMIN_SOURCE`.

## Pare-feu iptables (`firewall/`)

| Script | Rôle |
|---|---|
| `firewall-proxy-lan.sh` | Passerelle où seul un **proxy** du LAN peut sortir sur Internet. L'admin du proxy (port 12000) est publiée vers l'extérieur. |
| `firewall-apache-lan.sh` | Passerelle qui **publie un serveur web/FTP** (80, 443, 21, FTP passif, SSH sur le port 2222) et laisse le LAN sortir sur Internet. Fusion de deux anciennes versions presque identiques. |

Lancement (en root) : `bash firewall/firewall-apache-lan.sh`

Pour que les règles survivent au redémarrage : `apt install iptables-persistent` (le script les sauvegarde alors automatiquement).

Paquets refusés : `journalctl -k | grep FW-`

### Ce qui a été corrigé (novembre 2026)

**Problèmes sérieux**
- **Le routage n'était pas activé** (`net.ipv4.ip_forward`). Sans lui, aucune règle FORWARD ni NAT ne servait : la machine ne transmettait rien d'une carte à l'autre.
- **IPv6 restait entièrement ouvert**, les scripts ne gérant qu'IPv4. Il est maintenant fermé.
- **Les règles disparaissaient au redémarrage.** Elles sont sauvegardées si `iptables-persistent` est installé.

**Bugs**
- `--dport 80:443` ouvrait **toute la plage de ports 80 à 443** (plus de 360 ports, dont 445 le partage Windows). Remplacé par `-m multiport --dports 80,443`.
- Sorties du pare-feu proxy : `NEW,RELATED` laissait ouvrir n'importe quelle connexion mais bloquait la suite de l'échange. Remplacé par `ESTABLISHED,RELATED`.
- Le SSH « privé » du serveur Apache (port 2222) était **accessible depuis tout Internet** et sur toutes les cartes. Il est maintenant limité à la carte extérieure et à `ADMIN_SOURCE`.
- Les règles `--sport 21` et `--sport 40000:50000` laissaient le serveur ouvrir des connexions vers n'importe où depuis ces ports. Elles sont supprimées, les retours étant couverts par le suivi de connexion.
- Des règles inutiles ont été retirées : `--dport 2222` en FORWARD (le port est déjà 22 après la redirection), et les MASQUERADE et FORWARD « retour » du port 12000.

**Modernisation**
- `-m state` (obsolète) remplacé par `-m conntrack --ctstate`.
- Une seule règle `ESTABLISHED,RELATED` par chaîne au lieu d'une règle « retour » par service.
- Les politiques repassent en ACCEPT avant de vider les règles, pour ne pas couper la session SSH en cours quand on relance le script.
- Paquets invalides rejetés, ping limité, NTP autorisé pour l'heure, journal des paquets refusés.
- Le pare-feu est aussi administrable en SSH depuis le LAN (en plus de l'extérieur).
- Module `nf_conntrack_ftp` chargé pour mieux suivre les connexions FTP.

## Serveur web + FTP (`serveur-web-ftp/`)

Hébergement mutualisé : chaque client reçoit un site Apache et un compte FTP virtuel (pas de vrai compte Linux), enfermé dans son dossier. Le pare-feu `firewall/firewall-apache-lan.sh` publie ce serveur.

| Fichier | Rôle |
|---|---|
| `gestion-apache-ftp.sh` | Menu : créer / supprimer / lister un client (site Apache + compte FTP virtuel). |
| `vsftpd.conf` | Configuration vsftpd : comptes virtuels, chroot, FTPS obligatoire, mode passif. → `/etc/vsftpd.conf` |
| `pam.d-vsftpd` | Vérification des comptes virtuels par PAM (manquait). → `/etc/pam.d/vsftpd` |

Prérequis : `apt install apache2 vsftpd db-util`, plus un certificat (commande dans `vsftpd.conf`).

### Ce qui a été corrigé (novembre 2026)

**Script de gestion**
- **« Lister » affichait les mots de passe en clair.** Le fichier des comptes alterne nom et mot de passe, et le listage montrait toutes les lignes. Seuls les noms sont affichés maintenant.
- **Un nom vide ou bizarre n'était pas refusé.** En suppression, un nom vide pouvait mener à `rm -rf /var/www/`. Les noms sont maintenant vérifiés (minuscules, chiffres, `-`, `_`).
- La recherche et la suppression d'un compte regardaient aussi les lignes de mots de passe. Un mot de passe identique au nom d'un autre client faussait tout et pouvait supprimer le mauvais compte.
- `logins.txt`, qui contient les mots de passe en clair, était lisible par tous les comptes de la machine. Il est maintenant réservé à root (600).
- VirtualHost sur `*:80` au lieu de l'IP de la machine, pour que le site ne casse plus si l'IP change.
- Listage des dossiers (`Options Indexes`) désactivé.
- Droits 755 pour les dossiers et 644 pour les fichiers : avant, tous les fichiers devenaient exécutables.
- Configuration Apache vérifiée (`apache2ctl configtest`) avant rechargement, et présence de `db_load` vérifiée.
- `nouvel-utilisateur-apache.sh`, première version qui ne faisait que la création, a été retiré.

**vsftpd.conf**
- Le commentaire du chroot était **inversé** : avec `chroot_local_user=YES`, la liste contient les utilisateurs **non** enfermés.
- **FTPS rendu obligatoire** (`force_local_*=YES`). Avant, un client pouvait se connecter en FTP simple et le mot de passe passait en clair.
- `pasv_address` documentée : c'est l'IP publique quand le serveur est derrière un NAT.
- Ajout du fichier PAM `pam.d-vsftpd`, sans lequel les comptes virtuels ne peuvent pas se connecter.

Les versions d'origine restent consultables dans l'historique du dépôt [Debian](https://github.com/Bricoletonk/Debian).
