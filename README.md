# MangaiOS

**MangaiOS est un port non officiel de [Mihon](https://mihon.app) pour iOS 17+, réalisé par JeremieCZ avec l’aide de GitHub Copilot.**

Il reprend l’expérience du lecteur Android dans une application native SwiftUI,
UIKit et SwiftData pour iPhone et iPad. Ce projet indépendant n’est ni une
version officielle ni un produit soutenu par l’équipe Mihon.

> Ce README a été adapté pour le projet iOS. La présentation Android d’origine
> est conservée intégralement dans la section « README amont » ci-dessous.
> Ses téléchargements, badges et services concernent Mihon Android, pas MangaiOS.

## Fonctionnalités iOS

- Bibliothèque locale : recherche, tri, catégories, métadonnées, signets et historique.
- Lecture gauche → droite, droite → gauche, verticale paginée, webtoon et continue.
- Zoom, pages doubles, séparation des panoramas et reprise de lecture.
- Import ZIP/CBZ et dossiers d’images, avec copie privée et métadonnées `ComicInfo.xml`.
- Sauvegarde complète versionnée, incluant les fichiers, restauration confirmée
  et conservation d’une archive de sécurité.
- Import **expérimental** des sauvegardes Android `.tachibk` ou Protobuf brut,
  avec aperçu et rattachement manuel des fichiers locaux.

Les sauvegardes Android ne contiennent pas les images des chapitres :
leur import ne suffit pas à rendre les séries lisibles.

## Compiler et tester

Prérequis : **macOS, Xcode 15 ou ultérieur**, et une destination iOS 17+.

1. Ouvrir [ios/MangaiOS.xcodeproj](ios/MangaiOS.xcodeproj).
2. Sélectionner le schéma **MangaiOS** et un simulateur iPhone ou iPad.
3. Laisser Swift Package Manager résoudre **ZIPFoundation 0.9.20**, version exacte.
4. Compiler avec **⌘B**, lancer avec **⌘R**, exécuter les tests avec **⌘U**.

Pour un iPhone réel, ajouter son compte Apple dans Xcode, choisir sa **Team**
dans **Signing & Capabilities**, conserver la signature automatique et remplacer
`org.example.MangaiOS` par un identifiant unique. Sélectionner l’iPhone connecté
et activer le mode développeur si demandé. Xcode installe l’application
directement ; aucun IPA n’est nécessaire. La signature d’une Personal Team
gratuite expire généralement après sept jours.

Les tests XCTest sont hébergés dans l’application : conserver cette configuration
pour vérifier les ressources légales. Aucun certificat, profil de signature
personnel ou identifiant de compte n’est fourni dans ce dépôt.

## État et limites

Le développeur a confirmé le build, le lancement, les tests sous Xcode et le bon
fonctionnement de ses essais sur appareil. Cela ne constitue pas une validation
exhaustive de tous les appareils, versions d’iOS ou formats de sauvegarde Android.
La stabilisation et les essais de performances/accessibilité restent à poursuivre.

- Pas d’extensions, de chargement de code externe, de catalogue distant ni de suivi externe.
  La couche `Source` est réservée à un usage futur, sans fournisseur actif.
- Pas de lecture PDF/EPUB, de connexion Apple ou de synchronisation iCloud actuellement.
- Les sauvegardes iOS ne sont **pas chiffrées** et contiennent fichiers, notes et historique :
  protéger leur emplacement et n’importer que des contenus de confiance.
- La compatibilité Android reste expérimentale, sans export inverse ni garantie universelle.
- Ce dépôt ne fournit pas de distribution App Store/TestFlight ou d’IPA signé prêt à installer.
- MangaiOS n’héberge aucun manga et ne fournit aucun contenu à télécharger.

## Documentation

Les notes d’étapes décrivent les décisions, écarts avec Android et limites de validation :

- [Socle et instructions Xcode](ios/Documentation/Socle.txt) — état historique de l’étape 1.
- [Domaine et persistance](ios/Documentation/Etape2.txt).
- [Import local et ComicInfo](ios/Documentation/Etape3.txt).
- [Bibliothèque et lecteur](ios/Documentation/Etape4-6.txt).
- [Sauvegarde, restauration et reprise](ios/Documentation/Etape7.txt).
- [Compatibilité Android expérimentale](ios/Documentation/Etape8.txt).

Pour signaler un problème, utiliser les
[issues de MangaiOS](https://github.com/JeremieCz/MangaiOS/issues), avec les versions
de Xcode/iOS, les étapes de reproduction et des données de test non personnelles.
Ne pas transmettre de sauvegarde privée, de compte ni de certificat.

## Licence et attributions

MangaiOS conserve la licence [Apache 2.0](LICENSE) du projet d’origine,
sans modification du fichier `LICENSE`, ainsi que les attributions amont :

```text
Copyright © 2015 Javier Tomás
Copyright © 2024 Mihon Open Source Project
```

Merci aux contributeurs de [Mihon](https://github.com/mihonapp/mihon) et de Tachiyomi.
Les contributions iOS sont réalisées par **JeremieCZ avec l’aide de GitHub Copilot** ;
elles ne remplacent pas les crédits amont.

La [notice complémentaire iOS](ios/NOTICE) est accessible dans les mentions légales
de l’application. Aucun fichier `NOTICE` original n’a été trouvé dans le dépôt
fourni : son contenu ne sera pas inventé et devra être préservé séparément dès
qu’une référence vérifiable sera disponible.

ZIPFoundation est distribué sous [licence MIT](ios/Resources/ZIPFoundation-LICENSE),
également embarquée dans l’application. Les notices de redistribution et les
attributions applicables doivent être conservées.

## README amont — Mihon Android

<details>
<summary>Présentation d’origine conservée (Android uniquement)</summary>

<div align="center">

<a href="https://mihon.app">
    <img src="./.github/assets/logo.png" alt="Mihon logo" title="Mihon logo" width="80"/>
</a>

# Mihon [App](#)

### Full-featured reader
Discover and read manga, webtoons, comics, and more – easier than ever on your Android device.

[![Discord server](https://img.shields.io/discord/1195734228319617024.svg?label=&labelColor=6A7EC2&color=7389D8&logo=discord&logoColor=FFFFFF)](https://discord.gg/mihon)
[![GitHub downloads](https://img.shields.io/github/downloads/mihonapp/mihon/total?label=downloads&labelColor=27303D&color=0D1117&logo=github&logoColor=FFFFFF&style=flat)](https://mihon.app/download)

[![CI](https://img.shields.io/github/actions/workflow/status/mihonapp/mihon/build.yml?labelColor=27303D)](https://github.com/mihonapp/mihon/actions/workflows/build_push.yml)
[![License: Apache-2.0](https://img.shields.io/github/license/mihonapp/mihon?labelColor=27303D&color=0877d2)](/LICENSE)
[![Translation status](https://img.shields.io/weblate/progress/mihon?labelColor=27303D&color=946300)](https://hosted.weblate.org/engage/mihon/)

## Download

[![Mihon Stable](https://img.shields.io/github/release/mihonapp/mihon.svg?maxAge=3600&label=Stable&labelColor=06599d&color=043b69)](https://mihon.app/download)
[![Mihon Beta](https://img.shields.io/github/v/release/mihonapp/mihon-preview.svg?maxAge=3600&label=Beta&labelColor=2c2c47&color=1c1c39)](https://mihon.app/download)

*Requires Android 8.0 or higher.*

## Features

<div align="left">

* Local reading of content.
* A configurable reader with multiple viewers, reading directions and other settings.
* Tracker support: [MangaBaka](https://mangabaka.org), [MyAnimeList](https://myanimelist.net/), [AniList](https://anilist.co/), [Kitsu](https://kitsu.app/), [MangaUpdates](https://mangaupdates.com), [Shikimori](https://shikimori.one), [Bangumi](https://bgm.tv/), and [Hikka](https://hikka.io/) support.
* Categories to organize your library.
* Light and dark themes.
* Schedule updating your library for new chapters.
* Create backups locally to read offline or to your desired cloud service.
* Plus much more...

</div>

## Contributing

[Code of conduct](./CODE_OF_CONDUCT.md) · [Contributing guide](./CONTRIBUTING.md)

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Before reporting a new issue, take a look at the [FAQ](https://mihon.app/docs/faq/general), the [changelog](https://mihon.app/changelogs/) and the already opened [issues](https://github.com/mihonapp/mihon/issues); if you got any questions, join our [Discord server](https://discord.gg/mihon).


### Repositories

[![mihonapp/website - GitHub](https://github-stats-extended.vercel.app/api/pin/?username=mihonapp&repo=website&bg_color=161B22&text_color=c9d1d9&title_color=0877d2&icon_color=0877d2&border_radius=8&hide_border=true&description_lines_count=2)](https://github.com/mihonapp/website/)
[![mihonapp/bitmap.kt - GitHub](https://github-stats-extended.vercel.app/api/pin/?username=mihonapp&repo=bitmap.kt&bg_color=161B22&text_color=c9d1d9&title_color=0877d2&icon_color=0877d2&border_radius=8&hide_border=true&description_lines_count=2)](https://github.com/mihonapp/bitmap.kt/)

### Credits

Thank you to all the people who have contributed!

<a href="https://github.com/mihonapp/mihon/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=mihonapp/mihon" alt="Mihon app contributors" title="Mihon app contributors" width="800"/>
</a>

### Disclaimer

The developer(s) of this application does not have any affiliation with the content providers available, and this application hosts zero content.

### License

<pre>
Copyright © 2015 Javier Tomás
Copyright © 2024 Mihon Open Source Project

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
</pre>

</div>

</details>
