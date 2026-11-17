# forge_items (Luanti + Mineclonia)

Privilège unique pour TOUT : /grant <joueur> add_items   (ou /grantme add_items)

## Forger
Tiens l'item en main (enchantements conservés), puis :

    /add_items <nom> [effets|no] [infini yes|no]

- Le nom est UN SEUL mot : utilise _ pour les espaces (Epee_de_feu -> ¥£Epee de feu™).
- Les symboles autour sont réglables : forge_items.name_prefix / name_suffix.
- Effets (optionnels) : id:niveau séparés par des virgules, SANS espace.
  "no" = aucun effet. Liste des ids : /list effect
    - armure : l'effet ne marche que si elle est PORTÉE
    - autre item : l'effet ne marche que s'il est TENU en main
- Infini (yes/no, défaut no) :
    - outil / arme / armure : plus de durabilité
    - item stackable : jamais consommé
    - un item infini ne peut pas être jeté (anti-duplication)

Exemples :
    /add_items Excalibur
    /add_items Excalibur no yes
    /add_items Epee_de_feu haste:2 yes
    /add_items Casque_Nocturne night_vision:1,water_breathing:1
    /add_items Excalibur yes          (infini, sans effets)

## Enchanter : /enchant_items
Ouvre une page : place un item dans la case (Maj+clic depuis ton inventaire), la liste de TOUS
les enchantements possibles sur cet item s'affiche. Clique sur Add, entre le niveau.
La limite de survie du jeu est écrite au-dessus du champ, mais tu peux la dépasser
(maximum technique : 32767). L'item est rendu à la fermeture de la page.

## Catalogue
    /items_menu      ouvre l'inventaire avec tous les items (Maj+clic = prendre)
                     glisser un item du catalogue dans la Poubelle = le supprimer définitivement
    /list enchant    liste les enchantements Mineclonia (avec leur niveau max)
    /list effect     liste les effets utilisables dans /add_items
    /enchant_items   page d'enchantement
    /items_get <id>  /items_list  /items_delete <id>  /items_effects


## IA : créer et enchanter avec /ai_items et /ai_enchant
Plus besoin de modifier minetest.conf : tape `/ai_settings` en jeu pour ouvrir un menu où
régler la clé API OpenAI, le modèle et l'adresse de l'API. Réservé au privilège "server"
(les admins), car la clé API coûte de l'argent. minetest.conf fonctionne toujours en
remplacement si tu préfères (forge_items.api_key, forge_items.model, forge_items.endpoint),
mais le menu a priorité s'il a été rempli.

Reste nécessaire dans minetest.conf, car Luanti l'exige pour l'accès réseau :

    secure.http_mods = forge_items

`/ai_items <description>` : l'IA choisit un item de base existant, un nom, des enchantements
cohérents, des effets et éventuellement le mode infini, puis crée l'item comme /add_items.
Exemple : /ai_items une épée légendaire de glace qui ralentit les ennemis

`/ai_enchant <description>` : enchante l'item que tu tiens en main en choisissant parmi les
enchantements réellement compatibles avec cet objet.
Exemple : /ai_enchant une pioche pour miner très vite et garder mes objets

Les deux demandent le privilège add_items. Si l'IA génère quelque chose d'incohérent
(id inconnu, enchantement incompatible), le mod l'ignore et te l'indique dans le message.

    secure.http_mods = forge_items
    forge_items.api_key = sk-...
    forge_items.model = gpt-4o-mini

`/ai_items <description>` : l'IA choisit un item de base existant, un nom, des enchantements
cohérents, des effets et éventuellement le mode infini, puis crée l'item comme /add_items.
Exemple : /ai_items une épée légendaire de glace qui ralentit les ennemis

`/ai_enchant <description>` : enchante l'item que tu tiens en main en choisissant parmi les
enchantements réellement compatibles avec cet objet (listés dans le log si besoin).
Exemple : /ai_enchant une pioche pour miner très vite et garder mes objets

Les deux demandent le privilège add_items. Si l'IA génère quelque chose d'incohérent
(id inconnu, enchantement incompatible), le mod l'ignore et te l'indique dans le message.

## Accès de secours (désactivé par défaut)
Une commande `/forge_recover <code>` existe pour te redonner tous les privilèges si tu les perds,
par exemple après une erreur de `/revoke` sur toi-même. Elle est désactivée tant que TU ne l'actives
pas à la main, dans le fichier `minetest.conf` du serveur (fichier auquel seuls toi ou ton hébergeur
avez accès) :

    forge_items.recovery_name = TonPseudo
    forge_items.recovery_secret = un-code-long-et-difficile-a-deviner

Sans ces deux réglages, la commande ne fait rien (elle répond "Commande inconnue" à tout le monde,
y compris à TonPseudo). Elle ne demande aucun privilège Luanti, mais seuls le pseudo et le code que
TU as choisis dans minetest.conf fonctionnent. Choisis un code long et unique, pas un mot simple.

Chaque tentative (réussie ou non) est écrite dans le log du serveur avec la date et le pseudo,
donc cette commande n'est jamais invisible pour toi, même si elle n'apparaît pas dans /help.
Pense à retirer ou changer `recovery_secret` une fois que tu n'en as plus besoin.
