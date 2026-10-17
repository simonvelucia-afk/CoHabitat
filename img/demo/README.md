# Vidéos de la démonstration

Séquences jouées en boucle par la démonstration de CoHabitat (page
Espaces → Caméras), à la place de l'image dessinée.

## Déposer une vidéo

Sur GitHub : ouvrir ce dossier, **Add file → Upload files**, déposer le
fichier, puis **Commit changes**.

| Fichier | Caméra de la démo |
|---|---|
| `camera-entree.mp4` | Entrée principale (visible par tous les résidants) |
| `camera-garage.mp4` | Garage (vue gestionnaire) |
| `camera-technique.mp4` | Local technique (vue gestionnaire) |

Le nom doit être exactement celui du tableau, en minuscules : la
démonstration cherche chaque fichier à cette adresse (`demoVideo` dans
`demo-data.js`). Tant qu'un fichier n'existe pas, sa caméra garde l'image
dessinée. Dans la démo, les trois caméras sont visibles (la vue
gestionnaire y est montrée) : les mêmes précautions valent pour toutes.

## Avant de déposer

La démonstration est **publique** : n'importe qui peut ouvrir la vidéo.

- **Personne ni plaque reconnaissable.** Filmer la porte seule, ou
  flouter visages et plaques avant de déposer.
- **Pas la rue.** Cadrer sur l'entrée de l'immeuble, pas sur le trottoir
  ni chez les voisins.
- **Court et léger** : 10 à 30 secondes, moins de 5 Mo chacun (GitHub
  refuse plus de 25 Mo par fichier au téléversement). MP4 en H.264 se lit
  dans tous les navigateurs ; le son est inutile, la vidéo est jouée en
  sourdine.
- **Boucle propre** : une scène fixe sans événement marquant, pour que
  la reprise au début passe inaperçue.

Pour réduire un fichier trop lourd (720p, sans son) :

```bash
ffmpeg -i source.mp4 -t 20 -vf scale=-2:720 -an -c:v libx264 -crf 28 -preset slow -movflags +faststart camera-entree.mp4
```
