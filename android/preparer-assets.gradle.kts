// preparer-assets.gradle.kts — prepare les fichiers web embarques dans l'APK.
//
// Remplace l'ancien sync-assets.sh, qui ne tournait pas sur Windows et
// qu'il fallait penser a lancer a la main : l'oublier reconstruisait
// silencieusement l'interface precedente. Cette tache est branchee sur
// preBuild, donc elle s'execute a chaque construction, sur les trois
// systemes, sans rien installer.
//
// Le pendant cote Docker est deploy/scripts/render-index.mjs. Les deux
// appliquent les memes substitutions d'URL ; le garde-fou en fin de tache
// echoue si une URL de CDN survit, pour qu'une montee de version de
// librairie ne passe pas inapercue ici.

import java.io.File

val depot: File = rootProject.projectDir.parentFile      // racine du depot CoHabitat
val dest: File  = file("src/main/assets")

// URL distantes -> equivalents locaux. A garder aligne avec
// deploy/scripts/render-index.mjs.
val substitutions = listOf(
    "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2" to "vendor/supabase.js",
    "https://cdn.jsdelivr.net/npm/jspdf@2.5.2/dist/jspdf.umd.min.js" to "vendor/jspdf.umd.min.js",
    "https://cdn.jsdelivr.net/npm/jspdf-autotable@3.8.4/dist/jspdf.plugin.autotable.min.js"
        to "vendor/jspdf.plugin.autotable.min.js",
    "https://esm.sh/@supabase/supabase-js@2" to "vendor/supabase.esm.js",
)

// Configuration de demonstration : aucune adresse reelle. Meme si
// quelqu'un quittait le mode demo, il n'y aurait rien a joindre — et
// l'application n'a de toute facon pas la permission reseau.
val configDemo = """
/* Genere par android/preparer-assets.gradle.kts — configuration de
   demonstration. Aucune adresse reelle : cette application ne se
   connecte a rien. */
window.COHABITAT_CONFIG = {
  instance: { id: 'demo', name: 'Immeuble de démonstration' },
  supabaseUrl: 'https://demo.invalid',
  supabaseAnonKey: 'demo',
  siteUrl: 'https://demo.invalid',
  central:    { enabled: false, url: '', key: '', viaFederation: false },
  federation: { enabled: false, url: '' },
  analytics:  { enabled: false, gaId: '' },
  lunchMachine: { kioskBase: '', demoUrl: '', centralUrl: '' },
  assets: {
    supabaseJs: 'vendor/supabase.js',
    jspdf: 'vendor/jspdf.umd.min.js',
    jspdfAutotable: 'vendor/jspdf.plugin.autotable.min.js',
    fontsCss: null, fontsPreconnect: null
  }
};

""".trimIndent() + "\n"

val preparerAssets by tasks.registering {
    group = "build"
    description = "Copie l'interface web de CoHabitat dans les assets de l'APK."

    // Ne se relance que si une source a bouge.
    inputs.files(
        File(depot, "index.html"), File(depot, "config.js"),
        File(depot, "demo-data.js"), File(depot, "balanceOps.js"),
        File(depot, "manifest.webmanifest"),
    )
    inputs.dir(File(depot, "icons"))
    outputs.dir(dest)

    doLast {
        require(File(depot, "index.html").exists()) {
            "index.html introuvable dans ${depot.absolutePath}. Le dossier android/ doit rester " +
            "dans le depot CoHabitat : la construction lit l'interface dans le dossier parent."
        }

        // Repartir a vide : sans cela un fichier retire du depot resterait
        // indefiniment embarque dans l'APK.
        dest.deleteRecursively()
        dest.mkdirs()

        listOf("balanceOps.js", "demo-data.js", "manifest.webmanifest").forEach {
            File(depot, it).copyTo(File(dest, it), overwrite = true)
        }

        // Icones : seulement les images, la note de provenance n'a rien a
        // faire dans l'APK.
        val icones = File(dest, "icons").apply { mkdirs() }
        File(depot, "icons").listFiles { f -> f.extension == "png" }
            ?.forEach { it.copyTo(File(icones, it.name), overwrite = true) }

        // Librairies tierces si elles ont ete rapatriees par
        // deploy/scripts/fetch-vendor.sh. Facultatif : le mode
        // demonstration fonctionne sans, l'interface tolere l'absence du
        // SDK Supabase.
        val vendorSrc = File(depot, "vendor")
        if (vendorSrc.isDirectory) vendorSrc.copyRecursively(File(dest, "vendor"), overwrite = true)

        // config.js du depot definit CohabitatConfig en fusionnant la
        // configuration ci-dessus avec ses defauts : sans lui, l'interface
        // ne trouve pas sa configuration et s'arrete des la premiere ligne.
        File(dest, "config.js").writeText(configDemo + File(depot, "config.js").readText())

        // index.html : les URL tierces pointent vers vendor/, sinon un
        // appel au CDN partirait pour rien.
        var html = File(depot, "index.html").readText()
        substitutions.forEach { (de, vers) -> html = html.replace(de, vers) }

        // Les polices sont facultatives : sans elles la pile systeme prend
        // le relais, ce qui reste lisible.
        html = Regex(
            """<link rel="preconnect" href="https://fonts\.googleapis\.com">\s*""" +
            """<link href="https://fonts\.googleapis\.com/css2[^"]*" rel="stylesheet">"""
        ).replace(html, "<!-- polices systeme -->")

        // Analytique : le script Google ne serait de toute facon pas joignable.
        html = html.replace("https://www.googletagmanager.com/gtag/js?id=", "about:blank#gtag=")

        // Garde-fou : si une URL de CDN survit, c'est qu'une version de
        // librairie a bouge dans index.html sans que la table ci-dessus
        // suive. Mieux vaut une erreur de construction qu'une page qui
        // appelle le reseau depuis une application qui n'y a pas droit.
        val restantes = Regex("""https://(cdn\.jsdelivr\.net|esm\.sh)/[^"' ]+""")
            .findAll(html).map { it.value }.distinct().toList()
        check(restantes.isEmpty()) {
            "URL de CDN non substituees dans index.html : ${restantes.joinToString()}\n" +
            "Mettre a jour `substitutions` dans android/preparer-assets.gradle.kts " +
            "et REMPLACEMENTS dans deploy/scripts/render-index.mjs."
        }

        File(dest, "index.html").writeText(html)
        logger.lifecycle("[assets] interface prete dans ${dest.relativeTo(rootProject.projectDir)}")
    }
}

tasks.named("preBuild") { dependsOn(preparerAssets) }
