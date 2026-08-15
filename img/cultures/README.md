# Photos des cultures (plan de la serre)

Chaque section du plan de la serre affiche la **photo de la plante en culture**
quand le fichier correspondant existe ici. Sinon, l'emoji de la culture reste
affiché — aucune image cassée, aucun réglage à faire.

## Convention

Le nom du fichier est fixé par la table `SERRE_PHOTOS` dans `index.html` :

| Culture       | Fichier attendu               |
|---------------|-------------------------------|
| Tomate        | `tomate.webp`                 |
| Concombre     | `concombre.webp`              |
| Laitue        | `laitue.webp`                 |
| Poivron       | `poivron.webp`                |
| Basilic       | `basilic.webp`                |
| Haricot       | `haricot.webp`                |
| Radis         | `radis.webp`                  |
| Épinard       | `epinard.webp`                |
| Fine herbes   | `fines-herbes.webp`           |
| Fraise        | `fraise.webp`                 |

## Format recommandé

- **WebP**, cadrage **carré**, ~300 × 300 px (les sections sont recadrées en
  `object-fit: cover`, le centre de l'image doit donc porter le sujet).
- Viser **< 40 ko** par image : elles sont chargées pour les 60 sections du
  plan (avec `loading="lazy"`).

Pour ajouter une culture, ajoutez son entrée dans `SERRE_PHOTOS` (`index.html`)
puis déposez le fichier ici.
