# CoHabitat — application de démonstration Android

Une enveloppe minimale autour de l'application web : tout est embarqué
dans l'APK, **rien ne sort de la tablette**. Sert à démontrer CoHabitat
sans réseau, sans serveur et sans compte.

## Ce qui la rend hors ligne pour de bon

- **Aucune permission `INTERNET`** dans le manifeste. L'application ne
  *peut pas* atteindre le réseau, même si on le lui demandait. C'est la
  garantie la plus forte qu'aucune donnée réelle d'immeuble ne sera
  montrée à un prospect par accident.
- Les fichiers sont servis par `WebViewAssetLoader` sous une origine
  `https://appassets.androidplatform.net/`, et non en `file://`. La page
  se comporte donc comme sur un serveur : `localStorage` fonctionne, les
  restrictions du protocole `file://` ne s'appliquent pas.
- Le mode démonstration utilise `demo-data.js` — un jeu de données
  complet et fictif, jamais la base d'un immeuble.

## Construire et déployer

Dans Android Studio : **Open** → dossier `android/` → attendre la
synchronisation Gradle → brancher la tablette en USB (débogage USB
activé) → **Run**.

Il n'y a **rien à lancer au préalable**. La tâche `preparerAssets`
(`preparer-assets.gradle.kts`) est branchée sur `preBuild` : elle copie
l'interface, réécrit les URL tierces vers `vendor/` et génère la
configuration de démonstration à chaque construction, sur Windows comme
sur Mac et Linux. Modifier `index.html` suffit ; la construction suivante
reprend la nouvelle version, et ne refait rien si rien n'a bougé.

Elle échoue volontairement si une URL de CDN subsiste dans `index.html`
sans équivalent local — une montée de version de librairie non
répercutée. Le message nomme les deux fichiers à mettre à jour.

Pour préparer les fichiers sans construire l'APK :

```
gradle :app:preparerAssets
```

Pour un APK autonome à installer sans Android Studio :

```
Build → Build Bundle(s) / APK(s) → Build APK(s)
```

Le fichier sort dans `app/build/outputs/apk/debug/`. Il s'installe par
USB (`adb install`) ou par copie sur la tablette. Aucun compte
développeur Google n'est nécessaire pour installer sur ses propres
appareils.

## Ce qui est embarqué

| Fichier | Rôle |
|---|---|
| `index.html` | l'application, URL tierces réécrites vers `vendor/` |
| `demo-data.js` | le jeu de démonstration et le client local |
| `config.js` | configuration de démonstration — aucune adresse réelle |
| `balanceOps.js` | module de soldes (inactif sans centrale) |
| `vendor/` | librairies tierces, si `deploy/scripts/fetch-vendor.sh` a été lancé |

`vendor/` est facultatif : l'interface tolère l'absence du SDK Supabase,
dont le mode démonstration n'a pas besoin.

## Vérification

Le paquet exact qui part dans l'APK a été chargé dans Chromium **sans
aucun accès réseau** : zéro erreur JavaScript, entrée automatique en mode
démonstration par le fragment `#demo`, et les sept pages du parcours
locataire affichent leurs données.

Ce qui n'a pas pu être vérifié ici : la compilation Gradle et l'exécution
sur un appareil réel — cet environnement n'a ni SDK Android ni accès
réseau pour télécharger les dépendances. Attendez-vous à ce qu'Android
Studio propose des versions plus récentes du greffon Android Gradle ;
accepter est sans conséquence, rien dans ce projet n'en dépend.

## Limites assumées

- **Consultation seulement.** Le client de démonstration filtre, trie et
  borne ; il n'écrit rien. Un bouton d'enregistrement ne produira pas
  d'erreur, mais rien ne sera conservé.
- **Pas de Machine Lunch ni de facturation** : ces écrans dépendent de la
  centrale Modulimo.
- Une table absente du jeu de données renvoie une liste vide, ce que
  l'interface affiche comme « Aucune donnée » — jamais une erreur.
