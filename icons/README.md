# Icônes

Toutes les icônes de ce dossier, et celles de `android/app/src/main/res/mipmap-*/`,
dérivent d'une seule source :

    modulimo-home/images/ModulimoIcon432Px.png   (1254 × 1254)

## Nettoyage appliqué à la source

Le fichier fourni est en RGB **sans canal alpha** : le damier de transparence de
l'éditeur y a été aplati en pixels blancs et gris clair. Deux corrections :

1. **Transparence rétablie.** Le damier (pixels clairs et désaturés : min
   canal > 225 et écart max−min < 14) est remplacé par de la transparence.
2. **Contour circularisé.** Le tracé d'origine s'écarte d'un cercle parfait de
   8,9 px sur 547, soit 1,63 %. Un disque orange plein `#FD5102` est posé
   dessous — la couleur dominante de l'anneau extérieur — pour qu'aucun liseré
   clair n'apparaisse là où le dessin rentre en deçà du cercle. Le masque alpha
   est un disque parfait, suréchantillonné ×3 pour lisser le bord.

Cercle ajusté par moindres carrés sur les pixels de l'anneau orange :
centre (625,71 ; 622,02), rayon retenu **548**.

## Déclinaisons

| Fichier | Taille | Cadrage |
|---|---|---|
| `favicon.png` | 64 | plein cadre |
| `icon-192.png` | 192 | plein cadre |
| `icon-512.png` | 512 | plein cadre |
| `icon-maskable-512.png` | 512 | logo à 80 %, fond `#0f0f0f` |
| `mipmap-*/ic_launcher.png` (+ `_round`) | 48 → 192 | plein cadre |
| `mipmap-*/ic_launcher_foreground.png` | 108 → 432 | logo à 72/108 |

Les deux cadrages réduits ne sont pas décoratifs :

- **maskable** (PWA) — la zone garantie visible est le cercle central de 80 %
  du cadre ; le reste peut être rogné selon la plateforme.
- **avant-plan adaptatif** (Android) — le cadre fait 108 dp mais seuls les
  72 dp centraux sont toujours visibles, le lanceur appliquant son propre
  masque (cercle, carré arrondi, goutte). À 72/108, le disque du logo remplit
  exactement le masque circulaire.

Pour régénérer après une nouvelle source : reprendre la géométrie ci-dessus,
ou réajuster le cercle si le cadrage de la source change.
