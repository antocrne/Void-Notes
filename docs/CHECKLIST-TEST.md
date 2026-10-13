# Checklist de test manuel — Void Notes 0.1

À faire avec le build Release (ou Debug **sans** `-demo`). Rien ne demande de compte ni d'autorisation.

## 0. Premier lancement

- [ ] L'app s'ouvre en thème sombre, accent violet, **sans aucune demande d'autorisation**.
- [ ] La liste à gauche indique « Aucune note » ; à droite, « Aucune note ouverte » et un bouton « Nouvelle note ».
- [ ] La fenêtre se déplace en tirant une zone vide de la barre du haut ; un double-clic sur cette zone l'agrandit.
- [ ] Les boutons rouge, orange et vert sont alignés avec la barre et fonctionnent.

## 1. Créer une note

- [ ] ⌘N (ou le bouton crayon, seul en haut à droite) : une note vide s'ouvre, le curseur est dedans, « Titre » s'affiche en gris.
- [ ] Taper « Courses » : le texte est grand et gras ; la liste affiche « Courses » en tête, en couleur d'accent, avec l'heure.
- [ ] Entrée, puis « Pain, café » : le texte revient en taille normale ; la liste garde « Courses » sur une seule ligne ; laisser le pointeur dessus affiche « Pain, café » en infobulle.
- [ ] ⌘N une seconde fois, ne rien taper, cliquer sur « Courses » : la note vide a disparu de la liste.
- [ ] ⌘N deux fois de suite : une seule note vide est créée.

## 2. Modifier, sauvegarde automatique

- [ ] Créer une deuxième note « Idées ». Cliquer sur « Courses » et y ajouter une ligne : « Courses » repasse en tête de liste, son heure se met à jour.
- [ ] Taper quelques mots puis quitter aussitôt (⌘Q) et relancer : tout est là, et la note ouverte est celle qu'on écrivait.
- [ ] Même essai en fermant la fenêtre avec le bouton rouge.
- [ ] Réglages (⌘,) → Notes → « Afficher dans le Finder » : le dossier `notes` contient un fichier `.json` par note ; il s'ouvre dans un éditeur de texte et le texte de la note s'y lit.
- [ ] ⌘Z annule la dernière frappe, ⇧⌘Z la rétablit. Passer à une autre note et revenir : ⌘Z ne touche pas à l'autre note.

## 3. Mise en forme à la volée

Dans une note, sur une nouvelle ligne à chaque fois. La marque tapée doit **disparaître**.

- [ ] `# Titre` : dès l'espace après `#`, la ligne passe en très grand. Entrée : la ligne suivante est en texte normal.
- [ ] `## Sous-titre` : grand, un peu moins que le titre.
- [ ] `### Intertitre` : légèrement plus grand que le texte, semi-gras.
- [ ] `- un` : le tiret devient une puce « • ». Entrée : une nouvelle puce apparaît. Taper `deux`, Entrée, puis Entrée sur la puce vide : la puce disparaît, la liste est finie.
- [ ] `* un` : même résultat qu'avec le tiret.
- [ ] `1. un`, Entrée : « 2. » apparaît tout seul ; Entrée, « 3. » ; Entrée sur un numéro vide termine la liste.
- [ ] Écrire un élément de liste assez long pour passer à la ligne : la deuxième ligne s'aligne sous le texte, pas sous la puce.
- [ ] Retour arrière juste après une puce ou un numéro : la marque est retirée, le texte reste.
- [ ] `> citation` : dès l'espace, le texte se décale, devient gris, avec une barre verticale en couleur d'accent à gauche. Entrée continue la citation ; Entrée sur une ligne vide la termine.
- [ ] `un **mot** gras` : en tapant la deuxième étoile fermante, les étoiles disparaissent et « mot » passe en gras ; la suite n'est pas en gras.
- [ ] `un *mot* italique` et `un _mot_ italique` : même chose en italique.
- [ ] `**gras *et italique* ensemble**` : l'italique au milieu du gras est conservé.
- [ ] `2 * 3 * 4`, `nom_de_fichier` et `a*b*c` restent tels quels.
- [ ] Retour arrière au tout début d'un titre ou d'une citation : la ligne redevient du texte normal, sans rien effacer.
- [ ] Taper `**mot**` puis ⌘Z : les étoiles reviennent, le gras est annulé.
- [ ] Accents par touches mortes (`^` puis `e`, `¨` puis `i`) et emoji : rien n'est perturbé.
- [ ] Le curseur a la hauteur du texte normal sur la ligne vide qui suit un titre.

- [ ] `un ==mot== surligné` : en tapant le second `=` fermant, les `=` disparaissent et « mot » passe sur fond jaune ; la suite n'est pas surlignée. `a == b` et `x=1` restent tels quels.
- [ ] `---` sur une ligne vide : au troisième tiret, un trait traverse la colonne et le curseur passe à la ligne suivante, en texte normal. `a -- b` reste tel quel.
- [ ] Retour arrière au début de la ligne qui suit un séparateur : le séparateur disparaît, le texte reste.

## 3 bis. Dates et panneau « Aa »

- [ ] Sous le titre d'une note, une ligne grise en petits caractères à chasse fixe : « Créée 1 oct. 2026 · Modifiée 1 oct. 2026 à 14:38 » — pas d'heure pour la création. Elle ne se sélectionne pas et le curseur ne s'y place pas.
- [ ] Taper dans la note : l'heure de « Modifiée » suit ; « Créée » ne bouge pas, y compris après relance.
- [ ] Nouvelle note vide : la ligne des dates est sous « Titre ». Taper le titre : elle reste **sous** le titre, sans le chevaucher ; Entrée : elle ne bouge pas.
- [ ] Note qui n'a que son titre : un clic sous le titre (ou ↓) place le curseur sur une nouvelle ligne, en texte normal. Même essai quand la note se termine par un sous-titre.
- [ ] Couper le titre en deux avec Entrée, puis annuler : la ligne des dates reste sous la première ligne, sans espace vide ailleurs.
- [ ] Réduire la fenêtre au minimum : la ligne des dates se termine par « … », sans passer sur le texte.
- [ ] **Aa** et la corbeille sont dans la note, au bout de la ligne du titre. Un titre long passe à la ligne avant eux, sans passer dessous.
- [ ] Faire défiler une longue note : une fois le titre sorti de l'écran, les boutons (Aa, image, trombone, cadenas, corbeille) restent en haut à droite de la note, sur un petit fond ; ils restent cliquables (le panneau Aa s'ouvre sous eux). En remontant, ils reprennent leur place au bout du titre, sans fond.
- [ ] Fermer le panneau : le curseur revient dans le texte.
- [ ] Cliquer sur **Aa** : le panneau s'ouvre, en quatre groupes (Style, Caractères, Graisse, Paragraphe) ; le style de la ligne du curseur y est coché, en couleur d'accent, les autres montrent leur raccourci.
- [ ] G, I : gras et italique sur la sélection. Puces, numéros, citation : la ligne du curseur change.
- [ ] Sélectionner des mots, ouvrir **Aa** : la sélection reste visible. Cliquer sur chaque « Aa » de Graisse : le texte passe en Léger, Normal, Moyen, Semi-gras, Gras, et le nom s'affiche à droite de « Graisse ».
- [ ] « Surligner » : fond jaune sur la sélection ; une seconde fois le retire. Le jaune reste lisible en thème clair et en thème sombre.
- [ ] « Titre », « Sous-titre », « Texte » : la ligne du curseur change de style.
- [ ] « Séparateur » : un trait est posé sous la ligne du curseur.
- [ ] Sans sélection, choisir une graisse puis taper : seul ce qui est tapé ensuite la prend.
- [ ] ⌘Z annule chacune de ces actions.
- [ ] Quitter et relancer : graisses, surlignage et séparateurs sont conservés.

## 3 bis bis. Liens, orthographe, paragraphes déplacés

- [ ] Sélectionner un mot, **Aa** → Lien : taper `void.app`, Entrée. Le panneau se ferme ; le mot est souligné en couleur d'accent. Survol : l'adresse en infobulle. Clic : la page s'ouvre dans le navigateur.
- [ ] ⌘K sur une sélection : le panneau s'ouvre, le curseur dans le champ Lien. Une adresse mail donne un lien `mailto:`. « bonjour » : « Adresse non reconnue ».
- [ ] Curseur au bout du lien, taper : le texte ajouté n'est pas un lien. Au milieu du lien : il en fait partie.
- [ ] Curseur dans un lien (flèches), **Aa** : le champ montre son adresse ; la changer ; ✕ retire le lien, le texte reste. Format → « Retirer le lien » fait de même. ⌘Z annule.
- [ ] Sans sélection, hors d'un lien : **Aa** → Lien → `void.app` écrit « https://void.app » en lien.
- [ ] Quitter, relancer : les liens sont toujours là.
- [ ] Taper « aujourdhui » puis un espace : une vague **rouge** dessous, une fois le curseur parti du mot. Clic droit : « aujourd'hui » en tête du menu ; le choisir remplace le mot. « Ignorer l'orthographe », « Ajouter au dictionnaire » retirent la vague.
- [ ] (Seulement si Réglages → Écriture propose « Vérifier la grammaire » : macOS 27 ne la fournit plus.) Taper « This are a good idea. » : une vague **bleue** sous la faute ; clic droit : l'explication et la correction. Essayer aussi une faute de grammaire en français (accord).
- [ ] Réglages → Écriture : couper « Vérifier l'orthographe » retire les vagues rouges, « Vérifier la grammaire » les bleues. Édition → Orthographe et grammaire → les mêmes interrupteurs (cochés comme les Réglages).
- [ ] iPhone : bouton 🔗 au-dessus du clavier sur une sélection, taper l'adresse, OK : le mot est souligné ; un toucher l'ouvre dans Safari. Réglages → Écriture → « Vérifier l'orthographe » : les soulignés rouges d'iOS vont et viennent.

## 3 ter. Dossiers

- [ ] Dossiers et notes ont la même hauteur de ligne ; le titre d'une note commence sous l'icône de son dossier, sa date est au bout de la ligne.
- [ ] « Toutes les notes », en tête : un clic la déplie et montre toutes les notes de l'espace, la plus récente en premier ; un second clic la replie. L'état est conservé au relancement.

- [ ] Bouton à droite de la recherche (ou ⇧⌘N) : un dossier apparaît, son nom prêt à être tapé. Taper « Voyages », Entrée.
- [ ] Pendant la saisie du nom, cliquer sur l'icône : la grille d'icônes s'ouvre ; en choisir une, elle remplace l'icône de dossier par défaut.
- [ ] Clic droit sur « Voyages » → Nouveau sous-dossier, « Portugal » : « Voyages » se déplie, « Portugal » apparaît dessous, en retrait.
- [ ] Clic droit sur « Portugal » → Nouvelle note, l'écrire : elle apparaît sous « Portugal », en retrait. ⌘N : la note suivante va au même endroit.
- [ ] Cliquer sur « Voyages » : il se replie, « Portugal » et ses notes disparaissent ; le chevron tourne. Recliquer : tout revient.
- [ ] Les notes sans dossier sont **après** les dossiers, la plus récente en premier. Dans un dossier déplié, ses sous-dossiers viennent avant ses notes. Seules les notes épinglées sont au-dessus de « Toutes les notes ».
- [ ] **Glisser une note** sur un dossier : il se borde de la couleur d'accent ; lâcher : la note passe dessous, le dossier se déplie. Son heure n'a pas changé.
- [ ] Glisser une note sur une note d'un autre dossier : elle rejoint ce dossier. La lâcher sous la liste : elle sort de tout dossier.
- [ ] Glisser une note de la liste sur le texte de la note ouverte : rien n'y est écrit. Commencer à glisser une note puis la relâcher hors de la fenêtre ; glisser ensuite un texte depuis Safari sur un dossier : aucune note ne bouge.
- [ ] Un simple clic sur une note l'ouvre toujours, sans déclencher de glisser.
- [ ] Clic droit sur une note → Déplacer vers → un dossier ; « Aucun dossier » la sort.
- [ ] **⌘-clic** sur une autre note : elle se colore comme la note ouverte, qui reste affichée. ⌘-clic sur un dossier : il rejoint la sélection sans se déplier. ⌘-clic sur une ligne sélectionnée : elle en sort.
- [ ] **⇧-clic** plus bas dans la liste : tout ce qui est entre la dernière ligne choisie et celle-ci est sélectionné. Un clic simple sur une note : il ne reste qu'elle.
- [ ] Clic droit sur une note → « Sélectionner », puis sur une autre : même résultat qu'au ⌘-clic.
- [ ] Clic droit sur la sélection : le menu annonce le nombre d'éléments. « Déplacer vers » range toutes les notes ; « Déplacer vers l'espace » emporte notes et dossiers ; « Tout désélectionner » ne laisse que la note ouverte.
- [ ] Glisser une des notes sélectionnées sur un dossier : toutes y vont. Glisser une note hors de la sélection : elle seule.
- [ ] Sélection de notes seules, ⇧⌘⌫ (ou clic droit → « Mettre à la corbeille ») : toutes à la corbeille, sans confirmation. Avec un dossier dans la sélection : une confirmation ; les notes sélectionnées vont à la corbeille, celles restées dans le dossier remontent.
- [ ] Clic droit → Renommer, Échap : le nom ne change pas. Renommer, effacer tout, Entrée : le nom ne change pas non plus.
- [ ] Clic droit → Changer l'icône… : l'icône choisie est en couleur d'accent dans la grille.
- [ ] Chercher un mot d'une note rangée dans un dossier replié : elle est trouvée, la liste est à plat ; Entrée l'ouvre, et à la fin de la recherche son dossier est déplié.
- [ ] ⌥⌘↓ / ⌥⌘↑ parcourent les notes dans l'ordre affiché.
- [ ] Clic droit → Supprimer… sur « Voyages » : la confirmation dit que les notes sont gardées ; après suppression, « Portugal » a disparu aussi et ses notes sont à la fin de la liste, après les dossiers.
- [ ] Quitter et relancer : dossiers, icônes, rangement et dossiers dépliés sont conservés.

## 3 quater. Espaces

- [ ] Au premier lancement après mise à jour : un seul espace, « Personnel » (icône en bas à gauche de la barre latérale), avec toutes les notes et tous les dossiers d'avant. Le champ de recherche dit « Rechercher dans Personnel ».
- [ ] « + » en bas à droite : le formulaire s'ouvre, curseur dans le nom. Taper « Travail », choisir une icône, Entrée : le nouvel espace est affiché, vide (« Aucune note »), son icône en couleur d'accent.
- [ ] ⌘N puis ⇧⌘N dans « Travail » : la note et le dossier y sont ; revenir à « Personnel » (clic sur son icône) : ils n'y sont pas, et la note qu'on y lisait est rouverte.
- [ ] Balayer à deux doigts, horizontalement, sur la barre latérale : on passe à l'espace voisin ; le défilement vertical de la liste n'est pas gêné.
- [ ] Chercher dans « Travail » un mot d'une note de « Personnel » : « Aucun résultat ».
- [ ] Clic droit sur une note → Déplacer vers l'espace → Travail : elle quitte la liste, la note voisine s'ouvre ; elle est dans « Travail », hors de tout dossier, son heure inchangée.
- [ ] Clic droit sur un dossier → Déplacer vers l'espace : il part avec ses sous-dossiers et leurs notes.
- [ ] Clic droit sur l'icône d'un espace → « Renommer, changer l'icône… » : nom et icône changent dans la barre.
- [ ] Clic droit → « Supprimer l'espace… » : la confirmation dit où vont les notes ; après suppression, dossiers et notes sont dans l'espace restant. Avec un seul espace, « Supprimer l'espace… » est grisé.
- [ ] Quitter et relancer : espaces, icônes, répartition et espace affiché sont conservés ; `spaces.json` est à côté de `folders.json`.

## 4. Menu Format et raccourcis

- [ ] Sélectionner des mots, ⌘B : gras ; ⌘B à nouveau : normal. Même chose avec ⌘I.
- [ ] Sans sélection, ⌘B, taper, ⌘B : seul ce qui a été tapé entre les deux est en gras.
- [ ] Format → Titre, Sous-titre, Intertitre, Texte : la ligne du curseur change de type.
- [ ] Sélectionner trois lignes, Format → Liste numérotée : « 1. », « 2. », « 3. ». Format → Liste à puces : les numéros deviennent des puces. Une seconde fois : les puces sont retirées.
- [ ] Format → Surligner (⇧⌘E), Format → Graisse → Moyen, Format → Séparateur font la même chose que le panneau.
- [ ] Format → Citation, deux fois : la citation est posée puis retirée.
- [ ] Les raccourcis ⌥⌘1, ⌥⌘2, ⌥⌘3, ⌥⌘0, ⌥⌘7, ⌥⌘8, ⌥⌘9 font la même chose. **À noter si l'un d'eux ne répond pas sur votre clavier.**
- [ ] Copier du texte mis en forme depuis une page web ou Pages et le coller : il arrive sans sa police ni ses couleurs, dans le style de la note.
- [ ] Coller plusieurs lignes dans un titre : seule la première ligne est en titre.
- [ ] ⌘⌫ dans le texte efface jusqu'au début de la ligne (et ne supprime pas la note).

## 5. Rechercher

Avec au moins trois notes, dont une contenant « café » dans son texte et pas dans son titre.

- [ ] ⌘F : le curseur passe dans le champ « Rechercher », qui se borde de la couleur d'accent.
- [ ] Taper `cafe` (sans accent, en minuscules) : seules les notes contenant « café » restent, celle qui ne l'a que dans son contenu comprise.
- [ ] Taper deux mots : seules les notes contenant les deux restent.
- [ ] Taper un mot absent : « Aucun résultat ».
- [ ] Entrée : la première note trouvée s'ouvre, le curseur est dans son texte.
- [ ] Cliquer sur un résultat l'ouvre ; la recherche reste en place.
- [ ] La croix du champ, ou Échap, vide la recherche : toute la liste revient.
- [ ] ⌘N pendant une recherche : la recherche se vide et la nouvelle note apparaît en tête.
- [ ] Masquer la liste (⌃⌘S), puis ⌘F : la liste revient avec le curseur dans le champ.
- [ ] Taper le nom d'un dossier (ex. « Voyages ») : ses notes et celles de ses sous-dossiers (« Portugal ») sont trouvées, même si le mot n'est pas dans leur texte. Taper « voyages lisbonne » : seule la note de Lisbonne reste.
- [ ] Une note verrouillée se trouve par son titre ou son dossier, jamais par son texte.

## 5 bis. Épingler

- [ ] Clic droit sur une note rangée dans un dossier → « Épingler » : elle passe tout en haut de la liste, au-dessus de « Toutes les notes », avec une petite épingle après le titre ; elle n'est plus dans son dossier ; sa date ne change pas.
- [ ] ⌃⌘P sur la note ouverte : même chose ; à nouveau ⌃⌘P la désépingle, elle revient dans son dossier, qui se déplie.
- [ ] Déplier « Toutes les notes » : la note épinglée est la première. Rechercher un mot qu'elle partage avec d'autres : elle est le premier résultat.
- [ ] Sélectionner deux notes (⌘-clic), clic droit → « Épingler » : les deux montent ; à nouveau → « Désépingler ».
- [ ] Archiver une note épinglée : elle quitte le haut de la liste ; désarchivée, elle revient dans son dossier, sans épingle. « Épingler » est grisé sur une note archivée.
- [ ] Quitter et relancer : la note est toujours épinglée. Synchronisée : épinglée aussi sur l'iPhone.
- [ ] iPhone : balayer une note vers la droite → « Épingler » ; appui long → « Épingler » / « Désépingler ».

## 6. Supprimer, corbeille

- [ ] Ouvrir une note, ⇧⌘⌫ (ou le bouton corbeille au bout du titre) : elle quitte la liste **sans confirmation**, la note voisine s'ouvre ; « Corbeille » apparaît en dernière ligne de la liste.
- [ ] Clic droit sur une note → « Mettre à la corbeille » : même effet.
- [ ] Cliquer sur « Corbeille » : elle se déplie, les notes supprimées dessous, la plus récente en premier, chacune avec « 30 j ».
- [ ] Cliquer sur l'une d'elles : elle s'affiche, sous son titre « Dans la corbeille · Supprimée définitivement dans 30 jours » ; **on ne peut pas y écrire** ; à la place de Aa et du trombone, une flèche (restaurer) et une corbeille barrée.
- [ ] La flèche (ou clic droit → « Restaurer ») : la note revient dans son dossier, qui se déplie, avec sa date d'avant ; elle s'écrit de nouveau.
- [ ] Supprimer une note rangée dans un dossier, supprimer ce dossier, puis restaurer la note : elle revient hors de tout dossier.
- [ ] Sur une note de la corbeille, ⇧⌘⌫ (ou clic droit → « Supprimer définitivement… ») : une confirmation la nomme. « Annuler » ne supprime rien ; confirmer retire son fichier du dossier `notes`.
- [ ] Clic droit sur « Corbeille » → « Vider la corbeille… » : confirmation avec le nombre de notes ; après, la ligne « Corbeille » disparaît.
- [ ] Chercher un mot d'une note de la corbeille : « Aucun résultat ».
- [ ] La corbeille d'un espace ne montre pas les notes supprimées dans un autre.
- [ ] Quitter et relancer : la corbeille est conservée.
- [ ] App fermée, dans le fichier `.json` d'une note de la corbeille, reculer la date `deleted` de plus de 30 jours ; relancer : la note et son fichier ont disparu.
- [ ] Supprimer la dernière note : retour à « Aucune note ouverte ».

## 6 bis. Images et pièces jointes

- [ ] Le bouton image, avant le trombone : un menu « Depuis la photothèque » / « Depuis un fichier… ». Depuis un fichier : choisir trois images ; elles apparaissent en album sous les dates (une grande, deux petites), suivi d'un trait ; le texte commence dessous.
- [ ] Depuis la photothèque : le sélecteur de Photos s'ouvre **sans demande d'accès à la photothèque** ; les images choisies rejoignent l'album.
- [ ] Une, deux, quatre, cinq images : la mosaïque change ; à partir de six, la dernière tuile indique « +N ».
- [ ] Clic sur une image : elle s'ouvre en grand ; flèches (écran et clavier) pour passer aux autres ; la corbeille la retire ; « Terminé » ferme. Retirer la dernière ferme la fenêtre et l'album disparaît.
- [ ] Clic droit sur une image : « Voir l'image », « Afficher dans le Finder », « Supprimer l'image ».
- [ ] Un titre qui passe sur deux lignes pousse l'album ; taper du texte sous le titre : il va sous le trait. Réduire la fenêtre : l'album rétrécit avec la colonne.
- [ ] Une note qui n'a que des images (sans titre) n'est pas retirée comme une note vide. Dans la corbeille, l'album est là mais ne se modifie pas.
- [ ] Le trombone au bout du titre (ou ⇧⌘A, ou Fichier → « Joindre un fichier… ») ouvre un panneau de choix, **sans demande d'autorisation**. Y choisir une image l'envoie dans l'album.
- [ ] Joindre un PDF : une carte avec son icône, son nom, « PDF · taille ». Choisir plusieurs fichiers d'un coup : une ligne chacun.
- [ ] Glisser un fichier du Finder sur le texte : il est joint à l'endroit du dépôt.
- [ ] Copier un fichier dans le Finder, ⌘V dans la note : il est joint. Copier une image depuis Aperçu ou une page web, ⌘V : elle rejoint l'album (« Image.png »). Glisser une image du Finder : dans l'album aussi.
- [ ] Un clic sur une carte la sélectionne ; Retour arrière la retire ; ⌘Z la ramène.
- [ ] Double-clic sur une carte PDF : il s'ouvre dans Aperçu.
- [ ] Supprimer l'original du Finder : la pièce jointe est toujours là (c'est une copie).
- [ ] Une note qui ne contient qu'un fichier porte son nom dans la liste et n'est pas retirée comme une note vide.
- [ ] Joindre deux fichiers de même nom : le second s'appelle « nom 2 » dans `attachments/<identifiant>/`.
- [ ] Quitter et relancer : images et cartes sont là. Mettre la note à la corbeille puis la restaurer : elles y sont encore. La supprimer définitivement : son dossier dans `attachments` a disparu.
- [ ] Thème clair : les cartes restent lisibles.

## 6 quater. Listes à cocher

- [ ] En début de ligne, taper `[] ` : une case vide apparaît, la marque disparaît. De même `[ ] ` et `- [ ] `. `[x] ` donne une case cochée, dans la couleur d'accent, et le texte de la ligne s'estompe et se barre. Taper `[x] ` dans une case vide qu'Entrée vient de créer la coche aussi.
- [ ] Entrée : nouvelle case, vide, même après une ligne cochée. Entrée sur une case vide : fin de la liste. Retour arrière juste après la case : elle disparaît, le texte reste.
- [ ] **Cliquer sur une case** : elle se coche ; recliquer : elle se décoche et le trait part. Le curseur ne bouge pas, le texte ne saute pas d'un pixel. ⌘Z annule.
- [ ] Cliquer sur le texte de la ligne, juste à droite de la case : le curseur s'y place, rien n'est coché.
- [ ] ⇧⌘U coche la ligne du curseur ; avec plusieurs lignes sélectionnées, les coche toutes, ou les décoche si elles l'étaient toutes.
- [ ] Format → « Liste à cocher » (⌥⌘6) et la première tuile de « Paragraphe » du panneau Aa : des cases sur les lignes sélectionnées ; une seconde fois : elles partent. Sur une liste à puces : les puces deviennent des cases, et inversement avec ⌥⌘7.
- [ ] Une ligne à cocher longue passe à la ligne sous son texte, pas sous la case.
- [ ] Les lignes à cocher ont la même hauteur que les lignes à puces voisines.
- [ ] Cocher une ligne au milieu d'une liste : elle reste cochée à sa place une demi-seconde, puis passe (en fondu) sous les lignes qui restent à faire. En cocher trois d'affilée : elles descendent ensemble. La décocher : elle remonte juste sous les autres lignes à faire. ⌘Z la remet à sa place. Mac et iPhone.
- [ ] Dans une note de la corbeille, cliquer sur une case ne fait rien.
- [ ] Quitter et relancer : les cases et leur état sont là. Thème clair et autre accent : la case cochée suit l'accent.

## 6 sexies. Archives, et la corbeille à l'écart

- [ ] « Corbeille » (et « Archives » s'il y en a) est séparée des dossiers et des notes par un trait fin, tout en bas de la liste, juste au-dessus des espaces (Mac et iPhone) ; déplier la corbeille la fait grandir vers le haut : la ligne « Corbeille » remonte d'abord, puis ses notes apparaissent en fondu, sans jamais passer l'une sur l'autre ; au repli, les notes s'effacent avant que la ligne redescende ; pas de saut après coup (iPhone) ; une liste plus haute que la fenêtre les garde à sa fin ; pas de trait quand il n'y a ni archives ni corbeille.
- [ ] Clic droit sur une note → « Archiver » (ou ⌃⌘A sur la note ouverte) : elle quitte son dossier et « Toutes les notes » ; « Archives » apparaît au-dessus de « Corbeille » ; la note voisine s'ouvre.
- [ ] Cliquer « Archives » : la note est dessous. L'ouvrir : « Archivée · Créée… » sous le titre ; on peut y écrire.
- [ ] La rechercher par un mot de son texte : elle est trouvée.
- [ ] Clic droit → « Désarchiver » (ou ⌃⌘A) : elle revient dans son dossier, qui se déplie ; « Archives » disparaît si elle était la seule.
- [ ] Sélectionner trois notes (⌘-clic), clic droit → « Archiver » : toutes y vont.
- [ ] Quitter et relancer : les archives sont conservées ; l'app ne s'ouvre pas sur une note archivée, sauf si c'était la dernière ouverte.
- [ ] Les archives d'un espace ne montrent pas celles d'un autre.

## 6 quinquies. Verrouillage par Touch ID

- [ ] Sur une note avec du texte, cliquer le cadenas ouvert au bout du titre (ou ⇧⌘L) : **aucun dialogue** ; la note est remplacée par « Note verrouillée » et un bouton ; dans la liste, un petit cadenas suit son titre et l'infobulle d'aperçu a disparu.
- [ ] « Déverrouiller » (ou ⇧⌘L) : **le dialogue Touch ID de macOS apparaît**, au nom de Void Notes. Poser le doigt : la note revient, modifiable, le cadenas du titre est fermé et coloré.
- [ ] Dans le dialogue, « Annuler » : la note reste cachée. « Utiliser le mot de passe… » : le mot de passe de l'ordinateur la déverrouille aussi.
- [ ] **Sans Touch ID** (capot fermé avec un écran externe, ou Mac sans capteur) : le dialogue demande directement le mot de passe de l'ordinateur ; l'infobulle du cadenas dit « le mot de passe du Mac ».
- [ ] Note déverrouillée, cliquer le cadenas (ou ⇧⌘L) : elle se recache aussitôt.
- [ ] Note déverrouillée, ouvrir une autre note puis revenir : Touch ID est redemandé.
- [ ] Note déverrouillée, verrouiller l'écran (⌃⌘Q) ou laisser l'écran se mettre en veille, puis revenir : elle est recachée.
- [ ] Quitter et relancer sur une note verrouillée : elle s'ouvre cachée.
- [ ] Rechercher un mot du texte d'une note verrouillée : « Aucun résultat ». Un mot de son titre : elle est trouvée.
- [ ] Clic droit sur une note verrouillée (non ouverte) → « Retirer le verrou… » : Touch ID, puis le cadenas disparaît de la liste. Sur une note déverrouillée, Fichier → « Retirer le verrou… » : sans dialogue.
- [ ] Mettre une note verrouillée à la corbeille, la cliquer dans la corbeille : « Note verrouillée ». La restaurer : toujours verrouillée.
- [ ] Sur une note vide, le cadenas est grisé.
- [ ] Dans le dossier des notes, le fichier de la note contient `"locked" : true` — et son texte en clair (le verrou n'est pas un chiffrement).

## 6 ter. Afficher ou masquer « Toutes les notes »

- [ ] Réglages (⌘,) → Liste → désactiver « Afficher « Toutes les notes » » : **sans relancer**, la ligne disparaît (avec les notes dépliées dessous) ; la liste commence aux dossiers. Dossiers, notes et corbeille ne changent pas.
- [ ] ⌥⌘↓ / ⌥⌘↑ parcourent toujours les notes visibles ; la recherche trouve toujours dans tous les dossiers.
- [ ] Changer d'espace : la ligne est absente là aussi.
- [ ] Réactiver l'option : la ligne revient en tête, dépliée ou repliée comme elle l'était.
- [ ] Quitter et relancer : le choix est conservé.

## 7. Couleur d'accent et thème

- [ ] Réglages (⌘,) → Couleur : cliquer tour à tour sur violet, bleu, vert, orange, rose. À chaque clic, **sans relancer**, changent ensemble : la note sélectionnée dans la liste (fond et titre), le bouton de la liste dans la barre, le curseur du texte, la sélection de texte, la barre des citations, le contour du champ de recherche quand il est actif, les réglages eux-mêmes.
- [ ] Thème → Clair : fenêtre, liste, texte de la note et réglages passent en clair ; le texte reste lisible partout, les citations restent grises.
- [ ] Thème → Système : l'app suit l'apparence de macOS (la changer dans Réglages Système pour vérifier).
- [ ] Thème → Sombre. Quitter et relancer : le thème et la couleur choisis sont conservés.
- [ ] Les réglages de Void et de Void Calendar ne sont pas modifiés par ceux de Void Notes.

## 8. Fenêtre et liste

- [ ] ⌃⌘S (ou le bouton en haut à gauche) masque et affiche la liste ; le choix est conservé au relancement.
- [ ] ⌥⌘↓ / ⌥⌘↑ passent à la note suivante / précédente.
- [ ] Élargir la fenêtre : le texte reste dans une colonne centrée, de largeur confortable. La réduire au minimum : rien ne se chevauche.
- [ ] Avec une vingtaine de notes, la liste défile ; une longue note défile aussi.
- [ ] La taille et la position de la fenêtre sont rétablies au relancement.

## 8 bis. Synchronisation par iCloud Drive

Rien de ceci n'a été exécuté avec le vrai iCloud Drive : l'auto-test passe par un dossier temporaire.

- [ ] Réglages → Synchronisation → « Choisir un dossier… » : créer « Void Notes » dans iCloud Drive, « Utiliser ce dossier ». L'état passe à « À jour — heure » ; le Finder montre `void-notes-data.json` et, s'il y a des pièces jointes, `attachments/`.
- [ ] Quitter et relancer : le dossier est toujours là dans les réglages (pas « Dossier introuvable »).
- [ ] **Après avoir réinstallé une nouvelle version de l'app** : même vérification (la signature ad hoc change à chaque build ; si le dossier est perdu, le choisir de nouveau suffit, rien n'est perdu).
- [ ] Modifier une note, attendre trois secondes : la date de `void-notes-data.json` change dans le Finder.
- [ ] Ouvrir `void-notes-data.json` dans un éditeur de texte, changer un mot d'une note et sa date `modifiedAt` pour une date future, enregistrer ; revenir dans Void Notes : la note montre le mot changé.
- [ ] « Synchroniser maintenant », « Afficher dans le Finder », puis « Arrêter » : les notes restent dans l'app et dans le dossier.
- [ ] Choisir de nouveau le même dossier : aucune note en double, un seul espace « Personnel ».
- [ ] Mode avion, modifier une note, rétablir le réseau : la modification part.

## 8 ter. iPhone

Sur un vrai iPhone (Xcode → schéma `VoidNotesiOS`).

- [ ] Nouvelle note : le clavier s'ouvre, la première ligne est le titre ; `- `, `[] `, `## `, `**gras**`, `> ` et `---` se mettent en forme ; Entrée continue une liste.
- [ ] Toucher une case : elle se coche, la ligne est barrée ; retoucher la décoche.
- [ ] Barre au-dessus du clavier : style, gras, italique, surlignage, listes, citation, séparateur ; la touche de droite range le clavier.
- [ ] Retour à la liste : la note y est, avec l'heure. Une note laissée vide n'y est pas.
- [ ] Balayer une note vers la gauche : Archiver, Corbeille. Appui long : Déplacer vers, Verrouiller.
- [ ] Nouveau dossier (nom demandé), appui long dessus : note, sous-dossier, renommer, icône, supprimer.
- [ ] Espaces : « + », toucher une icône, appui long pour renommer ou supprimer.
- [ ] Images : bouton image → Photothèque ; l'album apparaît sous les dates ; toucher une image l'ouvre, balayer passe à la suivante, la corbeille la retire.
- [ ] Ajouter une image à une note ouverte qui n'a qu'un titre et un paragraphe (ex. « Livres à lire ») : le paragraphe passe sous l'album et son trait, il n'est jamais caché par l'image.
- [ ] Joindre un fichier (PDF) : une carte dans le texte ; la toucher l'ouvre.
- [ ] Verrouiller une note : Face ID demandé à l'ouverture ; revenir à l'écran d'accueil la reverrouille. Note déverrouillée ouverte, ouvrir le sélecteur d'apps : la vignette de Void Notes ne montre que le logo ; idem en tirant le centre de contrôle.
- [ ] Réglages : thème et couleur changent tout de suite, y compris dans une note ouverte.
- [ ] **Synchronisation** : Réglages → Choisir… → iCloud Drive → « Void Notes » → Ouvrir. Les notes du Mac arrivent, un seul espace « Personnel ». Modifier une note sur l'iPhone, revenir sur le Mac (le mettre au premier plan) : la modification y est ; et l'inverse. Une image ajoutée d'un côté arrive de l'autre.
- [ ] Fermer l'app et la rouvrir : le dossier est toujours là dans les réglages.

## 9. Robustesse

- [ ] App fermée, abîmer un fichier du dossier `notes` (y écrire n'importe quoi) et relancer : les autres notes sont là, la liste signale « 1 fichier illisible a été mis de côté », et le fichier se trouve dans `notes/illisibles/`.
- [ ] Forcer à quitter (⌥⌘Échap) une seconde après avoir tapé : au relancement, le texte tapé est là.
